import MapKit
import SwiftUI

/// A request to move the map, applied once per `id`.
struct MapFraming: Equatable {
    let id: Int
    let rect: MKMapRect
    static func == (lhs: MapFraming, rhs: MapFraming) -> Bool { lhs.id == rhs.id }
}

/// The MapKit view behind the turbulence map: soft turbulence fields, the route in deep teal
/// with a white casing, and round pilot-report markers.
struct TurbulenceMapLayer: UIViewRepresentable {
    let layer: MapLayer?
    /// Last layer kept on screen, faded, while a new one loads.
    let faded: Bool
    let route: [CLLocationCoordinate2D]
    let reports: [PilotReport]
    let framing: MapFraming?
    let insets: UIEdgeInsets
    let onSelectReport: (PilotReport) -> Void

    static let usRect: MKMapRect = {
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: 50, longitude: -126))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: 24, longitude: -66))
        return MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
    }()

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        // Muted base map so the turbulence colours stand out.
        let configuration = MKStandardMapConfiguration(emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = configuration
        map.showsCompass = false
        map.setVisibleMapRect(Self.usRect, edgePadding: insets, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectReport = onSelectReport
        coordinator.show(layer, faded: faded, on: map)
        coordinator.showRoute(route, on: map)
        coordinator.showReports(reports, on: map)
        if let framing, coordinator.framingID != framing.id {
            coordinator.framingID = framing.id
            map.setVisibleMapRect(framing.rect, edgePadding: insets, animated: coordinator.hasFramed)
            coordinator.hasFramed = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var framingID: Int?
        var hasFramed = false
        var onSelectReport: (PilotReport) -> Void = { _ in }
        private var current: GridOverlay?
        private var currentFaded = false
        private var routeCount = 0
        private var routeOverlays: [MKPolyline] = []
        private var reportIDs: Set<String> = []
        private var fadeTask: Task<Void, Never>?

        // MARK: Turbulence layer

        /// Swaps layers with a 0.4 s cross-fade (§4); fading the current one dims it in place.
        func show(_ layer: MapLayer?, faded: Bool, on map: MKMapView) {
            let target: CGFloat = faded ? 0.5 : 1
            guard layer?.id != current?.layer.id else {
                if faded != currentFaded, let current, let renderer = map.renderer(for: current) {
                    renderer.alpha = target
                    renderer.setNeedsDisplay()
                }
                currentFaded = faded
                return
            }
            let old = current
            let new = layer.map(GridOverlay.init)
            current = new
            currentFaded = faded
            if let new { map.addOverlay(new, level: .aboveRoads) }
            fadeTask?.cancel()
            let oldAlpha = old.flatMap { map.renderer(for: $0)?.alpha } ?? 1
            fadeTask = Task { [weak map] in
                let start = Date.now
                while !Task.isCancelled, let map {
                    let t = min(1, Date.now.timeIntervalSince(start) / 0.4)
                    if let new, let renderer = map.renderer(for: new) {
                        renderer.alpha = target * t
                        renderer.setNeedsDisplay()
                    }
                    if let old, let renderer = map.renderer(for: old) {
                        renderer.alpha = oldAlpha * (1 - t)
                        renderer.setNeedsDisplay()
                    }
                    if t >= 1 { break }
                    try? await Task.sleep(for: .milliseconds(33))
                }
                if let old { map?.removeOverlay(old) }
            }
        }

        // MARK: Route

        func showRoute(_ points: [CLLocationCoordinate2D], on map: MKMapView) {
            guard points.count != routeCount || (points.isEmpty && !routeOverlays.isEmpty) else { return }
            map.removeOverlays(routeOverlays)
            routeOverlays = []
            routeCount = points.count
            guard points.count >= 2 else { return }
            let casing = MKPolyline(coordinates: points, count: points.count)
            casing.title = "casing"
            let line = MKPolyline(coordinates: points, count: points.count)
            line.title = "route"
            routeOverlays = [casing, line]
            map.addOverlays(routeOverlays, level: .aboveLabels)
        }

        // MARK: Pilot reports

        func showReports(_ reports: [PilotReport], on map: MKMapView) {
            let ids = Set(reports.map(\.id))
            guard ids != reportIDs else { return }
            reportIDs = ids
            map.removeAnnotations(map.annotations)
            map.addAnnotations(reports.map(ReportAnnotation.init))
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let overlay = overlay as? GridOverlay {
                let renderer = GridRenderer(overlay: overlay)
                renderer.alpha = 0
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.lineCap = .round
                renderer.lineJoin = .round
                if line.title == "casing" {
                    renderer.strokeColor = .white
                    renderer.lineWidth = 8
                } else {
                    renderer.strokeColor = UIColor(Theme.routeInk)
                    renderer.lineWidth = 4
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let report = annotation as? ReportAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: ReportMarkerView.id) as? ReportMarkerView
                ?? ReportMarkerView(annotation: report, reuseIdentifier: ReportMarkerView.id)
            view.annotation = report
            view.configure(report.report.intensity)
            view.displayPriority = report.report.intensity >= .moderate ? .required : .defaultHigh
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let report = annotation as? ReportAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            onSelectReport(report.report)
        }
    }
}

extension Theme {
    /// The route line on the map: a deeper teal than the accent, so it reads over the fields.
    static let routeInk = Color(light: 0x1B5664, dark: 0x8FD3E0)
}

// MARK: - Pilot report markers

private final class ReportAnnotation: NSObject, MKAnnotation {
    let report: PilotReport
    let coordinate: CLLocationCoordinate2D

    init(_ report: PilotReport) {
        self.report = report
        coordinate = CLLocationCoordinate2D(latitude: report.lat, longitude: report.lon)
    }

    var title: String? {
        let height = report.altitudeFt.map(TurbulenceMapView.label) ?? "unknown height"
        return "Pilot report, \(report.intensity.title) at \(height)"
    }
}

/// A round severity dot with a white ring. No airplane glyph.
private final class ReportMarkerView: MKAnnotationView {
    static let id = "report"
    private let dot = CALayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // A 44 pt hit area around an 18 pt dot.
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        dot.frame = CGRect(x: 13, y: 13, width: 18, height: 18)
        dot.cornerRadius = 9
        dot.borderColor = UIColor.white.cgColor
        dot.borderWidth = 2.5
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOpacity = 0.2
        dot.shadowRadius = 2
        dot.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(dot)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ severity: Severity) {
        dot.backgroundColor = UIColor(Theme.color(severity)).cgColor
        accessibilityLabel = annotation?.title ?? nil
    }
}

// MARK: - Soft turbulence fields

/// The grid as one small image in map (Mercator) space: smooth cells transparent, bumps in
/// severity colours at about 45%, blurred so cells read as soft fields, not 0.25° squares.
private final class GridOverlay: NSObject, MKOverlay {
    let layer: MapLayer
    let image: CGImage?
    let boundingMapRect: MKMapRect
    var coordinate: CLLocationCoordinate2D { boundingMapRect.origin.coordinate }

    init(_ layer: MapLayer) {
        self.layer = layer
        let grid = layer.grid
        let half = grid.step / 2
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: grid.north + half, longitude: grid.west - half))
        let se = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: grid.north - Double(grid.ny - 1) * grid.step - half,
                longitude: grid.west + Double(grid.nx - 1) * grid.step + half))
        boundingMapRect = MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
        image = Self.render(layer, top: nw.y, bottom: se.y)
    }

    private static func render(_ layer: MapLayer, top: Double, bottom: Double) -> CGImage? {
        let grid = layer.grid
        let width = grid.nx, height = grid.ny * 2
        // Premultiplied RGBA per severity.
        let palette: [Severity: SIMD4<Float>] = Dictionary(
            uniqueKeysWithValues: [Severity.light, .moderate, .severe].map { severity in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(Theme.color(severity)).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                    .getRed(&r, green: &g, blue: &b, alpha: &a)
                let alpha: Float = 0.45
                return (severity, SIMD4(Float(r) * alpha, Float(g) * alpha, Float(b) * alpha, alpha))
            })
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
        for row in 0..<height {
            // Rows are evenly spaced in map space, so each samples the grid row at its latitude.
            let y = top + (Double(row) + 0.5) / Double(height) * (bottom - top)
            let lat = MKMapPoint(x: 0, y: y).coordinate.latitude
            let j = min(grid.ny - 1, max(0, Int(((grid.north - lat) / grid.step).rounded())))
            for i in 0..<width {
                if let severity = layer.values[j * grid.nx + i], let color = palette[severity] {
                    pixels[row * width + i] = color
                }
            }
        }
        pixels = blur(blur(pixels, width: width, height: height), width: width, height: height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (k, p) in pixels.enumerated() {
            bytes[k * 4] = UInt8(min(255, p.x * 255))
            bytes[k * 4 + 1] = UInt8(min(255, p.y * 255))
            bytes[k * 4 + 2] = UInt8(min(255, p.z * 255))
            bytes[k * 4 + 3] = UInt8(min(255, p.w * 255))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A 3×3 box blur.
    private static func blur(_ pixels: [SIMD4<Float>], width: Int, height: Int) -> [SIMD4<Float>] {
        var out = pixels
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD4<Float>.zero
                var n: Float = 0
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < height else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0, xx < width else { continue }
                        sum += pixels[yy * width + xx]
                        n += 1
                    }
                }
                out[y * width + x] = sum / n
            }
        }
        return out
    }
}

private final class GridRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? GridOverlay, let image = overlay.image else { return }
        context.interpolationQuality = .high
        UIGraphicsPushContext(context)
        UIImage(cgImage: image).draw(in: rect(for: overlay.boundingMapRect))
        UIGraphicsPopContext()
    }
}
