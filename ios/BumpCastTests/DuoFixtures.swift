import Darwin
import SwiftUI
import Testing
import UIKit

@testable import BumpCast

/// Flights in every state the screens show, in a store of their own, for rendering whole screens
/// in tests (the Duo audit and the iPhone comparison). Times are relative to now, so each state
/// is what the app would show today.
@MainActor
enum DuoFixtures {
    enum Case: String, CaseIterable {
        case beforeFlight, dayOf, inAir, justLanded, cancelled, diverted, evenStretches
        case global, lhrJfk, lhrFco, strong, gusty
        /// A flight with no forecast saved on the phone yet.
        case nothingSaved
    }

    /// Where the audit writes its renders: `ios/build/duo-audit`, which git ignores.
    static let output: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "build/duo-audit")

    static func flight(_ fixture: Case) -> (Flight, Forecast?) {
        func minutes(_ m: Double) -> Date { .now.addingTimeInterval(m * 60) }
        func numbered(_ origin: String, _ destination: String, departing: Date, number: String = "B6 23", air: Double = 386) -> Flight {
            var flight = Flight(id: UUID(), origin: origin, destination: destination, departureAt: departing)
            flight.flightNumber = number
            flight.airlineName = "JetBlue"
            flight.arrivalAt = departing.addingTimeInterval(air * 60)
            return flight
        }
        switch fixture {
        case .beforeFlight:
            return (numbered("KJFK", "KLAX", departing: minutes(26 * 60)), DemoFlightService.sampleForecast)
        case .dayOf:
            var flight = numbered("KJFK", "KLAX", departing: minutes(120))
            flight.status = FlightStatus(
                state: .delayed, live: true, departureScheduled: flight.departureAt,
                departureExpected: flight.departureAt.addingTimeInterval(40 * 60),
                arrivalScheduled: flight.arrivalAt, arrivalExpected: flight.arrivalAt?.addingTimeInterval(34 * 60),
                delayMin: 40, departureGate: "B22", departureTerminal: "5", arrivalTerminal: "5",
                checkedAt: .now.addingTimeInterval(-8 * 60), nextCheckAt: .now.addingTimeInterval(52 * 60))
            return (flight, DemoFlightService.sampleForecast)
        case .inAir:
            var flight = numbered("KLGA", "KORD", departing: minutes(-70), number: "AA 1180", air: 150)
            flight.status = FlightStatus(
                state: .departed, live: true, departureScheduled: flight.departureAt, checkedAt: .now,
                takeoffAt: flight.departureAt.addingTimeInterval(15 * 60))
            return (flight, DemoFlightService.sampleForecast)
        case .justLanded:
            return (numbered("KEWR", "CYYZ", departing: minutes(-8 * 60), number: "AC 1507", air: 95), DemoFlightService.sampleForecast)
        case .cancelled:
            var flight = numbered("KBOS", "KDCA", departing: minutes(5 * 60), number: "DL 402", air: 90)
            flight.status = FlightStatus(state: .cancelled, live: true, departureScheduled: flight.departureAt, checkedAt: .now)
            return (flight, DemoFlightService.sampleForecast)
        case .diverted:
            var flight = numbered("KJFK", "KLAX", departing: minutes(-120))
            flight.status = FlightStatus(
                state: .diverted, live: true, departureScheduled: flight.departureAt, divertedTo: "KDEN",
                checkedAt: .now, takeoffAt: flight.departureAt.addingTimeInterval(12 * 60))
            return (flight, DemoFlightService.sampleForecast)
        case .evenStretches:
            return (numbered("KJFK", "KLAX", departing: minutes(26 * 60)), Self.sampleWithoutLastStretch)
        case .global:
            return (Flight(id: UUID(), origin: "SBGR", destination: "LPPT", departureAt: minutes(26 * 60)),
                DemoFlightService.load("sample_global_outlook"))
        case .lhrJfk:
            let flight = Flight(id: UUID(), origin: "EGLL", destination: "KJFK", departureAt: minutes(20 * 60))
            return (flight, DemoFlightService.notYetConfirmed(DemoFlightService.load("sample_global_lhr_jfk"), departure: flight.departureAt))
        case .lhrFco:
            return (Flight(id: UUID(), origin: "EGLL", destination: "LIRF", departureAt: minutes(26 * 60)),
                DemoFlightService.load("sample_global_lhr_fco"))
        case .strong:
            return (numbered("KJFK", "KLAX", departing: minutes(26 * 60)), DemoFlightService.strongSample)
        case .gusty:
            return (numbered("KJFK", "KLAX", departing: minutes(26 * 60)), DemoFlightService.gustySample)
        case .nothingSaved:
            return (numbered("KJFK", "KLAX", departing: minutes(30 * 60)), nil)
        }
    }

    /// The sample forecast less its last stretch: an even number of stretch cards.
    static let sampleWithoutLastStretch: Forecast = {
        let url = Bundle.main.url(forResource: "sample_forecast", withExtension: "json")!
        var json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["segments"] = Array((json["segments"] as! [[String: Any]]).dropLast())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var forecast = try! decoder.decode(Forecast.self, from: JSONSerialization.data(withJSONObject: json))
        forecast.issuedAt = forecast.issuedAt ?? .now
        return forecast
    }()

    /// A store holding these flights and forecasts, with no network behind it.
    static func store(_ flights: [(Flight, Forecast?)]) async -> FlightStore {
        let directory = URL.temporaryDirectory.appending(path: "DuoFixtures-\(UUID().uuidString)")
        let local = LocalStore(directory: directory)
        var snapshot = Snapshot(flights: flights.map(\.0), syncedAt: .now, userID: nil)
        for (flight, forecast) in flights { snapshot.forecasts[flight.id] = forecast }
        await local.save(snapshot)
        return FlightStore(
            service: FakeFlightService(stored: nil, sessions: [], remote: []), local: local,
            connectivity: Connectivity(), protectedDataAvailable: { true })
    }

    /// The app's environment around a view, with this store.
    static func environment<V: View>(_ view: V, store: FlightStore, fold: DuoFold?, unlocked: Bool = true) -> some View {
        view
            .environment(\.duoFold, fold)
            .environment(\.isWideLayout, fold != nil)
            .environment(\.debugFullAccess, unlocked)
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

    /// Renders a view at a width, as tall as it needs, on a plain sky-coloured background.
    static func render<V: View>(_ view: V, width: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: view.frame(width: width).background(Color(red: 0.86, green: 0.91, blue: 0.96)))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 2
        return renderer.uiImage
    }

    /// SwiftUI builds its accessibility tree only while an assistive technology is on. Accessibility
    /// automation counts: the switch accessibility snapshot tools use (test-only).
    static let enableAccessibility: Void = {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
            let symbol = dlsym(library, "_AXSSetAutomationEnabled")
        else { return }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(1)
    }()

    /// A screen in a real window (accessibility and UIKit-backed views need one), at a size.
    static func host<V: View>(_ view: V, size: CGSize) throws -> (window: UIWindow, view: UIView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height, alignment: .top))
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (window, host.view)
    }

    /// What VoiceOver reaches, in its order: each element's label (and value) and frame on screen.
    static func accessibilityElements(in root: Any) -> [(label: String, frame: CGRect)] {
        var out: [(label: String, frame: CGRect)] = []
        func collect(_ object: Any) {
            guard let element = object as? NSObject else { return }
            if element.isAccessibilityElement {
                let label = [element.accessibilityLabel, element.accessibilityValue].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: ", ")
                if !label.isEmpty { out.append((label, element.accessibilityFrame)) }
                return
            }
            if let children = element.accessibilityElements, !children.isEmpty {
                children.forEach(collect)
                return
            }
            let count = element.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count { if let child = element.accessibilityElement(at: index) { collect(child) } }
                return
            }
            (element as? UIView)?.subviews.forEach(collect)
        }
        collect(root)
        return out
    }

    /// A contact sheet: each image's top under its name, PASS in green or FAIL in red.
    static func writeGrid(_ cells: [(name: String, image: UIImage?, passed: Bool)], name: String) {
        let columns = 4, width: CGFloat = 420, height: CGFloat = 320, label: CGFloat = 36
        let rows = (cells.count + columns - 1) / columns
        let size = CGSize(width: CGFloat(columns) * width, height: CGFloat(rows) * (height + label))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let grid = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, cell) in cells.enumerated() {
                let origin = CGPoint(x: CGFloat(index % columns) * width, y: CGFloat(index / columns) * (height + label))
                ("\(cell.passed ? "PASS" : "FAIL")  \(cell.name)" as NSString).draw(
                    at: CGPoint(x: origin.x + 8, y: origin.y + 8),
                    withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
                        .foregroundColor: cell.passed ? UIColor.systemGreen : UIColor.systemRed,
                    ])
                guard let image = cell.image else { continue }
                let scale = (width - 16) / image.size.width
                let shown = CGRect(x: origin.x + 8, y: origin.y + label, width: width - 16, height: min(image.size.height * scale, height - 8))
                context.cgContext.saveGState()
                context.cgContext.clip(to: shown)
                image.draw(in: CGRect(x: shown.minX, y: shown.minY, width: image.size.width * scale, height: image.size.height * scale))
                context.cgContext.restoreGState()
            }
        }
        write(grid, to: ".", name: name)
    }

    static func write(_ image: UIImage?, to folder: String, name: String) {
        guard let image else { return }
        // ImageRenderer's bitmap for a very tall screen can fail to encode; redrawn, it encodes.
        func redrawn(_ image: UIImage) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
        }
        guard let data = image.pngData() ?? redrawn(image).pngData() else {
            print("Duo audit: couldn't write \(name), \(image.size) at \(image.scale)x")
            return
        }
        let directory = output.appending(path: folder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "\(name).png"))
    }
}
