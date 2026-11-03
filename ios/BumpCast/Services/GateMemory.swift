import Foundation

/// The departure gate and terminal this phone has shown for each flight, so a change can say what
/// it was ("Gate B22, was B18"). Only what this device showed counts: a gate the airline changed
/// before anyone looked is never struck through, and "was" never comes from the server.
/// Approved Oct 27: docs/design/gate-changes.html.
enum GateMemory {
    struct Record: Codable, Equatable {
        /// The gate and terminal last shown.
        var gate: String?
        var terminal: String?
        /// What was shown before the latest change.
        var wasGate: String?
        var wasTerminal: String?
    }

    /// What to say about the gate now, given what this phone showed before.
    struct Change: Equatable {
        /// The previous gate, when the gate changed in the same terminal.
        var wasGate: String?
        /// The previous terminal, when the terminal changed, and the gate it had then, if any.
        var wasTerminal: String?
        var wasTerminalGate: String?
        /// The gate shown before it disappeared.
        var lastShownGate: String?

        var moved: Bool { wasGate != nil || wasTerminal != nil }
    }

    static func record(for id: UUID) -> Record? {
        UserDefaults.standard.data(forKey: key(id)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    static func save(_ record: Record, for id: UUID) {
        UserDefaults.standard.set(try? JSONEncoder().encode(record), forKey: key(id))
    }

    /// Notes the gate and terminal on screen now. Call from onAppear and onChange while the app is
    /// active, never from a view's body. A gate that disappears leaves the last one shown; a
    /// different one moves the last one to "was".
    static func note(_ status: FlightStatus?, for id: UUID) {
        guard let status, status.showsGate, status.departureGate != nil || status.departureTerminal != nil else { return }
        var record = record(for: id) ?? Record()
        let gate = status.departureGate, terminal = status.departureTerminal
        if gate == nil, record.gate != nil { return }
        guard gate != record.gate || terminal != record.terminal else { return }
        if record.gate != nil || record.terminal != nil {
            record.wasGate = record.gate
            record.wasTerminal = record.terminal
        }
        record.gate = gate
        record.terminal = terminal
        save(record, for: id)
    }

    static func change(_ status: FlightStatus, seen record: Record?) -> Change {
        guard let record, status.showsGate else { return Change() }
        let gate = status.departureGate, terminal = status.departureTerminal
        if gate == nil, let shown = record.gate { return Change(lastShownGate: shown) }
        // Only once the record has caught up with what's on screen.
        guard gate == record.gate, terminal == record.terminal else { return Change() }
        if let was = record.wasTerminal, was != terminal { return Change(wasTerminal: was, wasTerminalGate: record.wasGate) }
        if let was = record.wasGate, was != gate { return Change(wasGate: was) }
        return Change()
    }

    /// The flight was deleted, or is another departure now (date or flight number changed).
    static func remove(_ id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
    }

    /// The same trip saved again under a new id: what this phone showed still applies.
    static func move(from old: UUID, to new: UUID) {
        guard old != new else { return }
        if let record = record(for: old) { save(record, for: new) }
        remove(old)
    }

    /// Drops what's kept for flights no longer saved (deleted elsewhere, or before removal existed).
    /// Only with the full list from a good sync: before the first unlock the list can read empty.
    static func prune(keeping ids: Set<UUID>, in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            if let id = UUID(uuidString: String(key.dropFirst(prefix.count))), ids.contains(id) { continue }
            defaults.removeObject(forKey: key)
        }
    }

    private static let prefix = "gate.seen."
    private static func key(_ id: UUID) -> String { "\(prefix)\(id)" }
}
