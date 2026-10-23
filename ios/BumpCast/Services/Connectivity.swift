import Foundation
import Network
import Observation

/// The one place the app asks whether it can reach the internet. The path says whether there's a
/// network at all (airplane mode: no). Plane and hotel wifi often report a path but drop every
/// request, so a request that just failed for connection reasons also counts as offline until one
/// succeeds, the network changes, or a little time has passed and it's worth another try.
@Observable @MainActor
final class Connectivity {
    static let shared = Connectivity()

    /// There's a network (wifi or cellular). False in airplane mode.
    private(set) var hasPath = !Connectivity.debugForceOffline
    /// A request just failed for connection reasons on this network (captive or plane wifi).
    private(set) var isDegraded = false
    var isOnline: Bool { hasPath && !isDegraded }

    /// The phone has a usable network again: after none, after a network change, or when a failed
    /// connection is due another try.
    @ObservationIgnored var onReconnect: (@MainActor () -> Void)?

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var started = false
    /// The interfaces in use, so path updates that only change a flag don't count as a new network.
    @ObservationIgnored private var interfaces: [String] = []
    @ObservationIgnored private var retry: Task<Void, Never>?

    /// How long a failed connection counts as offline before automatic work tries it again.
    /// Pull-to-refresh only needs a path, so people can always try sooner.
    static let retryAfter: Duration = .seconds(90)

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied && !Connectivity.debugForceOffline
            let interfaces = path.availableInterfaces.map(\.name)
            Task { @MainActor in Connectivity.shared.pathChanged(up, interfaces: interfaces) }
        }
        monitor.start(queue: DispatchQueue(label: "bumpcast.connectivity"))
    }

    private func pathChanged(_ up: Bool, interfaces: [String]) {
        let changed = up != hasPath || interfaces != self.interfaces
        self.interfaces = interfaces
        guard changed else { return }
        let was = isOnline
        hasPath = up
        // A new network gets a fresh try.
        clearDegraded()
        if up, !was { onReconnect?() }
    }

    func noteSuccess() { clearDegraded() }

    func noteFailure(_ error: Error) {
        guard error.isConnectivityFailure, hasPath else { return }
        if !isDegraded { isDegraded = true }
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: Self.retryAfter)
            guard !Task.isCancelled, let self, self.isDegraded else { return }
            self.isDegraded = false
            if self.hasPath { self.onReconnect?() }
        }
    }

    private func clearDegraded() {
        retry?.cancel()
        retry = nil
        if isDegraded { isDegraded = false }
    }

    /// Debug builds: launch with `-forceOffline` to see the app with no connection.
    nonisolated static var debugForceOffline: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("-forceOffline")
        #else
            false
        #endif
    }
}

extension Error {
    /// No connection, or one that isn't reaching the internet (captive or plane wifi).
    var isConnectivityFailure: Bool {
        guard let code = (self as? URLError)?.code else { return false }
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed,
            .cannotLoadFromNetwork, .appTransportSecurityRequiresSecureConnection, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
            .badServerResponse, .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}
