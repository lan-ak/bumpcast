import ActivityKit
import AppIntents
import Foundation

/// Live Activity for a flight in progress. Everything it needs is on the phone, so it keeps
/// counting down with no connection: timers and the progress bar run on their own, and
/// staleDate re-renders it at the next stretch boundary.
struct FlightActivityAttributes: ActivityAttributes, Sendable {
    struct Stretch: Codable, Hashable, Sendable {
        let startMin: Int
        let endMin: Int
        /// smooth | light | moderate | severe
        let severity: String
        /// climb | cruise | descent
        var phase: String = "cruise"
        /// On a global outlook: whether this stretch is outlook (approximate, so it reads "Bumps
        /// possible" at rough times, never a single level) or confirmed. Nil elsewhere, and in
        /// pushes from before it was sent, when a global outlook's stretches all count as outlook.
        var outlook: Bool? = nil

        enum CodingKeys: String, CodingKey {
            case startMin, endMin, severity, phase, outlook
        }

        var level: Severity { Severity(rawValue: severity) ?? .light }
        var title: String { level.accessibilityName }
        var minutes: Int { endMin - startMin + 1 }
        /// Learn article that explains this kind of stretch.
        var explainerID: String { phase == "cruise" ? "clear-air" : "low-level" }
    }

    /// What can change while the activity runs: the takeoff it's timed to and the latest plan.
    /// The worker's wheels-up push replaces the whole state, with the same keys.
    struct ContentState: Codable, Hashable, Sendable {
        var takeoff: Date
        /// When the plan shown was last brought up to date: the app's last sync, or the worker's push.
        var updatedAt: Date
        /// The latest forecast's plan. Optional so pushes and activities from before it still
        /// decode; nil falls back to the attributes (the plan the activity started with).
        var durationMin: Int?
        var stretches: [Stretch]?
        var confidenceTitle: String?
        var issuedAt: Date?
    }

    let flightID: UUID
    let route: String
    /// The plan when the activity started. Read through `duration(_:)`, `stretches(_:)`,
    /// `confidence(_:)` and `issued(_:)`, which prefer the state's newer plan.
    let durationMin: Int
    let stretches: [Stretch]
    /// "Advance forecast" / "Partly confirmed" / "Confirmed forecast" / "Global outlook". Never a
    /// data source.
    var confidenceTitle: String = "Confirmed forecast"
    var issuedAt: Date?
}

extension FlightActivityAttributes.Stretch {
    /// `phase` and `outlook` may be missing from older pushes; synthesized decoding would drop the
    /// whole update.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startMin = try c.decode(Int.self, forKey: .startMin)
        endMin = try c.decode(Int.self, forKey: .endMin)
        severity = try c.decode(String.self, forKey: .severity)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "cruise"
        outlook = try c.decodeIfPresent(Bool.self, forKey: .outlook)
    }
}

extension FlightActivityAttributes {
    /// The plan shown: the state's when it carries one, else the one the activity started with.
    func stretches(_ state: ContentState) -> [Stretch] { state.stretches ?? stretches }
    func duration(_ state: ContentState) -> Int { state.durationMin ?? durationMin }
    func confidence(_ state: ContentState) -> String { state.confidenceTitle ?? confidenceTitle }
    /// When the plan shown was issued. A state with its own plan never borrows the older time.
    func issued(_ state: ContentState) -> Date? { state.durationMin != nil ? state.issuedAt : issuedAt }

    /// The badge the app gives a global outlook (and the worker's `confidence_title`).
    static let globalOutlookTitle = "Global outlook"

    /// A global outlook (beta) follows the outlook rules: it never says "smooth".
    func isGlobalOutlook(_ state: ContentState) -> Bool { confidence(state) == Self.globalOutlookTitle }

    /// An approximate stretch: "Bumps possible" with rough times, never a single level. Confirmed
    /// stretches stay exact, even on a global outlook.
    func isOutlook(_ stretch: Stretch, _ state: ContentState) -> Bool { stretch.outlook ?? isGlobalOutlook(state) }

    /// The glass for `date`: the level of the stretch in progress; between stretches smooth, or the
    /// empty outline on a global outlook, as the app shows it.
    func glass(at date: Date, _ state: ContentState) -> Severity? {
        if let (stretch, inProgress) = current(at: date, state), inProgress { return stretch.level }
        return isGlobalOutlook(state) ? nil : .smooth
    }

    func landing(_ state: ContentState) -> Date {
        state.takeoff.addingTimeInterval(TimeInterval(duration(state) * 60))
    }

    func start(of stretch: Stretch, _ state: ContentState) -> Date {
        state.takeoff.addingTimeInterval(TimeInterval(stretch.startMin * 60))
    }

    func end(of stretch: Stretch, _ state: ContentState) -> Date {
        state.takeoff.addingTimeInterval(TimeInterval((stretch.endMin + 1) * 60))
    }

    /// The next time what the activity shows changes in a way its timers can't follow: a stretch
    /// starting or ending, else landing. Not takeoff: the views read right through it, so with no
    /// connection the one re-render a stale date gives lands on the first stretch.
    func nextBoundary(after date: Date, _ state: ContentState) -> Date {
        let boundaries = stretches(state).flatMap { [start(of: $0, state), end(of: $0, state)] }.filter { $0 > date }
        return boundaries.min() ?? landing(state)
    }

    /// The stretch in progress or the next one, as of `date`.
    func current(at date: Date, _ state: ContentState) -> (Stretch, inProgress: Bool)? {
        for stretch in stretches(state) where end(of: stretch, state) > date {
            return (stretch, start(of: stretch, state) <= date)
        }
        return nil
    }
}

/// "How did it feel?" from the Live Activity after landing. Runs in the app process.
struct RateFlightIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Rate how the flight felt"

    @Parameter(title: "Flight") var flightID: String
    @Parameter(title: "Rating") var rating: String

    init() {}

    init(flightID: UUID, rating: FeltRating) {
        self.flightID = flightID.uuidString
        self.rating = rating.rawValue
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: flightID), let felt = FeltRating(rawValue: rating),
            let submit = await MainActor.run(body: { FlightRatingHandler.submit })
        {
            await submit(id, felt)
        }
        return .result()
    }
}

/// "End" on the Live Activity: takes it off the Lock Screen. Runs in the app process.
struct EndFlightActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End the bump countdown"

    @Parameter(title: "Flight") var flightID: String

    init() {}

    init(flightID: UUID) {
        self.flightID = flightID.uuidString
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: flightID), let end = await MainActor.run(body: { FlightRatingHandler.end }) {
            await end(id)
        }
        return .result()
    }
}

/// Set by the app at launch; the widget extension never runs the intents itself.
@MainActor
enum FlightRatingHandler {
    static var submit: (@MainActor (UUID, FeltRating) async -> Void)?
    static var end: (@MainActor (UUID) async -> Void)?
}
