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

extension Severity {
    /// In a sentence: "Then light chop for about 4 min", "Moderate bumps in about 2 minutes".
    /// Matches the worker's notification wording.
    var phrase: String {
        switch self {
        case .smooth: "smooth air"
        case .light: "light chop"
        case .moderate: "moderate bumps"
        case .severe: "strong bumps"
        }
    }
}

extension String {
    /// "moderate bumps" -> "Moderate bumps", for a phrase that starts a sentence.
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}
