import SwiftUI

// Live flight status and published-schedule notes, free for every flight with a number.
// docs/design/flight-status-1.1-copy.md §1a, §2 and §3. Status never borrows the severity
// colours: ink and accent teal, with words carrying the meaning. Never say where status
// comes from, and never imply live tracking (no position, no "Landed").

extension Flight {
    /// Live status starts 48 hours before departure, with the forecast.
    var liveStatusStartsAt: Date { departureAt.addingTimeInterval(-Flight.forecastWindow) }

    var originTimeZone: TimeZone { originAirport?.timeZone ?? .current }
    var destinationTimeZone: TimeZone { destinationAirport?.timeZone ?? .current }
}

extension FlightStatus {
    var isDelayed: Bool { state == .delayed && (delayMin ?? 0) >= 5 }

    /// "Delayed 40 min", "On time", "Departed", "Cancelled", "Diverted".
    var headline: String {
        switch state {
        case .delayed?: "Delayed \((delayMin ?? 0).durationText)"
        case .departed?: "Departed"
        case .cancelled?: "Cancelled"
        case .diverted?: "Diverted"
        case .scheduled?, nil: "On time"
        }
    }

    var gateText: String? {
        switch (departureGate, departureTerminal) {
        case let (gate?, terminal?): "Gate \(gate) · Terminal \(terminal)"
        case let (gate?, nil): "Gate \(gate)"
        case let (nil, terminal?): "Terminal \(terminal) · Gate not set yet"
        case (nil, nil): nil
        }
    }

    var divertedAirport: Airport? { divertedTo.flatMap { AirportStore.shared.airport($0) } }
}

/// The compact status row on the flight card: gate, delays and cancellations, free for everyone.
struct LiveStatusRow: View {
    let flight: Flight

    var body: some View {
        if flight.flightNumber == nil || flight.expectedDeparture < .now.addingTimeInterval(-3 * 3600) {
            EmptyView()
        } else if flight.schedulePending {
            Label("We'll fill in the details when the airline publishes this flight.", systemImage: "calendar.badge.clock")
                .font(.bcCaptionStrong)
                .foregroundStyle(.secondary)
        } else {
            Label(text, systemImage: symbol)
                .font(.bcCaptionStrong)
                .foregroundStyle(flight.status?.isDelayed == true ? Theme.accent : Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String {
        guard let status = flight.status, status.hasStatus else {
            if Date.now < flight.liveStatusStartsAt {
                return "Live status starts \(flight.liveStatusStartsAt.formatted(.dateTime.weekday(.abbreviated)))"
            }
            // No row yet: the worker checks within a few minutes. A row without a status was checked.
            return flight.status == nil ? "Checking live status…" : "Live status isn't available for this flight"
        }
        let tz = flight.originTimeZone
        switch status.state {
        case .delayed? where status.isDelayed:
            var parts = [status.headline]
            if let expected = status.departureExpected { parts.append("now \(expected.localTime(in: tz))") }
            if let gate = status.departureGate { parts.append("Gate \(gate)") }
            return parts.joined(separator: " · ")
        case .departed?:
            return status.departureActual.map { "Departed \($0.localTime(in: tz))" } ?? "Departed"
        case .cancelled?:
            return "Cancelled"
        case .diverted?:
            return status.divertedAirport.map { "Diverted to \($0.iata)" } ?? "Diverted"
        default:
            return ["On time", status.gateText ?? "Gate not set yet"].joined(separator: " · ")
        }
    }

    private var symbol: String {
        switch flight.status?.state {
        case .delayed? where flight.status?.isDelayed == true: "clock.badge.exclamationmark"
        case .departed?: "airplane.departure"
        case .cancelled?: "xmark.circle"
        case .diverted?: "arrow.triangle.branch"
        default: "airplane"
        }
    }
}

/// The detail view's "Flight status" card.
struct FlightStatusSection: View {
    let flight: Flight
    let forecast: Forecast?

    var body: some View {
        if flight.flightNumber == nil || flight.schedulePending {
            EmptyView()
        } else if let status = flight.status, status.hasStatus {
            if status.state == .cancelled {
                EmptyView()  // CancelledCard replaces the forecast
            } else {
                card(status)
            }
        } else if Date.now < flight.liveStatusStartsAt {
            VStack(alignment: .leading, spacing: 6) {
                Text("Flight status").font(.bcSection)
                Text("Live status starts \(flight.liveStatusStartsAt.formatted(.dateTime.weekday(.wide))) around \(flight.liveStatusStartsAt.localTime(in: .current)), two days before you fly.")
                    .font(.bcSubheadline)
                    .foregroundStyle(.secondary)
            }
            .skyCard()
        } else if flight.expectedDeparture > .now.addingTimeInterval(-3600) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Flight status").font(.bcSection)
                Text(flight.status == nil
                    ? "Checking live status. It usually takes a few minutes after you add a flight."
                    : "Live status isn't available for this flight. Your forecast still uses the scheduled time.")
                    .font(.bcSubheadline)
                    .foregroundStyle(.secondary)
            }
            .skyCard()
        }
    }

    private func card(_ status: FlightStatus) -> some View {
        let from = flight.originAirport?.iata ?? flight.origin
        let to = flight.destinationAirport?.iata ?? flight.destination
        return VStack(alignment: .leading, spacing: 12) {
            Text("Flight status").eyebrow().foregroundStyle(.secondary)
            Text(status.headline)
                .font(.bcTitle2)
                .foregroundStyle(status.isDelayed ? Theme.accent : Theme.ink)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Scheduled").eyebrow()
                    Text("Expected").eyebrow()
                    Text("Actual").eyebrow()
                }
                .foregroundStyle(.secondary)
                GridRow {
                    Text("Departs (\(from))").font(.bcFootnoteStrong)
                    time(status.departureScheduled ?? flight.departureAt, flight.originTimeZone)
                    time(status.departureActual == nil ? status.departureExpected : nil, flight.originTimeZone)
                    time(status.departureActual, flight.originTimeZone)
                }
                GridRow {
                    Text("Arrives (\(to))").font(.bcFootnoteStrong)
                    time(status.arrivalScheduled ?? flight.arrivalAt, flight.destinationTimeZone)
                    time(status.arrivalActual == nil ? status.arrivalExpected : nil, flight.destinationTimeZone)
                    time(status.arrivalActual, flight.destinationTimeZone)
                }
            }
            Label(status.gateText ?? "Gate not set yet", systemImage: "door.left.hand.open")
                .font(.bcSubheadline)
            if let note = forecastNote(status) {
                Label(note, systemImage: "waveform.path")
                    .font(.bcSubheadline)
                    .foregroundStyle(Theme.accent)
            }
            Text(freshness(status)).font(.bcFootnote).foregroundStyle(.secondary)
        }
        .skyCard()
        .accessibilityElement(children: .contain)
    }

    private func time(_ date: Date?, _ tz: TimeZone) -> some View {
        Text(date.map { $0.localTime(in: tz) } ?? "–")
            .font(.bcMeta)
            .monospacedDigit()
            .accessibilityLabel(date.map { $0.localTime(in: tz) } ?? "none")
    }

    /// "Forecast updated for the new 7:55 AM departure. The bumps moved with it."
    private func forecastNote(_ status: FlightStatus) -> String? {
        guard status.isDelayed || (status.departureExpected.map { abs($0.timeIntervalSince(flight.departureAt)) >= 5 * 60 } ?? false),
            let expected = status.departureExpected, let forecast, forecast.status == .ready,
            let forecastFor = forecast.departureAt, abs(forecastFor.timeIntervalSince(expected)) < 60
        else { return nil }
        let time = expected.localTime(in: flight.originTimeZone)
        return "Forecast updated for the new \(time) departure. The bumps moved with it."
    }

    private func freshness(_ status: FlightStatus) -> String {
        let updated = "Updated \(status.checkedAt.localTime(in: .current))"
        if status.finished || status.nextCheckAt == nil {
            return "\(updated) · status updates have finished for this flight"
        }
        return "\(updated) · next update around \(status.nextCheckAt!.localTime(in: .current))"
    }
}

/// A cancelled flight: replaces the forecast.
struct CancelledCard: View {
    let flight: Flight
    let addFlight: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "xmark.circle").font(.bcTitle).foregroundStyle(.tint)
            Text("This flight is cancelled").font(.bcSection)
            Text("Your airline will be in touch about other options. When you have a new flight, add it and we'll forecast it.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Add a new flight", action: addFlight)
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                Button("Remove this flight", action: remove)
                    .buttonStyle(.bordered).tint(Theme.accent)
            }
            .font(.bcSubheadlineStrong)
        }
        .skyCard()
    }
}

/// A diverted flight: a calm note above the faded forecast.
struct DivertedCard: View {
    let flight: Flight

    var body: some View {
        let airport = flight.status?.divertedAirport
        VStack(alignment: .leading, spacing: 8) {
            Text(airport.map { "Diverted to \($0.city) (\($0.iata))" } ?? "Diverted").font(.bcSection)
            Text("Diversions are planned for and routine for the crew. Your airline will share what happens next.")
                .foregroundStyle(.secondary)
        }
        .skyCard()
    }
}

/// The one-time "Schedule published" note, from the worker's schedule notification.
struct ScheduleNote: View {
    let flight: Flight
    @Environment(FlightStore.self) private var store
    @AppStorage("schedule.notes.seen") private var seen = ""

    var body: some View {
        if let update = (store.updates[flight.id] ?? []).first(where: { $0.kind == "schedule" }),
            !seen.contains(update.id.uuidString)
        {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar.badge.checkmark").foregroundStyle(Theme.accent)
                Text(update.changes.first?.text ?? update.body).font(.bcSubheadline)
                Spacer(minLength: 0)
                Button {
                    seen += update.id.uuidString + ","
                } label: {
                    Image(systemName: "xmark").font(.bcFootnoteStrong).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
            }
            .skyCard(cornerRadius: 16, padding: 12)
            // One time: once it's been on screen, it's seen.
            .onDisappear { if !seen.contains(update.id.uuidString) { seen += update.id.uuidString + "," } }
        }
    }
}
