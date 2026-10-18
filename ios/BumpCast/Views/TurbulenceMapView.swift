import MapKit
import SwiftUI

/// NOAA turbulence by altitude, with recent pilot reports (Pro). Works in landscape.
struct TurbulenceMapView: View {
    static let levels = [10000, 18000, 24000, 30000, 34000, 38000, 42000]

    @Environment(FlightStore.self) private var store
    @Environment(Paywalls.self) private var paywalls
    @State private var level = 34000
    @State private var grids: [Int: [TurbulenceGrid]] = [:]
    @State private var timeIndex = 0
    @State private var reports: [PilotReport] = []
    @State private var showReports = false
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                TurbulenceMap(grid: currentGrid, reports: showReports ? visibleReports : [])
                    .ignoresSafeArea(edges: .bottom)
                controls
                    .padding()
            }
            .navigationTitle("Turbulence map")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if isLoading && currentGrid == nil {
                    ProgressView()
                } else if loadFailed && currentGrid == nil {
                    ContentUnavailableView("Map unavailable offline", systemImage: "wifi.slash",
                        description: Text("The map needs a connection. Your saved flight forecasts still work."))
                } else if !isLoading && grids[level]?.isEmpty == true {
                    ContentUnavailableView("Map data is updating", systemImage: "clock.arrow.circlepath",
                        description: Text("The latest turbulence layers will appear here shortly."))
                }
            }
            .task(id: level) { await loadGrids() }
            .onAppear { Task { await loadGrids() } }
            .task(id: showReports) { if showReports { await loadReports() } }
        }
    }

    private var times: [TurbulenceGrid] { grids[level] ?? [] }
    private var currentGrid: TurbulenceGrid? { times.indices.contains(timeIndex) ? times[timeIndex] : times.first }

    /// Reports within 5,000 ft of the selected level from the last 3 hours.
    private var visibleReports: [PilotReport] {
        reports.filter { report in
            guard let altitude = report.altitudeFt else { return true }
            return abs(altitude - level) <= 5000 && report.observedAt > .now.addingTimeInterval(-3 * 3600)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Altitude").font(.bcCaptionStrong)
                Picker("Altitude", selection: $level) {
                    ForEach(Self.levels, id: \.self) { Text(Self.label($0)).tag($0) }
                }
                .pickerStyle(.menu)
                Spacer()
                Toggle(isOn: reportsBinding) {
                    Label("Pilot reports", systemImage: paywalls.isPro || !paywalls.isConfigured ? "person.wave.2" : "lock")
                }
                .toggleStyle(.button)
                .font(.bcCaptionStrong)
            }
            if times.count > 1 {
                Picker("Time", selection: $timeIndex) {
                    ForEach(times.indices, id: \.self) { i in
                        Text(i == 0 ? "Now" : times[i].validAt.formatted(date: .omitted, time: .shortened)).tag(i)
                    }
                }
                .pickerStyle(.segmented)
            }
            HStack(spacing: 12) {
                ForEach([Severity.light, .moderate, .severe], id: \.self) { severity in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(severity.color.opacity(0.6)).frame(width: 12, height: 8)
                        Text(severity.title)
                    }
                }
                Spacer()
                if let grid = currentGrid {
                    Text("Updated \(grid.cycle.formatted(date: .omitted, time: .shortened))")
                }
            }
            .font(.bcCaption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }

    /// Pilot reports are Pro; the toggle goes through the paywall for free users.
    private var reportsBinding: Binding<Bool> {
        Binding(
            get: { showReports },
            set: { newValue in
                guard newValue else { showReports = false; return }
                paywalls.unlock(.pilotReportsLocked) { showReports = true }
            })
    }

    static func label(_ feet: Int) -> String { feet >= 18000 ? "FL\(feet / 100)" : "\(feet.formatted()) ft" }

    private func loadGrids() async {
        // NOAA runs hourly; refetch once the cached layers' first time step is over an hour old.
        if let first = grids[level]?.first, first.validAt > .now.addingTimeInterval(-3600) { return }
        isLoading = true
        defer { isLoading = false }
        do {
            grids[level] = try await store.service.turbulenceGrids(levelFt: level)
            timeIndex = 0
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func loadReports() async {
        reports = (try? await store.service.pilotReports(since: .now.addingTimeInterval(-3 * 3600))) ?? reports
    }
}

private struct TurbulenceMap: UIViewRepresentable {
    let grid: TurbulenceGrid?
    let reports: [PilotReport]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        // Muted base map so the turbulence colours stand out.
        map.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39, longitude: -97),
                span: MKCoordinateSpan(latitudeDelta: 32, longitudeDelta: 62)),
            animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        if context.coordinator.gridKey != grid.map(Coordinator.key) {
            map.removeOverlays(map.overlays)
            if let grid { map.addOverlay(GridOverlay(grid: grid), level: .aboveRoads) }
            context.coordinator.gridKey = grid.map(Coordinator.key)
        }
        let ids = Set(reports.map(\.id))
        if context.coordinator.reportIDs != ids {
            map.removeAnnotations(map.annotations)
            map.addAnnotations(reports.map(ReportAnnotation.init))
            context.coordinator.reportIDs = ids
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var gridKey: String?
        var reportIDs: Set<String> = []

        static func key(_ grid: TurbulenceGrid) -> String { "\(grid.levelFt)-\(grid.validAt.timeIntervalSince1970)" }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let overlay = overlay as? GridOverlay { return GridRenderer(overlay: overlay) }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let report = annotation as? ReportAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "report") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: report, reuseIdentifier: "report")
            view.annotation = report
            view.markerTintColor = UIColor(report.report.intensity.color)
            view.glyphImage = UIImage(systemName: "airplane")
            view.canShowCallout = true
            view.displayPriority = report.report.intensity >= .moderate ? .required : .defaultHigh
            return view
        }
    }
}

private final class ReportAnnotation: NSObject, MKAnnotation {
    let report: PilotReport
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(_ report: PilotReport) {
        self.report = report
        coordinate = CLLocationCoordinate2D(latitude: report.lat, longitude: report.lon)
        let altitude = report.altitudeFt.map { TurbulenceMapView.label($0) } ?? "unknown altitude"
        title = "\(report.intensity.title) at \(altitude)"
        subtitle = [report.aircraft, report.observedAt.formatted(.relative(presentation: .named))]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// The grid as runs of same-severity cells per row, pre-projected to map coordinates.
private final class GridOverlay: NSObject, MKOverlay {
    let grid: TurbulenceGrid
    let cells: [(rect: MKMapRect, severity: Severity)]
    let boundingMapRect: MKMapRect
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: grid.north - Double(grid.ny) * grid.step / 2, longitude: grid.west + Double(grid.nx) * grid.step / 2)
    }

    init(grid: TurbulenceGrid) {
        self.grid = grid
        let values = grid.severities()
        var cells: [(MKMapRect, Severity)] = []
        let half = grid.step / 2
        for j in 0..<grid.ny {
            let lat = grid.north - Double(j) * grid.step
            var i = 0
            while i < grid.nx {
                guard let severity = values[j * grid.nx + i], severity > .smooth else {
                    i += 1
                    continue
                }
                var end = i
                while end + 1 < grid.nx, values[j * grid.nx + end + 1] == severity { end += 1 }
                let nw = MKMapPoint(CLLocationCoordinate2D(latitude: lat + half, longitude: grid.west + Double(i) * grid.step - half))
                let se = MKMapPoint(CLLocationCoordinate2D(latitude: lat - half, longitude: grid.west + Double(end) * grid.step + half))
                cells.append((MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y), severity))
                i = end + 1
            }
        }
        self.cells = cells
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: grid.north + half, longitude: grid.west - half))
        let se = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: grid.north - Double(grid.ny) * grid.step, longitude: grid.west + Double(grid.nx) * grid.step))
        boundingMapRect = MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
    }
}

private final class GridRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? GridOverlay else { return }
        for (rect, severity) in overlay.cells where rect.intersects(mapRect) {
            context.setFillColor(UIColor(severity.color).withAlphaComponent(0.45).cgColor)
            context.fill(self.rect(for: rect))
        }
    }
}
