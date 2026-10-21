import ActivityKit
import AppIntents
import Foundation

/// Live Activity for a flight in progress. Everything it needs is in the attributes, so it
/// keeps counting down with no connection: timers and the progress bar run on their own, and
/// staleDate re-renders it at each stretch boundary.
struct FlightActivityAttributes: ActivityAttributes {
    struct Stretch: Codable, Hashable {
        let startMin: Int
        let endMin: Int
        /// smooth | light | moderate | severe
        let severity: String
        /// climb | cruise | descent
        var phase: String = "cruise"

        var level: Severity { Severity(rawValue: severity) ?? .light }
        var title: String { level.accessibilityName }
        var minutes: Int { endMin - startMin + 1 }
        /// Learn article that explains this kind of stretch.
        var explainerID: String { phase == "cruise" ? "clear-air" : "low-level" }
    }

    struct ContentState: Codable, Hashable {
        var takeoff: Date
        /// When the app last refreshed the activity.
        var updatedAt: Date
    }

    let flightID: UUID
    let route: String
    let durationMin: Int
    let stretches: [Stretch]
    /// "Advance forecast" / "Partly confirmed" / "Confirmed forecast". Never a data source.
    var confidenceTitle: String = "Confirmed forecast"
    var issuedAt: Date?
}

extension FlightActivityAttributes {
    func landing(_ state: ContentState) -> Date {
        state.takeoff.addingTimeInterval(TimeInterval(durationMin * 60))
    }

    func start(of stretch: Stretch, _ state: ContentState) -> Date {
        state.takeoff.addingTimeInterval(TimeInterval(stretch.startMin * 60))
    }

    func end(of stretch: Stretch, _ state: ContentState) -> Date {
        state.takeoff.addingTimeInterval(TimeInterval((stretch.endMin + 1) * 60))
    }

    /// The next time what the activity shows changes: a stretch starting or ending, else landing.
    func nextBoundary(after date: Date, _ state: ContentState) -> Date {
        let boundaries = stretches.flatMap { [start(of: $0, state), end(of: $0, state)] }.filter { $0 > date }
        return boundaries.min() ?? landing(state)
    }

    /// The stretch in progress or the next one, as of `date`.
    func current(at date: Date, _ state: ContentState) -> (Stretch, inProgress: Bool)? {
        for stretch in stretches where end(of: stretch, state) > date {
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
