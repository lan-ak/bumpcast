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
    private var sky: Sky { Sky(date: departure, timeZone: origin?.timeZone ?? .current) }

    var body: some View {
        NavigationStack {
            ZStack {
                switch step {
                case .route:
                    RouteStep(
                        origin: $origin, destination: $destination,
                        allowOutsideCoverage: $allowOutsideCoverage, recent: recentAirports, sky: sky)
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
            .background { SkyBackground(sky: sky) }
            .onSky(sky)
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
        .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
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
    let sky: Sky

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
                    AirportField(title: "From", airport: $origin, highlight: false, sky: sky)
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
                    AirportField(title: "To", airport: $destination, highlight: sameAirport, sky: sky)
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
                                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent).tint(Theme.accent)
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
    let sky: Sky

    var body: some View {
        NavigationLink {
            AirportSearchView(title: title, selection: $airport, sky: sky)
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

/// Searchable airports on the same sky as the flow: a brand search field, then one card of
/// rows (IATA in Plex Mono, city, then airport name, with the matched text in bold).
private struct AirportSearchView: View {
    let title: String
    @Binding var selection: Airport?
    let sky: Sky
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [Airport] { AirportStore.shared.search(query) }
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).eyebrow().foregroundStyle(.secondary)
                Text(title == "From" ? "Where are you leaving from?" : "Where are you flying to?")
                    .font(.bcDisplay)
                    .accessibilityAddTraits(.isHeader)
                searchField
                if results.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No airports match \u{201C}\(trimmed)\u{201D}").font(.bcCardTitle)
                        Text("Try the city, the airport name or its three-letter code.")
                            .font(.bcSubheadline)
                            .foregroundStyle(.secondary)
                    }
                    .skyCard()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(trimmed.isEmpty ? "Popular airports" : "Airports").eyebrow().foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, airport in
                                if index > 0 { Divider().padding(.leading, 70) }
                                row(airport)
                            }
                        }
                        .skyCard(padding: 0)
                    }
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background { SkyBackground(sky: sky) }
        .onSky(sky)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("City, airport or code", text: $query)
                .font(.bcBody)
                .focused($focused)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { if let first = results.first, !trimmed.isEmpty { pick(first) } }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .skyCard(cornerRadius: 16, padding: 14)
    }

    private func row(_ airport: Airport) -> some View {
        Button {
            pick(airport)
        } label: {
            HStack(spacing: 14) {
                Text(highlighted(airport.iata))
                    .font(.bcMeta)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 32)
                    .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(highlighted(airport.city)).font(.bcBody)
                    Text(highlighted(airport.name)).font(.bcFootnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if airport == selection {
                    Image(systemName: "checkmark").font(.bcHeadline).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(airport == selection ? .isSelected : [])
    }

    private func pick(_ airport: Airport) {
        selection = airport
        dismiss()
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard !trimmed.isEmpty, let range = result.range(of: trimmed, options: .caseInsensitive) else { return result }
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

    /// Days shown as tiles; later dates come from the calendar tile.
    private static let tileDays = 6

    private var timeZone: TimeZone { origin?.timeZone ?? .current }
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = .current
        c.timeZone = timeZone
        return c
    }

    private var isLaterDate: Bool {
        let today = calendar.startOfDay(for: .now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: departure)).day ?? 0
        return days >= Self.tileDays || days < 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let origin, let destination {
                    Text("\(origin.iata) → \(destination.iata)").eyebrow().foregroundStyle(.secondary)
                }
                Text("When do you leave?").font(.bcDisplay)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(0..<Self.tileDays, id: \.self) { offset in
                            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))!
                            DayTile(
                                top: offset == 0 ? "Today" : weekday(day),
                                bottom: Text(dayNumber(day)),
                                selected: calendar.isDate(day, inSameDayAs: departure)
                            ) { setDay(day) }
                            .accessibilityLabel(offset == 0 ? "Today" : day.formatted(accessibleDay))
                        }
                        DayTile(
                            top: isLaterDate ? month(departure) : "More",
                            bottom: isLaterDate ? Text(dayNumber(departure)) : Text(Image(systemName: "calendar")),
                            selected: isLaterDate
                        ) { isPickingDate = true }
                        .accessibilityLabel(isLaterDate ? departure.formatted(accessibleDay) : "Pick another date")
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
                TimeWheel(date: $departure, calendar: calendar)
                    .skyCard(padding: 8)
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
                VStack(alignment: .leading, spacing: 18) {
                    Text("Pick a date").font(.bcTitle)
                    MonthCalendar(selection: departure, calendar: calendar) { day in
                        setDay(day)
                        isPickingDate = false
                    }
                    .skyCard()
                    Spacer(minLength: 0)
                }
                .padding()
                .background { SkyBackground(sky: Sky(date: departure, timeZone: timeZone)) }
                .onSky(Sky(date: departure, timeZone: timeZone))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { isPickingDate = false } }
                }
            }
            .presentationDetents([.fraction(0.72), .large])
        }
    }

    private var previewText: String {
        let unlock = departure.addingTimeInterval(-Flight.forecastWindow)
        if unlock <= .now { return "Your forecast will be ready a few minutes after you add the flight." }
        return "Your first forecast arrives \(unlock.approximateDayAndTime())."
    }

    private var accessibleDay: Date.FormatStyle {
        var style = Date.FormatStyle().weekday(.wide).month(.wide).day()
        style.timeZone = timeZone
        return style
    }

    private func weekday(_ day: Date) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated)
        style.timeZone = timeZone
        return day.formatted(style)
    }

    private func month(_ day: Date) -> String {
        var style = Date.FormatStyle().month(.abbreviated)
        style.timeZone = timeZone
        return day.formatted(style)
    }

    private func dayNumber(_ day: Date) -> String { "\(calendar.component(.day, from: day))" }

    /// Keeps the chosen time, moves it to `day` (in the departure airport's time zone).
    private func setDay(_ day: Date) {
        let time = calendar.dateComponents([.hour, .minute], from: departure)
        departure = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }
}

/// A day tile: weekday eyebrow over the date in Familjen. Selected tiles fill with accent teal.
private struct DayTile: View {
    let top: String
    let bottom: Text
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: action) {
            VStack(spacing: 4) {
                Text(top).eyebrow()
                bottom.font(.bcTitle2)
            }
            .frame(width: 50, height: 66)
            .foregroundStyle(selected ? Theme.onAccent : Color.primary)
            .background {
                if selected {
                    shape.fill(Theme.accent)
                } else {
                    shape.fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.6))
                        .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.7), lineWidth: 0.5))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The departure time as brand wheels (hour, minute, and AM/PM where the locale uses it),
/// in the departure airport's time zone. Replaces the SF Pro system wheel.
private struct TimeWheel: View {
    @Binding var date: Date
    let calendar: Calendar

    private static let uses12Hour: Bool =
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")

    private var hour24: Int { calendar.component(.hour, from: date) }
    private var minute: Int { calendar.component(.minute, from: date) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent.opacity(0.12))
                .frame(height: WheelColumn.rowHeight)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                if Self.uses12Hour {
                    WheelColumn(values: Array(1...12), selection: hour12Binding, label: { "\($0)" }, name: "Hour")
                } else {
                    WheelColumn(values: Array(0...23), selection: hour24Binding, label: { String(format: "%02d", $0) }, name: "Hour")
                }
                Text(":").font(.bcTitle).accessibilityHidden(true)
                WheelColumn(values: Array(0...59), selection: minuteBinding, label: { String(format: "%02d", $0) }, name: "Minute")
                if Self.uses12Hour {
                    WheelColumn(
                        values: [0, 1], selection: pmBinding,
                        label: { $0 == 0 ? calendar.amSymbol : calendar.pmSymbol }, name: "AM or PM")
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func set(hour: Int, minute: Int) {
        date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    private var hour24Binding: Binding<Int> {
        Binding { hour24 } set: { set(hour: $0, minute: minute) }
    }

    private var hour12Binding: Binding<Int> {
        Binding { hour24 % 12 == 0 ? 12 : hour24 % 12 } set: { set(hour: ($0 % 12) + (hour24 >= 12 ? 12 : 0), minute: minute) }
    }

    private var pmBinding: Binding<Int> {
        Binding { hour24 >= 12 ? 1 : 0 } set: { set(hour: hour24 % 12 + ($0 == 1 ? 12 : 0), minute: minute) }
    }

    private var minuteBinding: Binding<Int> {
        Binding { minute } set: { set(hour: hour24, minute: $0) }
    }
}

/// One snapping wheel column in Familjen Grotesk. VoiceOver adjusts it with swipe up/down.
private struct WheelColumn: View {
    static let rowHeight: CGFloat = 44
    let values: [Int]
    @Binding var selection: Int
    let label: (Int) -> String
    let name: String
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    @State private var scrolled: Int?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(values, id: \.self) { value in
                    Text(label(value))
                        .font(.bcTitle)
                        .monospacedDigit()
                        .foregroundStyle(value == (scrolled ?? selection) ? Color.primary : Color.secondary.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.rowHeight)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(.smooth) { scrolled = value } }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.vertical, Self.rowHeight * 2, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrolled, anchor: .center)
        .frame(height: Self.rowHeight * 5)
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.3),
            .init(color: .black, location: 0.7), .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
        .sensoryFeedback(.selection, trigger: scrolled) { _, _ in hapticsEnabled }
        .onAppear { scrolled = selection }
        .onChange(of: scrolled) { if let scrolled, scrolled != selection { selection = scrolled } }
        .onChange(of: selection) { if scrolled != selection { scrolled = selection } }
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue(label(selection))
        .accessibilityAdjustableAction { direction in
            guard let index = values.firstIndex(of: selection) else { return }
            switch direction {
            case .increment: if index + 1 < values.count { selection = values[index + 1] }
            case .decrement: if index > 0 { selection = values[index - 1] }
            @unknown default: break
            }
        }
    }
}

/// A month grid in brand type, for dates beyond the day tiles. Past days are disabled.
private struct MonthCalendar: View {
    let selection: Date
    let calendar: Calendar
    let pick: (Date) -> Void
    @State private var month: Date

    /// How far ahead flights can be added.
    private static let monthsAhead = 11

    init(selection: Date, calendar: Calendar, pick: @escaping (Date) -> Void) {
        self.selection = selection
        self.calendar = calendar
        self.pick = pick
        let base = max(selection, .now)
        _month = State(initialValue: calendar.dateInterval(of: .month, for: base)?.start ?? base)
    }

    private var firstMonth: Date { calendar.dateInterval(of: .month, for: .now)?.start ?? .now }
    private var lastMonth: Date { calendar.date(byAdding: .month, value: Self.monthsAhead, to: firstMonth)! }
    private var today: Date { calendar.startOfDay(for: .now) }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Leading blanks, then each day of the month.
    private var cells: [Date?] {
        let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead)
            + (0..<days).map { calendar.date(byAdding: .day, value: $0, to: month) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(monthTitle).font(.bcTitle2)
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.left").font(.bcHeadline).padding(10) }
                    .disabled(month <= firstMonth)
                    .accessibilityLabel("Previous month")
                Button { step(1) } label: { Image(systemName: "chevron.right").font(.bcHeadline).padding(10) }
                    .disabled(month >= lastMonth)
                    .accessibilityLabel("Next month")
            }
            .tint(Theme.accent)
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).eyebrow().foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { dayButton(day) } else { Color.clear.frame(height: 40) }
                }
            }
        }
    }

    private func dayButton(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let past = day < today
        return Button { pick(day) } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(selected || isToday ? .bcHeadline : .bcBody)
                .monospacedDigit()
                .foregroundStyle(selected ? Theme.onAccent : isToday ? Theme.accent : Color.primary)
                .frame(width: 40, height: 40)
                .background { if selected { Circle().fill(Theme.accent) } }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(past)
        .opacity(past ? 0.3 : 1)
        .accessibilityLabel(day.formatted(accessibleStyle))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var monthTitle: String {
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = calendar.timeZone
        return month.formatted(style)
    }

    private var accessibleStyle: Date.FormatStyle {
        var style = Date.FormatStyle().weekday(.wide).month(.wide).day()
        style.timeZone = calendar.timeZone
        return style
    }

    private func step(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) {
            withAnimation(.smooth) { month = min(max(next, firstMonth), lastMonth) }
        }
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
