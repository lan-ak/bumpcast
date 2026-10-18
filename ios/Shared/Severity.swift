import Foundation

/// Turbulence severity on the EDR scale. Shared by the app, widgets and Live Activity.
enum Severity: String, Codable, Comparable, CaseIterable, Sendable {
    case smooth, light, moderate, severe

    init(edr: Double) {
        switch edr {
        case 0.34...: self = .severe
        case 0.22...: self = .moderate
        case 0.10...: self = .light
        default: self = .smooth
        }
    }

    static func < (a: Severity, b: Severity) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}
