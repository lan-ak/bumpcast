import ActivityKit
import Foundation

/// Live Activity for a flight in progress. Everything it needs is in the attributes, so it
/// keeps counting down with no connection: the progress bar and timers run on their own.
struct FlightActivityAttributes: ActivityAttributes {
    struct Stretch: Codable, Hashable {
        let startMin: Int
        let endMin: Int
        /// smooth | light | moderate | severe
        let severity: String

        var title: String {
            switch severity {
            case "severe": "Strong bumps"
            case "moderate": "Moderate bumps"
            default: "Light chop"
            }
        }
    }

    struct ContentState: Codable, Hashable {
        var takeoff: Date
        /// When the app last refreshed the activity; "next stretch" is worked out from here.
        var updatedAt: Date
    }

    let flightID: UUID
    let route: String
    let durationMin: Int
    let stretches: [Stretch]
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

    /// The next time the "current stretch" text changes: a stretch starting or ending, else landing.
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
