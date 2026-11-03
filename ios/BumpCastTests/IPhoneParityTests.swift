import SwiftUI
import Testing
import UIKit

@testable import BumpCast

/// The iPhone, screen by screen, for comparing two builds pixel for pixel (`scripts/iphone-parity.sh`
/// renders this file in the current tree and in an earlier commit, then diffs the pairs). It uses
/// only what both builds have; `IPhoneParityAdapter.swift` holds the few lines that differ.
///
/// Run by the script, which sets `PARITY_OUT` (where the images go) and `PARITY_SIZES`
/// ("pro:402x874,closed-duo:466x678"). Launched with `-forceOffline` it renders the offline states
/// instead. Without `PARITY_OUT` it does nothing, so the normal suite skips it.
@MainActor
@Suite(.serialized)
struct IPhoneParityTests {
    static let environment = ProcessInfo.processInfo.environment
    static let output = environment["PARITY_OUT"].map { URL(fileURLWithPath: $0) }
    static let offline = ProcessInfo.processInfo.arguments.contains("-forceOffline")

    static var sizes: [(name: String, size: CGSize)] {
        (environment["PARITY_SIZES"] ?? "pro:402x874").split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":")
            let dims = parts.last?.split(separator: "x").compactMap { Double($0) } ?? []
            guard parts.count == 2, dims.count == 2 else { return nil }
            return (String(parts[0]), CGSize(width: dims[0], height: dims[1]))
        }
    }

    // MARK: Fixtures (only what both builds have)

    /// Tomorrow at a clock time in New York: a day or a night sky behind the flight.
    static func tomorrow(at hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    static func numbered(_ origin: String, _ destination: String, _ departing: Date, _ number: String = "B6 23", air: Double = 386) -> Flight {
        var flight = Flight(id: UUID(), origin: origin, destination: destination, departureAt: departing)
        flight.flightNumber = number
        flight.airlineName = "JetBlue"
        flight.arrivalAt = departing.addingTimeInterval(air * 60)
        return flight
    }

    enum Fixture: String, CaseIterable {
        case beforeDay, beforeNight, dayOf, inAir, landed, cancelled, diverted, gusty, global, lhrJfk, lhrFco, nothingSaved
    }

    static func flight(_ fixture: Fixture) -> (Flight, Forecast?) {
        func minutes(_ m: Double) -> Date { .now.addingTimeInterval(m * 60) }
        let sample = DemoFlightService.sampleForecast
        switch fixture {
        case .beforeDay: return (numbered("KJFK", "KLAX", tomorrow(at: 13)), sample)
        case .beforeNight: return (numbered("KJFK", "KLAX", tomorrow(at: 23, 30)), sample)
        case .dayOf:
            var flight = numbered("KJFK", "KLAX", minutes(120))
            flight.status = FlightStatus(
                state: .delayed, live: true, departureScheduled: flight.departureAt,
                departureExpected: flight.departureAt.addingTimeInterval(40 * 60),
                arrivalScheduled: flight.arrivalAt, arrivalExpected: flight.arrivalAt?.addingTimeInterval(34 * 60),
                delayMin: 40, departureGate: "B22", departureTerminal: "5", arrivalTerminal: "5",
                checkedAt: .now.addingTimeInterval(-8 * 60), nextCheckAt: .now.addingTimeInterval(52 * 60))
            return (flight, sample)
        case .inAir:
            var flight = numbered("KLGA", "KORD", minutes(-70), "AA 1180", air: 150)
            flight.status = FlightStatus(
                state: .departed, live: true, departureScheduled: flight.departureAt, checkedAt: .now,
                takeoffAt: flight.departureAt.addingTimeInterval(15 * 60))
            return (flight, sample)
        case .landed: return (numbered("KEWR", "CYYZ", minutes(-8 * 60), "AC 1507", air: 95), sample)
        case .cancelled:
            var flight = numbered("KBOS", "KDCA", minutes(5 * 60), "DL 402", air: 90)
            flight.status = FlightStatus(state: .cancelled, live: true, departureScheduled: flight.departureAt, checkedAt: .now)
            return (flight, sample)
        case .diverted:
            var flight = numbered("KJFK", "KLAX", minutes(-120))
            flight.status = FlightStatus(
                state: .diverted, live: true, departureScheduled: flight.departureAt, divertedTo: "KDEN",
                checkedAt: .now, takeoffAt: flight.departureAt.addingTimeInterval(12 * 60))
            return (flight, sample)
        case .gusty: return (numbered("KJFK", "KLAX", tomorrow(at: 13)), DemoFlightService.gustySample)
        case .global:
            return (Flight(id: UUID(), origin: "SBGR", destination: "LPPT", departureAt: tomorrow(at: 1)),
                DemoFlightService.load("sample_global_outlook"))
        case .lhrJfk:
            let flight = Flight(id: UUID(), origin: "EGLL", destination: "KJFK", departureAt: tomorrow(at: 9))
            return (flight, DemoFlightService.notYetConfirmed(DemoFlightService.load("sample_global_lhr_jfk"), departure: flight.departureAt))
        case .lhrFco:
            return (Flight(id: UUID(), origin: "EGLL", destination: "LIRF", departureAt: tomorrow(at: 15)),
                DemoFlightService.load("sample_global_lhr_fco"))
        case .nothingSaved: return (numbered("KJFK", "KLAX", tomorrow(at: 13)), nil)
        }
    }

    /// Today at noon in New York: when the fixtures last synced and their forecasts were issued, so
    /// "Updated …" reads the same in both builds however far apart they render.
    static let noon: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
    }()

    static func store(_ flights: [(Flight, Forecast?)]) async -> FlightStore {
        let local = LocalStore(directory: URL.temporaryDirectory.appending(path: "Parity-\(UUID().uuidString)"))
        var snapshot = Snapshot()
        snapshot.flights = flights.map(\.0)
        snapshot.syncedAt = noon
        for (flight, forecast) in flights {
            var forecast = forecast
            forecast?.issuedAt = noon
            snapshot.forecasts[flight.id] = forecast
            // Already seen, so the timeline is drawn whole rather than caught partway through its
            // first-open sweep (which a slower simulator can still be in when the picture is taken).
            UserDefaults.standard.set(true, forKey: "revealed.\(flight.id).\(noon.timeIntervalSince1970)")
        }
        await local.save(snapshot)
        return FlightStore(
            service: FakeFlightService(stored: nil, sessions: [], remote: []), local: local,
            connectivity: Connectivity(), protectedDataAvailable: { true })
    }

    static func environment<V: View>(_ view: V, store: FlightStore) -> some View {
        view
            .environment(store)
            .environment(Router.shared)
            .environment(Paywalls.shared)
            .environment(PushNotifications.shared)
            .environment(InFlight.shared)
            .environment(Connectivity.shared)
            .environment(EmailImport.shared)
            .font(.bcBody)
            .tint(Theme.accent)
    }

    // MARK: Rendering

    /// Shows `view` in a real window of `size` and saves what's on screen.
    /// Long enough for every appearance animation (the chart's sweep, cards settling in) to finish,
    /// even on a slower simulator.
    private func shoot<V: View>(_ name: String, _ view: V, size: CGSize, wait: Double = 3) async throws {
        guard let output = Self.output else { return }
        // PARITY_ONLY=breathing (or detail,flights) renders just the screens whose names contain one.
        if let only = Self.environment["PARITY_ONLY"], !only.split(separator: ",").contains(where: { name.contains($0) }) { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(wait))
        // At 2x on every device: a tall screen at 3x is past what a snapshot can hold and comes out
        // blank, and one scale makes every pair comparable.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        // A blank picture would compare as identical to another blank one: that's a failure.
        #expect(!Self.isBlank(image), "\(name) rendered blank")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(image.pngData()).write(to: output.appending(path: "\(name).png"))
    }

    /// One colour all over (nothing drawn), sampled on a grid.
    static func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let row = cg.bytesPerRow, step = cg.bitsPerPixel / 8
        let first = (bytes[0], bytes[1], bytes[2])
        for y in stride(from: 0, to: cg.height, by: max(1, cg.height / 60)) {
            for x in stride(from: 0, to: cg.width, by: max(1, cg.width / 30)) {
                let o = y * row + x * step
                if (bytes[o], bytes[o + 1], bytes[o + 2]) != first { return false }
            }
        }
        return true
    }

    /// A screen that presents `sheet` the way the app does (see the adapter).
    private struct SheetHost<Sheet: View>: View {
        @State var shown = false
        let sheet: () -> Sheet

        var body: some View {
            Color(red: 0.86, green: 0.91, blue: 0.96)
                .paritySheet(isPresented: $shown, content: sheet)
                .task { shown = true }
        }
    }

    @Test func renderEveryIPhoneScreen() async throws {
        guard Self.output != nil else { return }
        IPhoneParityAdapter.prepare()
        // The App Store rating prompt stays out of the pictures (and an earlier build asked Superwall
        // about it even with no key, which stops the run).
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? ""
        for key in ["review.requested.firstForecast", "review.requested.forecastMatched.\(version)"] {
            UserDefaults.standard.set(true, forKey: key)
        }
        GlobalBeta.shared.set(true)
        let texts: [(String, DynamicTypeSize)] = [("default", .large), ("ax3", .accessibility3)]
        for (device, size) in Self.sizes {
            for (text, type) in texts {
                func name(_ screen: String) -> String { "\(device)-\(text)-\(screen)" }
                // Long screens in a tall window, so what scrolls is in the picture: as tall as the
                // render server can snapshot at this device's scale (8192 pixels).
                let tall = CGSize(width: size.width, height: min(3200, (8192 / UIScreen.main.scale).rounded(.down)))
                if Self.offline {
                    for fixture in [Fixture.beforeDay, .inAir, .nothingSaved] {
                        let entry = Self.flight(fixture)
                        let store = await Self.store([entry])
                        try await shoot(name("offline-flights-\(fixture)"), Self.environment(FlightsListView(), store: store).dynamicTypeSize(type), size: tall)
                        try await shoot(name("offline-detail-\(fixture)"),
                            Self.environment(NavigationStack { FlightDetailView(flightID: entry.0.id) }, store: store).dynamicTypeSize(type), size: tall)
                    }
                    let mapStore = await Self.store([Self.flight(.beforeDay)])
                    await LocalStore.shared.saveMap(MapSnapshot(grids: [:], savedAt: .now))
                    try await shoot(name("offline-map-needs-connection"),
                        Self.environment(NavigationStack { TurbulenceMapView() }, store: mapStore).dynamicTypeSize(type), size: size, wait: 3.5)
                    let grid = TurbulenceGrid(
                        validAt: .now, levelFt: 10000, cycle: .now.addingTimeInterval(-3600), north: 50, west: -125, step: 1,
                        ny: 2, nx: 2, cells: "0000")
                    await LocalStore.shared.saveMap(MapSnapshot(grids: [10000: [grid]], savedAt: .now))
                    try await shoot(name("offline-map-no-saved-height"),
                        Self.environment(NavigationStack { TurbulenceMapView() }, store: mapStore).dynamicTypeSize(type), size: size, wait: 3.5)
                    await LocalStore.shared.saveMap(MapSnapshot(grids: [:], savedAt: .now))
                    continue
                }
                // Flights: each state as the list shows it.
                let lists: [(String, [Fixture])] = [
                    ("before-day", [.beforeDay]), ("before-night", [.beforeNight]), ("day-of", [.dayOf]), ("in-air", [.inAir]),
                    ("landed", [.landed, .beforeDay]), ("cancelled", [.cancelled, .beforeDay]), ("diverted", [.diverted]),
                    ("none", []), ("many", [.beforeDay, .dayOf, .global, .lhrJfk, .lhrFco, .gusty]),
                ]
                for (screen, fixtures) in lists {
                    let store = await Self.store(fixtures.map(Self.flight))
                    try await shoot(name("flights-\(screen)"), Self.environment(FlightsListView(), store: store).dynamicTypeSize(type), size: tall)
                }
                // A flight's own screen, for each kind of route and state.
                for fixture in Fixture.allCases {
                    let entry = Self.flight(fixture)
                    let store = await Self.store([entry, Self.flight(.dayOf)])
                    try await shoot(name("detail-\(fixture)"),
                        Self.environment(NavigationStack { FlightDetailView(flightID: entry.0.id) }, store: store).dynamicTypeSize(type), size: tall)
                }
                // The other tabs, full screen.
                let store = await Self.store([Self.flight(.beforeDay), Self.flight(.inAir)])
                try await shoot(name("map"), Self.environment(NavigationStack { TurbulenceMapView() }, store: store).dynamicTypeSize(type), size: size, wait: 3.5)
                try await shoot(name("learn"), Self.environment(LearnView(), store: store).dynamicTypeSize(type), size: size)
                try await shoot(name("calm"), Self.environment(CalmView(), store: store).dynamicTypeSize(type), size: size)
                try await shoot(name("breathing"), Self.environment(BreathingView(), store: store).dynamicTypeSize(type), size: size)
                try await shoot(name("onboarding"), Self.environment(NativeOnboardingView(), store: store).dynamicTypeSize(type), size: size)
                // Sheets, presented the way the app presents them.
                let (global, forecast) = Self.flight(.global)
                let sheetStore = await Self.store([(global, forecast)])
                let warning = try #require(forecast?.officialWarnings.first)
                let sheets: [(String, () -> AnyView)] = [
                    ("add-flight", { AnyView(AddFlightView()) }),
                    ("edit-flight", { AnyView(AddFlightView(flight: global)) }),
                    ("settings", { AnyView(SettingsView()) }),
                    ("ready-to-add", { AnyView(ReadyToAddSheet()) }),
                    ("warning", { AnyView(WarningSheet(warning: warning)) }),
                    ("pilot-report-note", { AnyView(PilotReportNoteSheet(warning: warning)) }),
                    ("global-outlook", { AnyView(GlobalOutlookSheet(neverConfirmed: true)) }),
                    ("email-import", { AnyView(EmailImportSheet()) }),
                ]
                for (screen, sheet) in sheets {
                    try await shoot(name("sheet-\(screen)"),
                        Self.environment(SheetHost(sheet: sheet), store: sheetStore).dynamicTypeSize(type), size: size, wait: 3)
                }
            }
        }
    }
}
