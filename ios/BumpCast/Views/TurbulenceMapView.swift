import MapKit
import SwiftUI

/// The turbulence map (DESIGN_SPEC §3 item 9): opens on the next flight's route at its cruise
/// height, with an altitude ladder, a route card and pilot reports (Pro). Works in landscape.
struct TurbulenceMapView: View {
    /// Top to bottom, as the ladder shows them.
    static let levels = [42000, 38000, 34000, 30000, 24000, 18000, 10000]

    enum Scope: Hashable { case route, us }

    @Environment(FlightStore.self) private var store
    @Environment(Paywalls.self) private var paywalls
    @Environment(Router.self) private var router
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("haptics.enabled") private var hapticsEnabled = true

    @State private var level = 34000
    @State private var layers: [Int: [MapLayer]] = [:]
    /// When every height was last asked for.
    @State private var loadedAt: Date?
    /// Heights on screen from the copy saved on this phone, not yet replaced by a fresh load.
    @State private var savedLevels: Set<Int> = []
    /// Heights whose last request failed, asked for again on the next chance.
    @State private var failedLevels: Set<Int> = []
    /// What the saved copy holds (height, model run, time), so a new copy is written only when that changes.
    @State private var savedKey: Set<String> = []
    /// A load (or the offline check) has run, so an empty height is an answer, not a wait.
    @State private var hasTried = false
    @State private var timeIndex = 0
    @State private var scope = Scope.route
    @State private var reports: [PilotReport] = []
    @State private var showReports = false
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var framing: MapFraming?
    @State private var routeProgress = 0.0
    @State private var openedFlightID: UUID?
    @State private var selectedReport: PilotReport?
    @State private var showTeaser = false

    private var isLandscape: Bool { verticalSizeClass == .compact }

    private var flight: Flight? { store.nextFlight }
    private var forecast: Forecast? { flight.flatMap { store.forecasts[$0.id] } }
    private var route: MapRoute? { flight.flatMap { MapRoute(flight: $0, forecast: forecast) } }

    /// The flight's cruise height, snapped to a map level.
    private var cruiseLevel: Int? {
        guard let flight else { return nil }
        let cruise = forecast?.cruiseFt ?? (flight.estimatedAirMinutes < 75 ? 30000 : 36000)
        return Self.levels.min { abs($0 - cruise) < abs($1 - cruise) }
    }

    private var times: [MapLayer] { layers[level] ?? [] }
    private var layer: MapLayer? { times.indices.contains(timeIndex) ? times[timeIndex] : times.first }
    /// The time step closest to now; earlier ones aren't offered.
    private var nowIndex: Int {
        times.indices.min { abs(times[$0].grid.validAt.timeIntervalSinceNow) < abs(times[$1].grid.validAt.timeIntervalSinceNow) } ?? 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TurbulenceMapLayer(
                    layer: layer,
                    faded: isLoading && layer != nil,
                    route: visibleRoute,
                    reports: showReports ? visibleReports : [],
                    framing: framing,
                    insets: mapInsets,
                    onSelectReport: { selectedReport = $0 })
                .ignoresSafeArea()
                if isLandscape { landscapeChrome } else { portraitChrome }
                stateCard
            }
            .navigationTitle("Turbulence map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isLandscape ? .hidden : .visible, for: .navigationBar)
            .sensoryFeedback(.selection, trigger: level) { _, _ in hapticsEnabled }
            .task {
                if layers.isEmpty { await showSavedMap() }
                await loadAll()
            }
            .task(id: showReports) { if showReports { await loadReports() } }
            .onChange(of: route?.flightID) { openOnRoute() }
            // A refreshed forecast means a newer model run: pull fresh grids too.
            .onChange(of: forecast?.issuedAt ?? forecast?.modelRun) {
                if Connectivity.shared.isOnline { Task { await loadAll(maxAge: 0) } }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, Connectivity.shared.isOnline { Task { await loadAll(maxAge: 5 * 60) } }
            }
            // Back online with only a saved map, a height missing, or nothing: fetch the latest.
            // Pilot reports skipped while offline load now too.
            .onChange(of: Connectivity.shared.isOnline) { _, online in
                guard online, scenePhase == .active else { return }
                if !savedLevels.isEmpty || !failedLevels.isEmpty || layers.isEmpty { Task { await loadAll() } }
                if showReports { Task { await loadReports() } }
            }
            .onChange(of: cruiseLevel) { _, cruise in
                if let cruise { level = cruise }
            }
            .onChange(of: scope) { reframe() }
            .onChange(of: isLandscape) { reframe() }
            .sheet(item: $selectedReport) { report in
                PilotReportSheet(report: report, route: route, forecast: forecast) { id in
                    selectedReport = nil
                    router.openFlight(id)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showTeaser) {
                PilotReportsTeaser {
                    showTeaser = false
                    paywalls.unlock(.pilotReportsLocked) { showReports = true }
                }
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: Layout

    private var portraitChrome: some View {
        VStack(spacing: 0) {
            chips.padding(.horizontal).padding(.top, 8)
            Spacer(minLength: 12)
            HStack(alignment: .bottom) {
                Spacer()
                ladder
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
            bottomCard.padding([.horizontal, .bottom])
        }
    }

    private var landscapeChrome: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Turbulence map").font(.bcTitle2).accessibilityAddTraits(.isHeader)
                chips
                summaryBlock
                legend
                updatedLine
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            Spacer()
            ladder.frame(maxHeight: .infinity)
        }
        .padding(12)
    }

    /// Keeps the framed area clear of the chrome.
    private var mapInsets: UIEdgeInsets {
        isLandscape
            ? UIEdgeInsets(top: 30, left: 330, bottom: 30, right: 100)
            : UIEdgeInsets(top: 150, left: 24, bottom: 300, right: 96)
    }

    // MARK: Chips

    private var chips: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowChips {
                if route != nil {
                    Chip("My route", selected: scope == .route) { scope = .route }
                    Chip("All US", selected: scope == .us) { scope = .us }
                }
                Chip("Pilot reports", systemImage: "dot.radiowaves.up.forward", selected: showReports) { toggleReports() }
            }
            if times.count > 1 {
                FlowChips {
                    ForEach(Array(times.indices.dropFirst(nowIndex)), id: \.self) { i in
                        Chip(timeLabel(i), selected: i == timeIndex) {
                            withAnimation(.smooth(duration: 0.4)) { timeIndex = i }
                        }
                    }
                }
            }
        }
    }

    /// "Now · 12:00 PM", "+3 h · 3:00 PM".
    private func timeLabel(_ i: Int) -> String {
        let clock = times[i].grid.validAt.formatted(date: .omitted, time: .shortened)
        guard i != nowIndex else { return "Now · \(clock)" }
        let hours = Int((times[i].grid.validAt.timeIntervalSince(times[nowIndex].grid.validAt) / 3600).rounded())
        return "+\(hours) h · \(clock)"
    }

    // MARK: Altitude ladder

    private var ladder: some View {
        VStack(spacing: 2) {
            ForEach(Self.levels, id: \.self) { height in
                let severity = routeSeverity(at: height)
                Button {
                    withAnimation(.smooth(duration: 0.4)) { level = height }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(severity.map(Theme.color) ?? .clear)
                            .strokeBorder(severity == nil ? Theme.secondaryInk.opacity(0.5) : Theme.mapHalo.opacity(0.8), lineWidth: severity == nil ? 1 : 1.5)
                            .frame(width: 10, height: 10)
                        Text(Self.ladderLabel(height))
                            .font(.bcCaptionStrong)
                            .monospacedDigit()
                    }
                    .frame(width: 72, height: isLandscape ? 34 : 40)
                    .foregroundStyle(height == level ? Theme.onAccent : Theme.ink)
                    .background {
                        if height == level {
                            Capsule().fill(Theme.accent)
                        }
                    }
                    .overlay {
                        if height == cruiseLevel {
                            Capsule().strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ladderAccessibility(height, severity: severity))
                .accessibilityAddTraits(height == level ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Height")
    }

    nonisolated static func ladderLabel(_ feet: Int) -> String { feet >= 18000 ? "FL\(feet / 100)" : "\(feet / 1000)k ft" }
    nonisolated static func label(_ feet: Int) -> String { feet >= 18000 ? "FL\(feet / 100)" : "\(feet.formatted()) ft" }

    private func ladderAccessibility(_ height: Int, severity: Severity?) -> String {
        var parts = [Self.label(height)]
        if let severity, route != nil { parts.append("\(severity.title.lowercased()) on your route") }
        if height == cruiseLevel { parts.append("your cruise height") }
        return parts.joined(separator: ", ")
    }

    /// The route's severity at `height`, at the selected time.
    private func routeSeverity(at height: Int) -> Severity? {
        guard let route, let layers = layers[height], !layers.isEmpty else { return nil }
        let layer = layers.indices.contains(timeIndex) ? layers[timeIndex] : layers[0]
        return RouteProfile(route: route, layer: layer).overall
    }

    // MARK: Route card

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryBlock
            legend
            updatedLine
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    @ViewBuilder private var summaryBlock: some View {
        if scope == .route, let route {
            let profile = layer.map { RouteProfile(route: route, layer: $0) }
            HStack(alignment: .top, spacing: 12) {
                WaterGlass(severity: profile?.overall, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(route.routeText) at \(Self.label(level))").font(.bcCardTitle)
                    Text(profile?.summary(route: route) ?? (loadFailed ? "No map for your route yet." : "Loading the map for your route…"))
                        .font(.bcSubheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("All US at \(Self.label(level))").font(.bcCardTitle)
                Text(layer?.usSummary ?? (loadFailed ? "No map yet." : "Loading the map…"))
                    .font(.bcSubheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var legend: some View {
        ViewThatFits {
            HStack(spacing: 12) { legendItems }
            VStack(alignment: .leading, spacing: 6) { legendItems }
        }
        .font(.bcCaption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var legendItems: some View {
        ForEach([Severity.light, .moderate, .severe], id: \.self) { severity in
            HStack(spacing: 5) {
                Circle().fill(Theme.color(severity).opacity(0.6)).frame(width: 10, height: 10)
                Text(severity.title)
            }
        }
        Text("Clear = smooth")
    }

    @ViewBuilder private var updatedLine: some View {
        if let layer {
            Text(updatedText(layer))
                .font(.bcMeta)
                .foregroundStyle(.secondary)
        }
    }

    /// "Updated 2:00 PM", "Saved map · updated 2:00 PM" (with the weekday when not today), or
    /// "Updating · showing the 3:00 PM layer". The time is the height's own model run.
    private func updatedText(_ layer: MapLayer) -> String {
        if isLoading {
            return "Updating · showing the \(layer.grid.validAt.formatted(date: .omitted, time: .shortened)) layer"
        }
        if savedLevels.contains(level) {
            return "Saved map · updated \(OfflineCopy.time(layer.grid.cycle))"
        }
        return "Updated \(layer.grid.cycle.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: States

    @ViewBuilder private var stateCard: some View {
        if layer == nil {
            let online = Connectivity.shared.isOnline
            VStack(alignment: .leading, spacing: 10) {
                if loadFailed, !online {
                    Label("The map needs a connection", systemImage: "wifi.slash").font(.bcCardTitle)
                    Text("Your saved flight forecasts still work without one.")
                        .font(.bcSubheadline).foregroundStyle(.secondary)
                    if let flight {
                        Button("Open my forecast") { router.openFlight(flight.id) }
                            .font(.bcSubheadlineStrong)
                            .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                            .tint(Theme.accent)
                    }
                } else if loadFailed {
                    Label("The map didn't load", systemImage: "exclamationmark.arrow.circlepath").font(.bcCardTitle)
                    Text("Your saved flight forecasts still work.")
                        .font(.bcSubheadline).foregroundStyle(.secondary)
                    tryAgainButton
                } else if isLoading || !hasTried {
                    // Also before the first load has started, so "updating" never flashes first.
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading the map…").font(.bcSubheadline)
                    }
                } else if !online {
                    // Other heights are saved, this one isn't, and nothing can arrive offline.
                    Label("No saved map at this height", systemImage: "wifi.slash").font(.bcCardTitle)
                    Text("Pick another height, or connect to load this one.")
                        .font(.bcSubheadline).foregroundStyle(.secondary)
                } else if failedLevels.contains(level) {
                    Label("This height didn't load", systemImage: "exclamationmark.arrow.circlepath").font(.bcCardTitle)
                    Text("Pick another height, or try again.")
                        .font(.bcSubheadline).foregroundStyle(.secondary)
                    tryAgainButton
                } else {
                    // Loaded, with no layers yet for this height.
                    Label("The map is updating", systemImage: "clock.arrow.circlepath").font(.bcCardTitle)
                    Text("The latest layers will appear here shortly.")
                        .font(.bcSubheadline).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: 340, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding()
        }
    }

    private var tryAgainButton: some View {
        Button("Try again") { Task { await loadAll() } }
            .font(.bcSubheadlineStrong)
            .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
            .tint(Theme.accent)
            .disabled(isLoading)
    }

    // MARK: Behaviour

    private var visibleRoute: [CLLocationCoordinate2D] {
        guard let route else { return [] }
        let count = Int((Double(route.points.count) * routeProgress).rounded())
        return Array(route.points.prefix(max(0, count)))
    }

    /// Reports within 5,000 ft of the selected height from the last 3 hours.
    private var visibleReports: [PilotReport] {
        reports.filter { report in
            guard report.observedAt > .now.addingTimeInterval(-3 * 3600) else { return false }
            guard let altitude = report.altitudeFt else { return true }
            return abs(altitude - level) <= 5000
        }
    }

    private func toggleReports() {
        if showReports { showReports = false; return }
        if paywalls.isPro || !paywalls.isConfigured { showReports = true } else { showTeaser = true }
    }

    /// First open with a flight: its cruise height, the time nearest now, framed on the
    /// bumpiest stretch; the route draws from origin to destination.
    private func openOnRoute() {
        guard let route, openedFlightID != route.flightID else {
            if route == nil { scope = .us; reframe() }
            return
        }
        openedFlightID = route.flightID
        scope = .route
        if let cruiseLevel { level = cruiseLevel }
        timeIndex = nowIndex
        reframe()
        drawRoute()
    }

    private func drawRoute() {
        guard !reduceMotion else { routeProgress = 1; return }
        routeProgress = 0
        Task {
            let steps = 30
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(30))
                routeProgress = Double(step) / Double(steps)
            }
        }
    }

    private func reframe() {
        let rect: MKMapRect
        if scope == .route, let route {
            rect = bumpiestRect(route) ?? route.mapRect()
        } else {
            rect = TurbulenceMapLayer.usRect
        }
        framing = MapFraming(id: (framing?.id ?? 0) + 1, rect: rect)
    }

    /// The bumpiest stretch at this height, with some route either side for context.
    private func bumpiestRect(_ route: MapRoute) -> MKMapRect? {
        guard let layer else { return nil }
        let profile = RouteProfile(route: route, layer: layer)
        guard let overall = profile.overall, overall > .smooth, let run = profile.longestRun(atLeast: overall) else { return nil }
        let pad = max(12, run.count)
        let range = max(0, run.lowerBound - pad)...min(route.points.count - 1, run.upperBound + pad)
        return route.mapRect(range)
    }

    /// The copy saved on the phone, so the map opens at once and works offline. Layers more
    /// than 3 hours past are left out: they no longer describe the sky. So are heights the ladder
    /// doesn't have (1.0.1 saved every layer under height 0; see `HeightLoad`).
    private func showSavedMap() async {
        // Decoding about a megabyte of grids stays off the main thread.
        guard let saved = await Task.detached(priority: .userInitiated, operation: { LocalStore.shared.loadMap() }).value
        else { return }
        let cutoff = Date.now.addingTimeInterval(-3 * 3600)
        let grids = saved.grids.mapValues { $0.filter { $0.validAt >= cutoff } }
            .filter { Self.levels.contains($0.key) && !$0.value.isEmpty }
        savedKey = Self.key(saved.grids)
        guard layers.isEmpty, !grids.isEmpty else { return }
        layers = grids.mapValues { $0.map(MapLayer.init) }
        savedLevels = Set(grids.keys)
        timeIndex = nowIndex
        openOnRoute()
    }

    private func loadAll(maxAge: TimeInterval = 30 * 60) async {
        let isRecent = loadedAt.map { $0 > .now.addingTimeInterval(-maxAge) } ?? false
        if isRecent, failedLevels.isEmpty, !layers.isEmpty {
            openOnRoute()
            return
        }
        // Offline: keep the saved map up and skip the spinner. Without one, say it needs a connection.
        guard Connectivity.shared.isOnline else {
            loadFailed = layers.isEmpty
            hasTried = true
            openOnRoute()
            return
        }
        guard !isLoading else { return }
        let selectedTime = layer?.grid.validAt
        isLoading = true
        defer { isLoading = false }
        let service = store.service
        // The cruise height is asked for first. Each height loads on its own, so one slow or
        // dropped level doesn't lose the others; a failed one keeps what was on screen and is asked
        // for again next time. A recent load only asks again for the heights that failed.
        let all = cruiseLevel.map { cruise in [cruise] + Self.levels.filter { $0 != cruise } } ?? Self.levels
        let order = isRecent ? all.filter(failedLevels.contains) : all
        var fresh: [Int: [TurbulenceGrid]] = [:]
        var failed: Set<Int> = []
        var failure: Error?
        await withTaskGroup(of: HeightLoad.self) { group in
            for height in order {
                group.addTask {
                    do { return HeightLoad(height: height, result: .success(try await service.turbulenceGrids(levelFt: height))) }
                    catch { return HeightLoad(height: height, result: .failure(error)) }
                }
            }
            for await load in group {
                switch load.result {
                case .success(let grids): fresh[load.height] = grids
                case .failure(let error):
                    failed.insert(load.height)
                    failure = error
                }
            }
        }
        failedLevels = failed
        hasTried = true
        if fresh.isEmpty {
            if let failure { Connectivity.shared.noteFailure(failure) }
            loadFailed = layers.isEmpty
        } else {
            Connectivity.shared.noteSuccess()
            var merged = layers
            for (height, grids) in fresh { merged[height] = grids.map(MapLayer.init) }
            withAnimation(.smooth(duration: 0.4)) { layers = merged }
            if !isRecent { loadedAt = .now }
            savedLevels.subtract(fresh.keys)
            loadFailed = false
            saveIfChanged(merged)
        }
        // Keep the hour the user was looking at if the new run still has it.
        if openedFlightID == nil {
            timeIndex = nowIndex
        } else if let selectedTime {
            timeIndex = max(nowIndex, times.firstIndex { $0.grid.validAt == selectedTime } ?? nowIndex)
        }
        openOnRoute()
    }

    /// One height's answer from the task group. A struct on purpose: with optimisation on, Swift 6.4
    /// hands an `(Int, Result<…, Error>)` tuple back from a task group with the Int lost (always 0),
    /// so release builds filed every height under 0 and the map sat on "updating" for good.
    private struct HeightLoad: Sendable {
        let height: Int
        let result: Result<[TurbulenceGrid], Error>
    }

    /// Keeps a copy on the phone for next time and for offline, written only when what it holds
    /// changes: a new model run, or a height that loaded after an earlier load missed it (about a
    /// megabyte each time).
    private func saveIfChanged(_ shown: [Int: [MapLayer]]) {
        let grids = shown.mapValues { $0.map(\.grid) }
        let key = Self.key(grids)
        guard !key.isEmpty, key != savedKey else { return }
        savedKey = key
        let snapshot = MapSnapshot(grids: grids, savedAt: .now)
        Task { await LocalStore.shared.saveMap(snapshot) }
    }

    /// Every layer's height, model run and time.
    private static func key(_ grids: [Int: [TurbulenceGrid]]) -> Set<String> {
        Set(grids.flatMap { height, list in
            list.map { "\(height)|\($0.cycle.timeIntervalSince1970)|\($0.validAt.timeIntervalSince1970)" }
        })
    }

    private func loadReports() async {
        guard Connectivity.shared.isOnline else { return }
        reports = (try? await store.service.pilotReports(since: .now.addingTimeInterval(-3 * 3600))) ?? reports
    }
}

// MARK: - Chips

private struct Chip: View {
    let title: String
    var systemImage: String?
    let selected: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.bcSubheadlineStrong)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundStyle(selected ? Theme.onAccent : Theme.ink)
            .background { if selected { Capsule().fill(Theme.accent) } }
            .glassEffect(selected ? .identity : .regular, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row of chips that scrolls when it doesn't fit.
private struct FlowChips<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }.padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

// MARK: - Pilot report sheet

private struct PilotReportSheet: View {
    let report: PilotReport
    let route: MapRoute?
    let forecast: Forecast?
    let openForecast: (UUID) -> Void

    private var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: report.lat, longitude: report.lon) }
    private var nearest: (index: Int, nm: Double)? { route?.nearest(to: coordinate) }
    private var onRoute: Bool { (nearest?.nm ?? .infinity) <= 50 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pilot report · \(ago)").eyebrow().foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    WaterGlass(severity: report.intensity, size: 34)
                    Text(headline).font(.bcTitle)
                }
                HStack(spacing: 10) {
                    tile("Height", report.altitudeFt.map(TurbulenceMapView.label) ?? "Not given")
                    tile("Aircraft", report.aircraft ?? "Not given")
                    tile("Your route", distanceText)
                }
                Text("Pilots share what they feel so the crews behind them can pick a smoother height. Most reports are routine.")
                    .font(.bcSubheadline)
                    .foregroundStyle(.secondary)
                if onRoute, let route, let note = forecastNote {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(note).font(.bcSubheadline)
                        Button("Open my forecast") { openForecast(route.flightID) }
                            .font(.bcSubheadlineStrong)
                            .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                            .tint(Theme.accent)
                    }
                    .skyCard()
                }
            }
            .padding(20)
        }
        .skyBackground(.day)
    }

    private var ago: String {
        let minutes = max(1, Int(-report.observedAt.timeIntervalSinceNow / 60))
        return minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h \(minutes % 60) min ago"
    }

    private var headline: String {
        let place = Geo.nearestCity(to: coordinate).map { " near \($0)" } ?? ""
        return "\(report.intensity.phrase.sentenceCased)\(place)"
    }

    private var distanceText: String {
        guard let nearest else { return "No flight" }
        if nearest.nm < 5 { return "Right on it" }
        return Measurement(value: nearest.nm, unit: UnitLength.nauticalMiles)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0)))) + " away"
    }

    /// What the user's own forecast expects at the matching point of their flight.
    private var forecastNote: String? {
        guard let route, let nearest, let forecast, forecast.status == .ready, let duration = forecast.durationMin else { return nil }
        let minute = Int(Double(nearest.index) / Double(route.points.count - 1) * Double(duration))
        guard let segment = forecast.segments.first(where: { $0.startMin <= minute && minute <= $0.endMin }) else { return nil }
        if segment.severity > .smooth {
            return "Your forecast already expects \(segment.severity.title.lowercased()) here for about \(segment.minutes) minutes."
        }
        return "Your forecast expects smooth air here at your time. It keeps updating until you fly."
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).eyebrow().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(.bcHeadline).lineLimit(1).minimumScaleFactor(0.7)
        }
        .skyCard(cornerRadius: 16, padding: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Free users: a calm invitation instead of a lock.
private struct PilotReportsTeaser: View {
    let seeOptions: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.bcSymbolHero)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("See what pilots are feeling right now").font(.bcTitle)
            Text("Pilots report the bumps they feel. With Pro, the last three hours of reports appear on the map at your height, next to your route.")
                .font(.bcBody)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: seeOptions) {
                Text("See Pro options").font(.bcHeadline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
            .tint(Theme.accent)
            .controlSize(.large)
            Button("Not now") { dismiss() }
                .font(.bcSubheadlineStrong)
                .frame(maxWidth: .infinity)
                .tint(Theme.accent)
        }
        .padding(24)
        .skyBackground(.day)
    }
}
