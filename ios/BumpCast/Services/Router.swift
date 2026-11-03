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
    /// Where the explainer opening now was opened from, for `explainer_opened`.
    @ObservationIgnored var explainerFrom = "learn"
    /// Where breathing was opened from, for `breathing_started`.
    @ObservationIgnored var breathingFrom = "calm"
    /// Opens Add flight on the Flights tab (the native onboarding, for people flying soon).
    var showAddFlight = false
    /// Where `showAddFlight` came from, for `flight_add_started`.
    var addFlightSource = "list"
    /// A short confirmation shown over the tabs ("YYZ → EWR added. First forecast…").
    private(set) var toast: String?
    /// The toast's symbol, so a note ("You're offline…") doesn't show a checkmark.
    private(set) var toastSymbol = "checkmark.circle.fill"
    /// Undo for what the toast reports (something done by itself, like an email import).
    private(set) var toastUndo: (@MainActor () -> Void)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// What Add flight wants once it has finished closing: open the forecast and/or show the toast.
    /// The presenting sheet's onDismiss runs it, so the sheet, the push and the toast never move at once.
    struct AfterAdd {
        let flightID: UUID
        let openForecast: Bool
        let toast: String?
    }

    var afterAdd: AfterAdd?

    /// With `undo`, the toast carries an Undo button and stays long enough to reach it.
    func showToast(_ text: String, systemImage: String = "checkmark.circle.fill", undo: (@MainActor () -> Void)? = nil) {
        toast = text
        toastSymbol = systemImage
        toastUndo = undo
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(undo == nil ? 4 : 8))
            if !Task.isCancelled {
                toast = nil
                toastUndo = nil
            }
        }
    }

    /// The toast's Undo button, when it has one: runs the undo and clears the toast.
    var toastUndoAction: (@MainActor () -> Void)? {
        guard toastUndo != nil else { return nil }
        return { [weak self] in self?.undoToast() }
    }

    func undoToast() {
        let undo = toastUndo
        toastTask?.cancel()
        toast = nil
        toastUndo = nil
        undo?()
    }

    /// Run by the Add flight presenter's sheet onDismiss.
    func finishAdding() {
        guard let after = afterAdd else { return }
        afterAdd = nil
        if after.openForecast { openFlight(after.flightID, from: "add_flight") }
        if let toast = after.toast { showToast(toast) }
    }

    /// Where the flight opening now was opened from, for `flight_opened`; nil is the list.
    @ObservationIgnored var openedFrom: String?

    /// Links and notifications made for a flight's old id (one saved again) open it under its new one.
    func openFlight(_ id: UUID, from source: String) {
        openedFrom = source
        tab = .flights
        flightPath = [InFlight.shared.currentID(of: id)]
    }

    /// bumpcast://flight/<id>, bumpcast://breathe and bumpcast://learn/<id> (used by the Live Activity).
    func handle(url: URL) {
        guard url.scheme == "bumpcast" else { return }
        switch url.host() {
        case "flight":
            if let id = UUID(uuidString: url.lastPathComponent) { openFlight(id, from: "live_activity") }
        case "breathe":
            breathingFrom = "live_activity"
            showBreathing = true
        case "learn":
            explainerFrom = "live_activity"
            tab = .learn
            learnPath = Explainer.byID(url.lastPathComponent).map { [$0] } ?? []

        default:
            break
        }
    }
}
