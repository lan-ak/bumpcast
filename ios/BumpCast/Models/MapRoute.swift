import CoreLocation
import Foundation
import MapKit

/// A flight's great-circle line for the map, sampled evenly from origin to destination.
struct MapRoute: Equatable {
    static let sampleCount = 121

    let flightID: UUID
    let routeText: String
    let points: [CLLocationCoordinate2D]
    let airMinutes: Double

    init?(flight: Flight, forecast: Forecast?) {
        guard let a = flight.originAirport, let b = flight.destinationAirport, a != b else { return nil }
        flightID = flight.id
        routeText = flight.routeText
        points = Self.greatCircle(
            CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
            CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon),
            count: Self.sampleCount)
        airMinutes = forecast?.durationMin.map(Double.init) ?? flight.estimatedAirMinutes
    }

    static func == (lhs: MapRoute, rhs: MapRoute) -> Bool {
        lhs.flightID == rhs.flightID && lhs.points.count == rhs.points.count
            && zip(lhs.points, rhs.points).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }

    /// The map rect around points `range` (the whole route by default).
    func mapRect(_ range: ClosedRange<Int>? = nil) -> MKMapRect {
        let slice = range.map { Array(points[$0]) } ?? points
        return slice.reduce(MKMapRect.null) { rect, point in
            let p = MKMapPoint(point)
            return rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
    }

    /// Minutes in the air covered by `count` route samples.
    func minutes(samples count: Int) -> Int {
        max(1, Int((Double(count) / Double(points.count - 1) * airMinutes).rounded()))
    }

    /// Distance from `coordinate` to the nearest point on the route, and that point's index.
    func nearest(to coordinate: CLLocationCoordinate2D) -> (index: Int, nm: Double) {
        var best = (index: 0, nm: Double.infinity)
        for (i, p) in points.enumerated() {
            let d = Geo.distanceNM(p, coordinate)
            if d < best.nm { best = (i, d) }
        }
        return best
    }

    static func greatCircle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, count: Int) -> [CLLocationCoordinate2D] {
        func vector(_ c: CLLocationCoordinate2D) -> SIMD3<Double> {
            let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
            return SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        }
        let va = vector(a), vb = vector(b)
        let angle = acos(min(1, max(-1, (va * vb).sum())))
        guard angle > 1e-6 else { return [a, b] }
        return (0..<count).map { k in
            let f = Double(k) / Double(count - 1)
            let v = va * (sin((1 - f) * angle) / sin(angle)) + vb * (sin(f * angle) / sin(angle))
            return CLLocationCoordinate2D(
                latitude: atan2(v.z, (v.x * v.x + v.y * v.y).squareRoot()) * 180 / .pi,
                longitude: atan2(v.y, v.x) * 180 / .pi)
        }
    }
}

enum Geo {
    static func distanceNM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let rad = Double.pi / 180
        let h = pow(sin((b.latitude - a.latitude) * rad / 2), 2)
            + cos(a.latitude * rad) * cos(b.latitude * rad) * pow(sin((b.longitude - a.longitude) * rad / 2), 2)
        return 2 * 3440.065 * asin(min(1, h.squareRoot()))
    }

    private static let cities = AirportStore.shared.all.filter(\.large)

    /// The nearest big-airport city, for plain-words places ("near Denver").
    static func nearestCity(to coordinate: CLLocationCoordinate2D) -> String? {
        cities.min {
            distanceNM(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon), coordinate)
                < distanceNM(CLLocationCoordinate2D(latitude: $1.lat, longitude: $1.lon), coordinate)
        }?.city
    }
}

/// One decoded map layer: the grid plus its severities, parsed once.
final class MapLayer: Identifiable {
    let grid: TurbulenceGrid
    let values: [Severity?]
    var id: String { "\(grid.levelFt)-\(grid.validAt.timeIntervalSince1970)" }

    init(_ grid: TurbulenceGrid) {
        self.grid = grid
        values = grid.severities()
    }

    func severity(at c: CLLocationCoordinate2D) -> Severity? {
        let j = Int(((grid.north - c.latitude) / grid.step).rounded())
        let i = Int(((c.longitude - grid.west) / grid.step).rounded())
        guard (0..<grid.ny).contains(j), (0..<grid.nx).contains(i) else { return nil }
        return values[j * grid.nx + i]
    }

    /// Share of cells with data at each severity, for the all-of-the-US summary.
    lazy var shares: [Severity: Double] = {
        var counts: [Severity: Int] = [:]
        var total = 0
        for case let value? in values {
            counts[value, default: 0] += 1
            total += 1
        }
        guard total > 0 else { return [:] }
        return counts.mapValues { Double($0) / Double(total) }
    }()

    /// Plain words for the whole map at this height.
    var usSummary: String {
        guard !shares.isEmpty else { return "No map data at this height yet." }
        let bumpy = [Severity.light, .moderate, .severe].filter { (shares[$0] ?? 0) >= 0.01 }
        guard !bumpy.isEmpty else { return "Smooth across the US at this height." }
        let parts = bumpy.reversed().map { severity -> String in
            "\(severity.phrase.lowercased()) over \(Int(((shares[severity] ?? 0) * 100).rounded()))%"
        }
        let headline = (shares[.smooth] ?? 0) >= 0.7 ? "Mostly smooth across the US" : "Bumps across parts of the US"
        return "\(headline) · \(parts.joined(separator: ", "))"
    }
}

/// Severity along a route at one height and time.
struct RouteProfile {
    let severities: [Severity?]

    init(route: MapRoute, layer: MapLayer) {
        severities = route.points.map(layer.severity(at:))
    }

    var hasData: Bool { severities.contains { $0 != nil } }

    /// The highest severity covering at least 3% of the route (single cells are noise).
    var overall: Severity? {
        guard hasData else { return nil }
        let threshold = max(2, severities.count * 3 / 100)
        for severity in [Severity.severe, .moderate, .light] where severities.filter({ $0 == severity }).count >= threshold {
            return severity
        }
        return .smooth
    }

    /// The longest unbroken stretch at `severity` or worse.
    func longestRun(atLeast severity: Severity) -> ClosedRange<Int>? {
        var best: ClosedRange<Int>?
        var start: Int?
        for (i, value) in severities.enumerated() {
            if let value, value >= severity {
                if start == nil { start = i }
                if let s = start, best.map({ $0.count < i - s + 1 }) ?? true { best = s...i }
            } else {
                start = nil
            }
        }
        return best
    }

    /// "Mostly smooth · Light chop near Denver for about 8 min"
    func summary(route: MapRoute) -> String {
        guard let overall else { return "No map data along your route at this height yet." }
        guard overall > .smooth, let run = longestRun(atLeast: overall) else { return "Smooth along your route at this height." }
        let middle = route.points[(run.lowerBound + run.upperBound) / 2]
        let place = Geo.nearestCity(to: middle).map { " near \($0)" } ?? ""
        return "\(overall.mapHeadline) · \(overall.phrase)\(place) for about \(route.minutes(samples: run.count)) min"
    }
}

extension Severity {
    /// How a stretch reads in a sentence: "Light chop near Denver".
    var phrase: String {
        switch self {
        case .smooth: "Smooth air"
        case .light: "Light chop"
        case .moderate: "Moderate bumps"
        case .severe: "Strong bumps"
        }
    }

    var mapHeadline: String {
        switch self {
        case .smooth: "Smooth"
        case .light: "Mostly smooth"
        case .moderate: "Some bumps"
        case .severe: "Bumpy in places"
        }
    }
}
