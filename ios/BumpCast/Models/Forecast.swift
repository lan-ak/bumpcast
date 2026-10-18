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

    /// How settled the forecast is. NOAA's GTG reaches 18 hours ahead; anything
    /// beyond that is our early outlook from the global model and can still change.
    enum Confidence: Equatable {
        /// All our outlook. NOAA's forecast is expected to start covering the flight around `noaaExpected`.
        case early(noaaExpected: Date)
        /// NOAA covers the flight up to `confirmedUntilMin` minutes after takeoff; the rest is outlook.
        case partly(confirmedUntilMin: Int)
        /// The whole flight is covered by NOAA's GTG.
        case confirmed
    }

    /// NOAA's GTG horizon and how long after each hourly run it's published.
    static let noaaHorizon: TimeInterval = 18 * 3600
    static let noaaPublishLag: TimeInterval = 3600
    /// The worker assumes takeoff 15 minutes after scheduled departure (taxi-out).
    static let taxiOut: TimeInterval = 15 * 60

    func confidence(departure: Date) -> Confidence {
        let takeoff = departure.addingTimeInterval(Self.taxiOut)
        switch source {
        case "gtg":
            return .confirmed
        case "mixed":
            if let run = modelRun {
                let covered = run.addingTimeInterval(Self.noaaHorizon).timeIntervalSince(takeoff) / 60
                return .partly(confirmedUntilMin: max(0, Int(covered)))
            }
            return .partly(confirmedUntilMin: 0)
        default:
            return .early(noaaExpected: takeoff.addingTimeInterval(-Self.noaaHorizon + Self.noaaPublishLag))
        }
    }
}
