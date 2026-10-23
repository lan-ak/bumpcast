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

    /// Which kind of forecast covers each stretch: "gtg" is confirmed, "gfs" is outlook.
    struct SourceStretch: Codable, Hashable, Sendable {
        let startMin: Int
        let endMin: Int
        let source: String

        enum CodingKeys: String, CodingKey {
            case source
            case startMin = "start_min"
            case endMin = "end_min"
        }

        var isConfirmed: Bool { source == "gtg" }
        var minutes: ClosedRange<Int> { startMin...endMin }
    }

    /// An official warning (SIGMET) or a recent pilot report that raised part of the route.
    struct Warning: Codable, Hashable, Sendable {
        let startMin: Int
        let endMin: Int
        let kind: String  // sigmet | pirep
        let hazard: String  // turbulence | mountain_wave | thunderstorms | tropical_cyclone
        let severity: Severity
        var region: String? = nil

        enum CodingKeys: String, CodingKey {
            case kind, hazard, severity, region
            case startMin = "start_min"
            case endMin = "end_min"
        }

        var isOfficial: Bool { kind == "sigmet" }
        var minutes: Int { endMin - startMin + 1 }
    }

    let status: Status
    var issuedAt: Date?
    let source: String?
    let modelRun: Date?
    let grade: Grade?
    let score: Int?
    let durationMin: Int?
    let cruiseFt: Int?
    let segments: [Segment]
    let samples: [Sample]
    let route: [[Double]]
    /// The departure this forecast was computed for: the expected time when a delay moved it.
    var departureAt: Date? = nil
    /// Worldwide forecasts only (nil on older ones).
    var sources: [SourceStretch]? = nil
    var warnings: [Warning]? = nil
    /// False when the route leaves the area we forecast in full detail: it stays a global outlook.
    var noaaPossible: Bool? = nil
    /// The previous forecast moved to a delayed departure until a new one is worked out for it.
    var retimed: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case status, source, grade, score, segments, samples, route, sources, warnings, retimed
        case noaaPossible = "noaa_possible"
        case departureAt = "departure_at"
        case issuedAt = "issued_at"
        case modelRun = "model_run"
        case durationMin = "duration_min"
        case cruiseFt = "cruise_ft"
    }

    /// How settled the forecast is. Our detailed forecast reaches 18 hours ahead over the US;
    /// the rest is our outlook, which can still change.
    enum Confidence: Equatable {
        /// All outlook. The detailed forecast is expected to start covering the flight around `noaaExpected`.
        case early(noaaExpected: Date)
        /// These stretches (minutes after takeoff) are confirmed; the rest is outlook.
        case partly(confirmed: [ClosedRange<Int>])
        /// The whole flight is confirmed.
        case confirmed
        /// The route leaves the area we forecast in full detail, so it stays a global outlook
        /// (beta). Any stretches over the US are confirmed.
        case globalOutlook(confirmed: [ClosedRange<Int>])
    }

    /// The detailed forecast's horizon and how long after each hourly run it's published.
    static let noaaHorizon: TimeInterval = 18 * 3600
    static let noaaPublishLag: TimeInterval = 3600
    /// The worker assumes takeoff 15 minutes after scheduled departure (taxi-out).
    static let taxiOut: TimeInterval = 15 * 60

    var isGlobalOutlook: Bool { noaaPossible == false }

    /// Confirmed stretches from the worker's per-stretch sources, merged where they touch.
    var confirmedStretches: [ClosedRange<Int>] {
        (sources ?? []).filter(\.isConfirmed).map(\.minutes).reduce(into: []) { merged, range in
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
    }

    func confidence(departure: Date) -> Confidence {
        let takeoff = departure.addingTimeInterval(Self.taxiOut)
        if isGlobalOutlook { return .globalOutlook(confirmed: confirmedStretches) }
        if let sources, !sources.isEmpty {
            let confirmed = confirmedStretches
            if sources.allSatisfy(\.isConfirmed) { return .confirmed }
            if !confirmed.isEmpty { return .partly(confirmed: confirmed) }
            return .early(noaaExpected: takeoff.addingTimeInterval(-Self.noaaHorizon + Self.noaaPublishLag))
        }
        // Forecasts from before per-stretch sources: the detailed forecast covers the start of the flight.
        switch source {
        case "gtg":
            return .confirmed
        case "mixed":
            if let run = modelRun {
                let covered = Int(run.addingTimeInterval(Self.noaaHorizon).timeIntervalSince(takeoff) / 60)
                return .partly(confirmed: covered > 0 ? [0...(covered - 1)] : [])
            }
            return .partly(confirmed: [])
        default:
            return .early(noaaExpected: takeoff.addingTimeInterval(-Self.noaaHorizon + Self.noaaPublishLag))
        }
    }

    /// Whether this minute is outlook (approximate) rather than confirmed.
    func isOutlook(minute: Int, departure: Date) -> Bool {
        switch confidence(departure: departure) {
        case .early: true
        case .confirmed: false
        case .partly(let ranges), .globalOutlook(let ranges): !ranges.contains { $0.contains(minute) }
        }
    }

    /// Outlook stretches follow the beta trust rules: approximate times, ranges, no "smooth".
    func isOutlook(_ segment: Segment, departure: Date) -> Bool {
        isGlobalOutlook && isOutlook(minute: (segment.startMin + segment.endMin) / 2, departure: departure)
    }

    /// Global outlooks only count once the person turned the beta on: until then the app
    /// shows "Not forecast yet" and schedules nothing from them.
    var isShown: Bool { status == .ready && (!isGlobalOutlook || GlobalBeta.storedIsOn) }

    /// Rows for "What to expect". Outlook stretches less than half an hour apart become one
    /// approximate row (their rounded times would collide); confirmed and warned stretches stay as they are.
    func expectedStretches(departure: Date) -> [Segment] {
        var rows: [Segment] = []
        for segment in segments {
            let outlook = isOutlook(segment, departure: departure) && warning(for: segment) == nil
            if outlook, let last = rows.last, isOutlook(last, departure: departure), warning(for: last) == nil,
                segment.startMin - last.endMin < Self.outlookMergeGap
            {
                let stronger = segment.severity > last.severity ? segment : last
                rows[rows.count - 1] = Segment(
                    startMin: last.startMin, endMin: segment.endMin, severity: stronger.severity,
                    peakEdr: max(last.peakEdr, segment.peakEdr), phase: last.phase, altitudeFt: stronger.altitudeFt)
            } else {
                rows.append(segment)
            }
        }
        return rows
    }

    static let outlookMergeGap = 30

    var officialWarnings: [Warning] { (warnings ?? []).filter(\.isOfficial) }

    /// The warning or pilot report covering most of this stretch, official warnings first.
    func warning(for segment: Segment) -> Warning? {
        (warnings ?? [])
            .filter { $0.startMin <= segment.endMin && segment.startMin <= $0.endMin }
            .max { ($0.isOfficial ? 1 : 0, $0.minutes) < ($1.isOfficial ? 1 : 0, $1.minutes) }
    }
}
