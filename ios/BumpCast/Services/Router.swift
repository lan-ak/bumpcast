import Foundation
import Observation

/// App navigation, so notifications and Live Activity taps can open the right screen.
@Observable @MainActor
final class Router {
    static let shared = Router()

    enum Tab: Hashable { case flights, map, learn, calm }

    var tab: Tab = .flights
    var flightPath: [UUID] = []
    var learnPath: [Explainer] = []
    var showBreathing = false
    /// A short confirmation shown over the tabs ("YYZ → EWR added. First forecast…").
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toast = nil }
        }
    }

    func openFlight(_ id: UUID) {
        tab = .flights
        flightPath = [id]
    }

    /// bumpcast://flight/<id>, bumpcast://breathe and bumpcast://learn/<id> (used by the Live Activity).
    func handle(url: URL) {
        guard url.scheme == "bumpcast" else { return }
        switch url.host() {
        case "flight":
            if let id = UUID(uuidString: url.lastPathComponent) { openFlight(id) }
        case "breathe":
            showBreathing = true
        case "learn":
            tab = .learn
            learnPath = Explainer.byID(url.lastPathComponent).map { [$0] } ?? []
        default:
            break
        }
    }
}
