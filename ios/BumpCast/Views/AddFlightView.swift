import SwiftUI

/// Add a flight in three short steps (Route, When, Check), or edit one starting on Check.
/// DESIGN_SPEC §3 item 8. States are never red: problems use the moderate orange plus words.
struct AddFlightView: View {
    var flight: Flight?

    enum Step: Int, CaseIterable { case route, when, check }

    @Environment(FlightStore.self) private var store
    @Environment(PushNotifications.self) private var push
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Step = .route
    @State private var origin: Airport?
    @State private var destination: Airport?
    @State private var departure = AddFlightView.defaultDeparture
    @State private var notify = true
    @State private var allowOutsideCoverage = false
    @State private var isSaving = false
    @State private var loaded = false

    private var isEditing: Bool { flight != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                switch step {
                case .route:
                    RouteStep(
                        origin: $origin, destination: $destination,
                        allowOutsideCoverage: $allowOutsideCoverage, recent: recentAirports)
                    .transition(stepTransition)
                case .when:
                    WhenStep(origin: origin, destination: destination, departure: $departure)
                        .transition(stepTransition)
                case .check:
                    CheckStep(
                        origin: origin, destination: destination, departure: departure, notify: $notify,
                        isEditing: isEditing
                    ) { step = .route }
                    .transition(stepTransition)
                }
            }
            .animation(Theme.motion(reduceMotion), value: step)
            .background { SkyBackground(sky: Sky(date: departure, timeZone: origin?.timeZone ?? .current)) }
            .safeAreaInset(edge: .bottom) { primaryButton }
            .navigationTitle(isEditing ? "Edit flight" : "\(step.rawValue + 1) of 3")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .route || (isEditing && step == .check) {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .route }
                    }
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity.combined(with: .offset(x: -24)))
    }

    // MARK: Primary button

    private var primaryButton: some View {
        Button(action: advance) {
            Text(buttonTitle).font(.bcHeadline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .controlSize(.large)
        .disabled(!canAdvance || isSaving)
        .padding()
    }

    private var buttonTitle: String {
        switch step {
        case .route, .when: "Next"
        case .check: isEditing ? "Save changes" : "Add flight"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .route: RouteStep.isValid(origin, destination, allowOutsideCoverage: allowOutsideCoverage)
        case .when: WhenStep.isValid(departure)
        case .check:
            RouteStep.isValid(origin, destination, allowOutsideCoverage: true) && WhenStep.isValid(departure)
        }
    }

    private func advance() {
        switch step {
        case .route: step = .when
        case .when: step = .check
        case .check: Task { await save() }
        }
    }

    // MARK: Saving

    private func save() async {
        guard let origin, let destination else { return }
        isSaving = true
        defer { isSaving = false }
        let draft = FlightDraft(origin: origin.icao, destination: destination.icao, departureAt: departure, notify: notify)
        guard let saved = await store.save(draft, editing: flight?.id) else { return }
        dismiss()
        // The toggle asks for permission at the moment it's useful.
        if notify, push.status == .notDetermined {
            await push.requestPermission()
        }
        router.showToast(toastText(for: saved))
        // Leaving soon: go straight to the forecast.
        if !isEditing, saved.departureAt.timeIntervalSinceNow < 18 * 3600 {
            router.openFlight(saved.id)
        }
    }

    private func toastText(for saved: Flight) -> String {
        if store.isPending(saved.id) {
            return "\(saved.routeText) saved on your phone. We'll sync it when you're back online."
        }
        if isEditing { return "Changes saved." }
        let unlock = saved.forecastUnlocksAt
        if unlock <= .now { return "\(saved.routeText) added. Your forecast will be ready in a few minutes." }
        return "\(saved.routeText) added. First forecast \(unlock.approximateDayAndTime())."
    }

    // MARK: Setup

    private static var defaultDeparture: Date {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        guard let flight else { return }
        origin = flight.originAirport
        destination = flight.destinationAirport
        departure = flight.departureAt
        notify = flight.notify
        allowOutsideCoverage = true
        step = .check
    }

    /// Airports from saved flights, most recent first.
    private var recentAirports: [Airport] {
        var seen = Set<String>()
        return store.flights.reversed()
            .flatMap { [$0.originAirport, $0.destinationAirport] }
            .compactMap { $0 }
            .filter { seen.insert($0.icao).inserted }
            .prefix(6)
            .map { $0 }
    }
}

// MARK: - Step 1: Route

private struct RouteStep: View {
    @Binding var origin: Airport?
    @Binding var destination: Airport?
    @Binding var allowOutsideCoverage: Bool
    let recent: [Airport]

    static func isValid(_ origin: Airport?, _ destination: Airport?, allowOutsideCoverage: Bool) -> Bool {
        guard let origin, let destination, origin != destination else { return false }
        return allowOutsideCoverage || Coverage.covers(from: origin, to: destination)
    }

    private var sameAirport: Bool { origin != nil && origin == destination }
    private var outsideCoverage: Bool {
        guard let origin, let destination, origin != destination else { return false }
        return !Coverage.covers(from: origin, to: destination)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Where are you flying?").font(.bcDisplay)
                VStack(spacing: 0) {
                    AirportField(title: "From", airport: $origin, highlight: false)
                    HStack {
                        DottedRouteLine().frame(width: 24, height: 28)
                        Spacer()
                        Button {
                            swap(&origin, &destination)
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.bcHeadline)
                                .padding(10)
                                .background(.regularMaterial, in: .circle)
                        }
                        .accessibilityLabel("Swap airports")
                        .disabled(origin == nil && destination == nil)
                    }
                    .padding(.horizontal, 14)
                    AirportField(title: "To", airport: $destination, highlight: sameAirport)
                }
                if sameAirport {
                    Text("That's where you're leaving from. Pick where you're flying to.")
                        .font(.bcSubheadline)
                        .foregroundStyle(Theme.color(.moderate))
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent").eyebrow().foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(recent.filter { $0 != origin && $0 != destination }) { airport in
                                    Button {
                                        if origin == nil { origin = airport } else { destination = airport }
                                    } label: {
                                        Text("\(Text(airport.iata).font(.bcMeta)) \(airport.city)")
                                            .font(.bcSubheadline)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(Theme.accent)
                                }
                            }
                        }
                    }
                }
                if outsideCoverage && !allowOutsideCoverage {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("This route is outside our coverage for now", systemImage: "globe")
                            .font(.bcCardTitle)
                        Text("You can still save it. We'll show it as not covered and let you know when we cover it.")
                            .font(.bcSubheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Save anyway") { allowOutsideCoverage = true }
                                .buttonStyle(.borderedProminent).tint(Theme.accent)
                            Button("Change route") { destination = nil }
                                .buttonStyle(.bordered).tint(Theme.accent)
                        }
                        .font(.bcSubheadlineStrong)
                    }
                    .skyCard()
                }
                Label("We have the strongest coverage in the US, and we're expanding rapidly.", systemImage: "info.circle")
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .onChange(of: destination) { allowOutsideCoverage = false }
        .onChange(of: origin) { allowOutsideCoverage = false }
    }
}

/// A From/To field that pushes the airport search.
private struct AirportField: View {
    let title: String
    @Binding var airport: Airport?
    let highlight: Bool

    var body: some View {
        NavigationLink {
            AirportSearchView(title: title, selection: $airport)
        } label: {
            HStack(spacing: 12) {
                Text(title).eyebrow().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                if let airport {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(airport.iata).font(.bcTitle2)
                        Text(airport.city).font(.bcSubheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Choose airport").font(.bcBody).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .skyCard(cornerRadius: 18, padding: 14)
            .overlay {
                if highlight {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.color(.moderate), lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DottedRouteLine: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 12, y: 0))
            path.addLine(to: CGPoint(x: 12, y: 28))
        }
        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 6]))
        .accessibilityHidden(true)
    }
}

/// Searchable airports: IATA in Plex Mono, city, then name, with the match in bold.
private struct AirportSearchView: View {
    let title: String
    @Binding var selection: Airport?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List(AirportStore.shared.search(query)) { airport in
            Button {
                selection = airport
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Text(highlighted(airport.iata)).font(.bcMeta).frame(width: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(highlighted(airport.city)).font(.bcBody)
                        Text(highlighted(airport.name)).font(.bcFootnote).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.primary)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "City, airport or code")
        .navigationTitle(title)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let range = result.range(of: q, options: .caseInsensitive) else { return result }
        result[range].inlinePresentationIntent = .stronglyEmphasized
        return result
    }
}

// MARK: - Step 2: When

private struct WhenStep: View {
    let origin: Airport?
    let destination: Airport?
    @Binding var departure: Date
    @State private var isPickingDate = false

    /// Up to an hour late is allowed, for delays.
    static func isValid(_ departure: Date) -> Bool { departure > .now.addingTimeInterval(-3600) }

    private var timeZone: TimeZone { origin?.timeZone ?? .current }
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let origin, let destination {
                    Text("\(origin.iata) → \(destination.iata)").eyebrow().foregroundStyle(.secondary)
                }
                Text("When do you leave?").font(.bcDisplay)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(0..<6, id: \.self) { offset in
                            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))!
                            let selected = calendar.isDate(day, inSameDayAs: departure)
                            Button {
                                setDay(day)
                            } label: {
                                Text(label(for: day, offset: offset)).font(.bcSubheadlineStrong)
                            }
                            .buttonStyle(.bordered)
                            .tint(selected ? Theme.accent : Theme.secondaryInk)
                        }
                        Button {
                            isPickingDate = true
                        } label: {
                            Image(systemName: "calendar").font(.bcSubheadlineStrong)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.secondaryInk)
                        .accessibilityLabel("Pick another date")
                    }
                }
                // The time wheel is the system DatePicker (it stays SF Pro).
                DatePicker("Departure time", selection: $departure, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .environment(\.timeZone, timeZone)
                    .skyCard()
                Text("Local time in \(origin?.city ?? "your departure city"), from your booking.")
                    .font(.bcFootnote)
                    .foregroundStyle(.secondary)
                if !Self.isValid(departure) {
                    Text("Check the date, or pick a later time.")
                        .font(.bcSubheadline)
                        .foregroundStyle(Theme.color(.moderate))
                } else {
                    Label(previewText, systemImage: "clock")
                        .font(.bcSubheadline)
                        .skyCard(cornerRadius: 16, padding: 12)
                }
            }
            .padding()
        }
        .sheet(isPresented: $isPickingDate) {
            NavigationStack {
                DatePicker("Departure date", selection: $departure, in: Date.now..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.timeZone, timeZone)
                    .padding()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { isPickingDate = false } }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var previewText: String {
        let unlock = departure.addingTimeInterval(-Flight.forecastWindow)
        if unlock <= .now { return "Your forecast will be ready a few minutes after you add the flight." }
        return "Your first forecast arrives \(unlock.approximateDayAndTime())."
    }

    private func label(for day: Date, offset: Int) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            var style = Date.FormatStyle().weekday(.abbreviated).day()
            style.timeZone = timeZone
            return day.formatted(style)
        }
    }

    /// Keeps the chosen time, moves it to `day` (in the departure airport's time zone).
    private func setDay(_ day: Date) {
        let time = calendar.dateComponents([.hour, .minute], from: departure)
        departure = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }
}

// MARK: - Step 3: Check

private struct CheckStep: View {
    let origin: Airport?
    let destination: Airport?
    let departure: Date
    @Binding var notify: Bool
    let isEditing: Bool
    let change: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Check your flight").font(.bcDisplay)
                if let origin, let destination {
                    routeCard(origin, destination)
                }
                if departure.timeIntervalSinceNow > 18 * 3600 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("What happens next").font(.bcSection)
                        ForEach(timeline, id: \.title) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Circle()
                                    .fill(item.isNow ? Theme.accent : Theme.secondaryInk.opacity(0.4))
                                    .frame(width: 10, height: 10)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.when).eyebrow().foregroundStyle(.secondary)
                                    Text(item.title).font(.bcHeadline)
                                    Text(item.detail).font(.bcSubheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .skyCard()
                }
                Toggle(isOn: $notify) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tell me when it's ready or changes").font(.bcHeadline)
                        // Backed by worker quiet hours (22:00–07:00 local; early flights still get updates).
                        Text("Only for changes you'd notice. Quiet overnight unless you fly early.")
                            .font(.bcFootnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Theme.accent)
                .skyCard()
            }
            .padding()
        }
    }

    private func routeCard(_ origin: Airport, _ destination: Airport) -> some View {
        let flight = Flight(id: UUID(), origin: origin.icao, destination: destination.icao, departureAt: departure)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(flight.routeText).font(.bcTitle2)
                Spacer()
                Button("Change", action: change).font(.bcSubheadlineStrong).tint(Theme.accent)
            }
            Text("\(origin.city) to \(destination.city)").font(.bcSubheadline)
            Text(flight.departureText).font(.bcMeta).foregroundStyle(.secondary)
            Text("About \(Int(flight.estimatedAirMinutes).durationText) in the air").font(.bcFootnote).foregroundStyle(.secondary)
        }
        .skyCard()
    }

    private struct Item {
        let when: String
        let title: String
        let detail: String
        var isNow = false
    }

    private var timeline: [Item] {
        let advance = departure.addingTimeInterval(-Flight.forecastWindow)
        let confirmed = departure.addingTimeInterval(-Forecast.noaaHorizon + Forecast.noaaPublishLag)
        var items = [
            Item(
                when: "Now", title: isEditing ? "Saved" : "Saved",
                detail: advance > .now ? "Too early to tell yet." : "Your forecast will be ready in a few minutes.",
                isNow: true)
        ]
        if advance > .now {
            items.append(Item(when: advance.approximateDayAndTime(), title: "Advance forecast", detail: "An early look. It can still change."))
        }
        items.append(Item(when: confirmed.approximateDayAndTime(), title: "Confirmed forecast", detail: "Updated every hour until you fly."))
        items.append(Item(when: "You fly", title: "Ready for the flight", detail: "Saved on your phone for the flight, even offline."))
        return items
    }
}
