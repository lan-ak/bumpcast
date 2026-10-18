import Foundation

struct Forecast: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case ready
        case tooEarly = "too_early"
        case outOfCoverage = "out_of_coverage"
    }

    enum Grade: String, Codable, Sendable {
        case smooth
        case mostlySmooth = "mostly_smooth"
        case someBumps = "some_bumps"
        case bumpy
        case rough
    }

    struct Segment: Codable, Hashable, Sendable {
        let startMin: Int
        let endMin: Int
        let severity: Severity
        let peakEdr: Double
        let phase: String
        let altitudeFt: Int

        enum CodingKeys: String, CodingKey {
            case severity, phase
            case startMin = "start_min"
            case endMin = "end_min"
            case peakEdr = "peak_edr"
            case altitudeFt = "altitude_ft"
        }

        var minutes: Int { endMin - startMin + 1 }
    }

    struct Sample: Codable, Hashable, Sendable {
        let min: Int
        let edr: Double
        let altitudeFt: Int

        enum CodingKeys: String, CodingKey {
            case min, edr
            case altitudeFt = "altitude_ft"
        }

        var severity: Severity { Severity(edr: edr) }
    }

    let status: Status
    let issuedAt: Date?
    let source: String?
    let modelRun: Date?
    let grade: Grade?
    let score: Int?
    let durationMin: Int?
    let cruiseFt: Int?
    let segments: [Segment]
    let samples: [Sample]
    let route: [[Double]]

    enum CodingKeys: String, CodingKey {
        case status, source, grade, score, segments, samples, route
        case issuedAt = "issued_at"
        case modelRun = "model_run"
        case durationMin = "duration_min"
        case cruiseFt = "cruise_ft"
    }

    /// Inside 18 hours the forecast comes from NOAA's GTG; beyond that it's our outlook.
    var isOutlook: Bool { source == "gfs" }
}

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
