import Foundation

/// Mirrors the worker's coverage check (worker/src/smooth_worker/forecast.py): the
/// great-circle route must stay inside the box around NOAA's US forecast domain.
enum Coverage {
    static let latitude = 22.0...52.0
    static let longitude = -128.0 ... -64.0

    static func covers(_ flight: Flight) -> Bool {
        guard let a = flight.originAirport, let b = flight.destinationAirport else { return false }
        return covers(from: a, to: b)
    }

    static func covers(from a: Airport, to b: Airport, samples: Int = 40) -> Bool {
        (0...samples).allSatisfy { i in
            let (lat, lon) = intermediate(a, b, Double(i) / Double(samples))
            return latitude.contains(lat) && longitude.contains(lon)
        }
    }

    /// The airport (and its country) that puts a route outside coverage, for the waitlist.
    static func uncoveredAirport(_ flight: Flight) -> Airport? {
        let ends = [flight.destinationAirport, flight.originAirport].compactMap { $0 }
        return ends.first { !latitude.contains($0.lat) || !longitude.contains($0.lon) } ?? ends.first
    }

    /// The stretch of a route that leaves or lands in the box, as fractions of the way along it:
    /// the part a global outlook gets confirmed. Nil when the route stays inside, or never starts
    /// or ends inside.
    static func usPart(from a: Airport, to b: Airport, samples: Int = 80) -> (fractions: ClosedRange<Double>, isLanding: Bool)? {
        let inside = (0...samples).map { i in
            let (lat, lon) = intermediate(a, b, Double(i) / Double(samples))
            return latitude.contains(lat) && longitude.contains(lon)
        }
        if inside.allSatisfy({ $0 }) { return nil }
        if inside[0], let exit = inside.firstIndex(of: false) {
            return (0...Double(exit - 1) / Double(samples), false)
        }
        if inside[samples], let entry = inside.lastIndex(of: false) {
            return (Double(entry + 1) / Double(samples)...1, true)
        }
        return nil
    }

    static func intermediate(_ a: Airport, _ b: Airport, _ fraction: Double) -> (Double, Double) {
        let rad = Double.pi / 180
        let (lat1, lon1, lat2, lon2) = (a.lat * rad, a.lon * rad, b.lat * rad, b.lon * rad)
        let h = pow(sin((lat2 - lat1) / 2), 2) + cos(lat1) * cos(lat2) * pow(sin((lon2 - lon1) / 2), 2)
        let d = 2 * asin(sqrt(h))
        guard d > 0 else { return (a.lat, a.lon) }
        let s1 = sin((1 - fraction) * d) / sin(d)
        let s2 = sin(fraction * d) / sin(d)
        let x = s1 * cos(lat1) * cos(lon1) + s2 * cos(lat2) * cos(lon2)
        let y = s1 * cos(lat1) * sin(lon1) + s2 * cos(lat2) * sin(lon2)
        let z = s1 * sin(lat1) + s2 * sin(lat2)
        return (atan2(z, sqrt(x * x + y * y)) / rad, atan2(y, x) / rad)
    }
}
