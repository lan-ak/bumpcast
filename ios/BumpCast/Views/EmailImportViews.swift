import SwiftUI

// Adding flights from your email (E1, revision 2): connect once, and every booked flight is
// added and kept up to date. Calm, plain words in ink; the user's own mailbox is named, never a
// data source. No red, no warning symbols, no warning haptics.

/// Opened from Find and Settings: connect, then the first scan's progress and summary, and
/// after that how it's doing, with Check now.
struct EmailImportSheet: View {
    /// The presenting screen's sky, so the sheet reads as part of it.
    var sky = Sky(date: .now)
    @Environment(EmailImport.self) private var emailImport
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let summary = emailImport.summary {
                        EmailSummaryView(summary: summary)
                    } else if emailImport.isScanning, let progress = emailImport.progress {
                        progressView(progress)
                    } else if emailImport.isConnected {
                        status
                    } else {
                        connect
                    }
                }
                .foregroundStyle(Theme.ink)
                .padding()
            }
            .skyBackground(sky)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        emailImport.summary = nil
                        dismiss()
                    }
                }
            }
            .animation(Theme.motion(reduceMotion), value: emailImport.isConnected)
            .animation(Theme.motion(reduceMotion), value: emailImport.isScanning)
            .animation(Theme.motion(reduceMotion), value: emailImport.summary)
        }
    }

    // MARK: Before connecting

    private var connect: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add flights from your email")
                .font(.bcDisplay)
                .accessibilityAddTraits(.isHeader)
            Text("We add every flight we find in your booking emails, and keep them up to date when the airline emails you a change.")
                .font(.bcBody)
                .foregroundStyle(Theme.secondaryInk)
            VStack(alignment: .leading, spacing: 16) {
                promise("airplane", "Only flight bookings.", "Other email is never opened by BumpCast.")
                promise("hand.tap", "Remove any flight", "we add in one tap. It won't come back.")
                promise(
                    "iphone", "Read on this iPhone.",
                    "Emails are never stored or sent anywhere. Only the flight number and date are used to find the flight.")
                promise("gearshape", "Disconnect any time", "in Settings.")
            }
            .skyCard()
            VStack(spacing: 10) {
                EmailConnectButtons()
                // Outlook isn't set up yet: said once, calmly, under the button.
                if emailImport.providers == [.google] {
                    Text("Gmail for now. Outlook is next.")
                        .font(.bcFootnote)
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func promise(_ symbol: String, _ lead: String, _ rest: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.bcSymbolControl)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text("\(Text(lead).font(.bcSubheadlineStrong)) \(rest)")
                .font(.bcSubheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The first scan

    /// The splash screen's Calm line, drawing itself then breathing, over a plain count and bar.
    private func progressView(_ progress: EmailImport.Progress) -> some View {
        VStack(spacing: 16) {
            ScanningMark()
                .padding(.bottom, 8)
            Text("Looking for your flights")
                .font(.bcDisplay)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 8) {
                Text("Checked \(progress.checked) of \(progress.total) booking emails")
                    .font(.bcHeadline.monospacedDigit())
                ProgressView(value: Double(progress.checked), total: Double(max(progress.total, 1)))
                    .tint(Theme.accent)
                    .frame(maxWidth: 240)
                    .accessibilityHidden(true)
            }
            if progress.added > 0 {
                Text(progress.added == 1 ? "1 flight added so far" : "\(progress.added) flights added so far")
                    .font(.bcSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
            if progress.total > EmailImport.messagesPerScan {
                Text(EmailImportCopy.bigInbox)
                    .font(.bcSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        // Centred in the sheet rather than pinned to the top: the space is the calm.
        .containerRelativeFrame(.vertical, alignment: .center) { height, _ in height * 0.85 }
    }

    // MARK: Connected

    private var status: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Flights from your email").font(.bcDisplay).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                if let email = emailImport.email, !email.isEmpty {
                    Text(email).font(.bcHeadline)
                }
                if emailImport.needsReconnect {
                    Text("Sign in again to keep adding flights.").font(.bcSubheadline).foregroundStyle(Theme.secondaryInk)
                    EmailConnectButtons(again: true)
                } else {
                    Text(EmailImportCopy.ongoing).font(.bcSubheadline).foregroundStyle(Theme.secondaryInk)
                    Button {
                        Task { await emailImport.scan() }
                    } label: {
                        Group {
                            if emailImport.isScanning {
                                ProgressView().tint(Theme.onAccent)
                            } else {
                                Text("Check now").font(.bcHeadline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                    .controlSize(.large)
                    .disabled(emailImport.isScanning)
                    if let text = EmailImportCopy.result(emailImport.lastResult) {
                        Text(text).font(.bcSubheadline).foregroundStyle(Theme.secondaryInk)
                    } else if let checked = emailImport.lastChecked {
                        Text("Last checked \(checked.formatted(.relative(presentation: .named))).")
                            .font(.bcSubheadline).foregroundStyle(Theme.secondaryInk)
                    }
                    if emailImport.backlog > 0 {
                        Text(EmailImportCopy.bigInbox).font(.bcSubheadline).foregroundStyle(Theme.secondaryInk)
                    }
                }
            }
            .skyCard()
            EmailListsSection()
        }
    }
}

/// The first scan's end: what was added, each with Remove, then what needs them.
private struct EmailSummaryView: View {
    let summary: EmailImport.Summary
    @Environment(EmailImport.self) private var emailImport
    @Environment(FlightStore.self) private var store

    var body: some View {
        let added = summary.added.compactMap(store.flight)
        VStack(alignment: .leading, spacing: 20) {
            Text(title(added.count)).font(.bcDisplay).accessibilityAddTraits(.isHeader)
            if added.isEmpty {
                Text(EmailImportCopy.ongoing).font(.bcBody).foregroundStyle(Theme.secondaryInk)
            } else {
                VStack(spacing: 0) {
                    ForEach(added) { flight in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(flight.titleText).font(.bcHeadline)
                                Text(flight.departureText).font(.bcMeta).foregroundStyle(Theme.secondaryInk)
                            }
                            Spacer(minLength: 8)
                            // Teal, never red: removing is calm, and it won't come back.
                            Button("Remove") { Task { await emailImport.remove(flight) } }
                                .font(.bcSubheadlineStrong)
                                .foregroundStyle(Theme.accent)
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 10)
                        if flight.id != added.last?.id { Divider() }
                    }
                }
                .skyCard(padding: 14)
                Text("Removed flights won't be added again.").font(.bcFootnote).foregroundStyle(Theme.secondaryInk)
            }
            EmailListsSection()
            if emailImport.backlog > 0 {
                Text(EmailImportCopy.bigInbox).font(.bcSubheadline).foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    private func title(_ count: Int) -> String {
        switch count {
        case 0: "No upcoming flights yet"
        case 1: "We added 1 flight"
        default: "We added \(count) flights"
        }
    }
}

/// Needs you, then Ready to add, each with its one header.
private struct EmailListsSection: View {
    @Environment(EmailImport.self) private var emailImport

    var body: some View {
        if !emailImport.needsYou.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Needs you").eyebrow().foregroundStyle(Theme.secondaryInk).accessibilityAddTraits(.isHeader)
                NeedsYouList().skyCard(padding: 14)
            }
        }
        if !emailImport.readyToAdd.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ready to add").eyebrow().foregroundStyle(Theme.secondaryInk).accessibilityAddTraits(.isHeader)
                ReadyToAddList().skyCard(padding: 14)
            }
        }
    }
}

/// Connect Gmail (and Outlook, only once it's set up), or sign in again.
struct EmailConnectButtons: View {
    var again = false
    @Environment(EmailImport.self) private var emailImport

    var body: some View {
        @Bindable var emailImport = emailImport
        VStack(spacing: 12) {
            // Signing in again: only the account that was connected.
            let shown = again ? emailImport.providers.filter { $0 == emailImport.provider } : emailImport.providers
            ForEach(shown, id: \.self) { provider in
                Button {
                    Paywalls.shared.unlock(.emailImportLocked) { Task { await emailImport.connect(provider) } }
                } label: {
                    Group {
                        if emailImport.isConnecting {
                            ProgressView().tint(Theme.onAccent)
                        } else {
                            Text(again ? "Sign in to \(provider.name) again" : "Connect \(provider.name)").font(.bcHeadline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
                .controlSize(.large)
                .disabled(emailImport.isConnecting)
            }
        }
        .alert("That didn't go through", isPresented: $emailImport.connectFailed) {
            Button("OK") {}
        } message: {
            Text("Check your connection and try again.")
        }
    }
}

/// Bookings that couldn't be added by themselves: what each is, why, and Add it › with the number
/// and day filled in.
struct NeedsYouList: View {
    @Environment(EmailImport.self) private var emailImport
    @Environment(Paywalls.self) private var paywalls
    @Environment(Router.self) private var router
    @State private var adding: EmailImport.NeedsYouItem?

    var body: some View {
        let items = emailImport.needsYou
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.bcHeadline).foregroundStyle(Theme.ink)
                    Text(item.reason.text).font(.bcFootnote).foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Add it ›") { add(item) }
                        .font(.bcSubheadlineStrong)
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.borderless)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .contextMenu {
                    Button("Not my flight", systemImage: "hand.raised") { emailImport.discard(item) }
                }
                if item.id != items.last?.id { Divider() }
            }
        }
        .adaptiveSheet(item: $adding, onDismiss: { router.finishAdding() }) { item in
            AddFlightView(prefill: item)
        }
    }

    /// The same free-limit check as the + button.
    private func add(_ item: EmailImport.NeedsYouItem) {
        if paywalls.canAddFlight {
            adding = item
        } else {
            paywalls.unlock(.flightLimitReached) { adding = item }
        }
    }
}

/// Flights found past the free limit: one tap adds each, through the paywall. The header is the
/// container's, so it's never shown twice.
struct ReadyToAddList: View {
    @Environment(EmailImport.self) private var emailImport
    @Environment(Paywalls.self) private var paywalls

    var body: some View {
        let ready = emailImport.readyToAdd
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ready) { item in
                let flight = item.flight
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flight.titleText).font(.bcHeadline).foregroundStyle(Theme.ink)
                        Text(flight.departureText).font(.bcMeta).foregroundStyle(Theme.secondaryInk)
                    }
                    Spacer(minLength: 8)
                    Button("Add") { add(item) }
                        .font(.bcSubheadlineStrong)
                        .buttonStyle(.bordered).tint(Theme.accent)
                }
                .padding(.vertical, 10)
                .contextMenu {
                    Button("Not my flight", systemImage: "hand.raised") { emailImport.discard(item) }
                }
                if item.id != ready.last?.id { Divider() }
            }
        }
    }

    private func add(_ item: EmailImport.ReadyFlight) {
        if paywalls.canAddFlight {
            Task { await emailImport.add(item) }
        } else {
            paywalls.unlock(.flightLimitReached) { Task { await emailImport.add(item) } }
        }
    }
}

/// From the Flights list's "Ready to add" row.
struct ReadyToAddSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EmailListPage(kind: .ready)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

/// Needs you or Ready to add as its own page (Settings, the Flights list).
struct EmailListPage: View {
    enum Kind { case ready, needsYou }
    let kind: Kind

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    kind == .ready
                        ? "You're using your \(Paywalls.freeUpcomingFlights) free upcoming flights. Pro adds as many as you like."
                        : "We found these bookings but couldn't tell which flight is yours."
                )
                .font(.bcSubheadline)
                .foregroundStyle(Theme.secondaryInk)
                Group {
                    if kind == .ready { ReadyToAddList() } else { NeedsYouList() }
                }
                .skyCard(padding: 14)
            }
            .padding()
        }
        .skyBackground(Sky(date: .now))
        .navigationTitle(kind == .ready ? "Ready to add" : "Needs you")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings → Email: the account, when it last looked, what's waiting, Check now, Disconnect.
struct EmailSettingsSection: View {
    @Environment(EmailImport.self) private var emailImport
    @State private var connecting = false
    @State private var confirmingDisconnect = false

    var body: some View {
        if !EmailImport.isReady {
            // Until Google verifies the Gmail scope: say it's coming, and offer nothing to tap.
            Section {
                LabeledContent("Add flights from your email", value: "Coming soon")
            } header: {
                Text("Email").eyebrow()
            } footer: {
                Text("Adds your booked flights and keeps them up to date from airline emails.")
            }
        } else if emailImport.isConnected || !emailImport.providers.isEmpty {
            // Hidden until a provider is set up (and while none is connected).
            Section {
                if emailImport.isConnected {
                    if let email = emailImport.email, !email.isEmpty {
                        LabeledContent("Account", value: email)
                    }
                    if emailImport.needsReconnect {
                        Button("Sign in again to keep adding flights") { connecting = true }
                    }
                    if !Paywalls.shared.hasEmailImport {
                        // Pro ended: nothing is checked until it's back.
                        Button("Keep adding flights with BumpCast Pro") {
                            Paywalls.shared.unlock(.emailImportLocked) { Task { await emailImport.scan() } }
                        }
                    }
                    LabeledContent(
                        "Last checked",
                        value: emailImport.lastChecked?.formatted(.relative(presentation: .named)) ?? "Not yet")
                    if !emailImport.readyToAdd.isEmpty {
                        NavigationLink("\(emailImport.readyToAdd.count) ready to add") { EmailListPage(kind: .ready) }
                    }
                    if !emailImport.needsYou.isEmpty {
                        NavigationLink("\(emailImport.needsYou.count) needs you") { EmailListPage(kind: .needsYou) }
                    }
                    Button {
                        Task { await emailImport.scan() }
                    } label: {
                        HStack {
                            Text("Check now")
                            if emailImport.isScanning {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(emailImport.isScanning || emailImport.needsReconnect || !Paywalls.shared.hasEmailImport)
                    // Accent, not red: nothing in Settings uses red (DESIGN_SPEC).
                    Button("Disconnect") { confirmingDisconnect = true }
                } else {
                    ForEach(emailImport.providers, id: \.self) { provider in
                        Button("Connect \(provider.name)") {
                            Paywalls.shared.unlock(.emailImportLocked) { connecting = true }
                        }
                    }
                }
            } header: {
                Text("Email").eyebrow()
            } footer: {
                Text("Adds your booked flights and keeps them up to date from airline emails.")
            }
            .adaptiveSheet(isPresented: $connecting) { EmailImportSheet() }
            .confirmationDialog(
                "Stop adding flights from your email?", isPresented: $confirmingDisconnect, titleVisibility: .visible
            ) {
                Button("Disconnect") { Task { await emailImport.disconnect() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Flights already added stay. You can connect again any time.")
            }
        }
    }
}

/// On the flight screen for a day after email changed it: "Updated from your email" with what it
/// is now and what it was, and Undo.
struct EmailFlightNotes: View, DuoPlaced {
    var duoRole: DuoRole { .leading }
    let flight: Flight
    /// The flight is gone: the screen closes.
    let removed: () -> Void
    @Environment(EmailImport.self) private var emailImport

    var body: some View {
        if let change = emailImport.recentChange(flight.id) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Updated from your email").eyebrow().foregroundStyle(Theme.secondaryInk)
                Text("Now: \(Self.line(number: flight.flightNumber, flight.departureAt, flight))").font(.bcHeadline)
                Text("Was: \(Text(Self.line(number: change.was.flightNumber, change.was.departureAt, flight)).strikethrough())")
                    .font(.bcSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                Button("Undo") { Task { await emailImport.undoChange(flight.id) } }
                    .font(.bcSubheadlineStrong)
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .skyCard(cornerRadius: 16, padding: 12)
        }
    }

    /// "B6 1023 · 9:05 AM" at the departure airport, with the day when it isn't the flight's.
    private static func line(number: String?, _ departure: Date, _ flight: Flight) -> String {
        let tz = flight.originTimeZone
        let otherDay = departure.localDay(in: tz) != flight.departureAt.localDay(in: tz)
        let time = departure.localTime(in: tz, withDay: otherDay)
        return number.map { "\($0) · \(time)" } ?? time
    }
}

enum EmailImportCopy {
    static let ongoing = "We check when you open BumpCast, and now and then in the background."
    static let bigInbox =
        "Big inboxes take a few visits. We'll keep going next time you open BumpCast, and you can close this now."

    static func result(_ result: EmailImport.ScanResult?) -> String? {
        switch result {
        case nil: nil
        case .found(let added, let ready, let needsYou):
            [
                added > 0 ? (added == 1 ? "Added 1 flight." : "Added \(added) flights.") : nil,
                ready > 0 ? (ready == 1 ? "1 flight is ready to add." : "\(ready) flights are ready to add.") : nil,
                needsYou > 0 ? (needsYou == 1 ? "1 booking needs you." : "\(needsYou) bookings need you.") : nil,
            ].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "Your flights are up to date."
        case .nothingNew: "No new flights right now."
        case .offline: "You're offline. We'll look again when you're connected."
        case .unavailable: "We couldn't look just now. We'll try again soon."
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The launch screen's Calm line icon while the first scan runs: the line draws and the sun rises,
/// then it breathes slowly until the scan is done. Reduce Motion shows it still.
private struct ScanningMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var drawn = false
    @State private var breathing = false

    var body: some View {
        CalmLineIcon(palette: colorScheme == .dark ? .dark : .light, lineProgress: drawn ? 1 : 0, sunRise: drawn ? 1 : 0)
            .frame(width: 112, height: 112)
            .clipShape(.rect(cornerRadius: 26, style: .continuous))
            .scaleEffect(breathing ? 1.03 : 1)
            .onAppear {
                if reduceMotion {
                    drawn = true
                    return
                }
                withAnimation(.smooth(duration: 1.6)) { drawn = true }
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true).delay(1.6)) {
                    breathing = true
                }
            }
    }
}
