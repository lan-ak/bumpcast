import Foundation
import Observation

/// App navigation, so notifications and Live Activity taps can open the right screen.
@Observable @MainActor
final class Router {
    static let shared = Router()

    enum Tab: Hashable { case flights, map, calm }

    var tab: Tab = .flights
    var flightPath: [UUID] = []
    var showBreathing = false

    func openFlight(_ id: UUID) {
        tab = .flights
        flightPath = [id]
    }

    /// bumpcast://flight/<id> and bumpcast://breathe (used by the Live Activity).
    func handle(url: URL) {
        guard url.scheme == "bumpcast" else { return }
        switch url.host() {
        case "flight":
            if let id = UUID(uuidString: url.lastPathComponent) { openFlight(id) }
        case "breathe":
            tab = .calm
            showBreathing = true
        default:
            break
        }
    }
}
