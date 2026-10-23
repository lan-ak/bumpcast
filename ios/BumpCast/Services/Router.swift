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
    /// Opens Add flight on the Flights tab (the native onboarding, for people flying soon).
    var showAddFlight = false
    /// A short confirmation shown over the tabs ("YYZ → EWR added. First forecast…").
    private(set) var toast: String?
    /// The toast's symbol, so a note ("You're offline…") doesn't show a checkmark.
    private(set) var toastSymbol = "checkmark.circle.fill"
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// What Add flight wants once it has finished closing: open the forecast and/or show the toast.
    /// The presenting sheet's onDismiss runs it, so the sheet, the push and the toast never move at once.
    struct AfterAdd {
        let flightID: UUID
        let openForecast: Bool
        let toast: String?
    }

    var afterAdd: AfterAdd?

    func showToast(_ text: String, systemImage: String = "checkmark.circle.fill") {
        toast = text
        toastSymbol = systemImage
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toast = nil }
        }
    }

    /// Run by the Add flight presenter's sheet onDismiss.
    func finishAdding() {
        guard let after = afterAdd else { return }
        afterAdd = nil
        if after.openForecast { openFlight(after.flightID) }
        if let toast = after.toast { showToast(toast) }
    }

    /// Links and notifications made for a flight's old id (one saved again) open it under its new one.
    func openFlight(_ id: UUID) {
        tab = .flights
        flightPath = [InFlight.shared.currentID(of: id)]
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
