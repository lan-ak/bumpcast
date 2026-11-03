import Accessibility
import Charts
import SwiftUI

struct ForecastView: View {
    let forecast: Forecast
    let flight: Flight
    /// The screen's one clock (a minute tick on the flight's own minutes), shared with the in-flight card.
    var now: Date = .now
    /// The flight screen's entries before the forecast (the route, its notes, the status cards) and
    /// after it (updates, and on the open Duo Coming up and the Learn card): one list with the
    /// forecast's own, shown by `AdaptiveSpread`.
    var before: [AdaptiveItem] = []
    var after: [AdaptiveItem] = []
    /// The phone's space above the forecast's first entry (closer under a diverted flight's note).
    var leadSpacing: CGFloat = 20
    /// A diverted flight's forecast is shown faded.
    var fade: Double = 1

    @Environment(Paywalls.self) private var paywalls
    @Environment(InFlight.self) private var inFlight
    @Environment(FlightStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @Environment(\.debugFullAccess) private var debugFullAccess
    #endif
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    /// Set when this forecast moved from advance to confirmed since the user last saw it.
    @State private var justConfirmed = false
    @State private var rowsVisible = false
    @State private var openWarning: Forecast.Warning?
    @State private var showOutlookSheet = false

    var body: some View {
        let confidence = forecast.confidence(departure: flight.departureAt)
        // The caller's clock ticks every minute, so in the air "Still ahead", the rows and the marker keep up.
        AdaptiveSpread(items: before + items(moment(confidence: confidence, now: now)) + after, spacing: 20)
        .adaptiveSheet(item: $openWarning) { warning in
            Group {
                if warning.isOfficial { WarningSheet(warning: warning) } else { PilotReportNoteSheet(warning: warning) }
            }
            .presentationDetents([.medium, .large])
        }
        .adaptiveSheet(isPresented: $showOutlookSheet) {
            GlobalOutlookSheet(neverConfirmed: usPart == nil).presentationDetents([.medium, .large])
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: justConfirmed) { _, new in new && hapticsEnabled }
        .onAppear {
            paywalls.firstGradeViewed(flight)
            ReviewPrompt.forecastShown(forecast)
            justConfirmed = ConfidenceMemory.didFirmUp(flight: flight.id, now: confidence)
            if justConfirmed { Analytics.log(.forecastConfirmedSeen, ["grade": forecast.grade?.rawValue ?? ""]) }
            rowsVisible = true
        }
    }

    /// On a mixed global outlook route, the part over the US and when it's confirmed.
    private var usPart: Forecast.USPart? {
        guard forecast.isGlobalOutlook, let origin = flight.originAirport, let destination = flight.destinationAirport else { return nil }
        let airMinutes = forecast.durationMin.map(Double.init) ?? flight.estimatedAirMinutes
        return Forecast.usPart(from: origin, to: destination, airMinutes: airMinutes, departure: flight.departureAt)
    }

    /// What the screen shows at this minute, worked out once for either layout.
    private struct Moment {
        let confidence: Forecast.Confidence
        let now: Date
        let fullAccess: Bool
        /// Minutes since takeoff while flying; nil on the ground (and for a cancelled or diverted flight).
        let minute: Int?
        /// Past departure, nothing more is coming hourly, so nothing promises it.
        let underWay: Bool
        let connection: ConnectionNote
        /// The forecast itself was issued after takeoff (and so reached the phone in the air).
        let inAir: Bool
    }

    private func moment(confidence: Forecast.Confidence, now: Date) -> Moment {
        let minute = InFlightMode.minute(flight, forecast: forecast, inFlight: inFlight, now: now)
        var fullAccess = paywalls.hasFullAccess(to: flight)
        #if DEBUG
        fullAccess = fullAccess || debugFullAccess
        #endif
        return Moment(
            confidence: confidence, now: now, fullAccess: fullAccess, minute: minute,
            underWay: minute != nil || now >= flight.expectedDeparture, connection: ConnectionNote(store: store),
            inAir: (forecast.issuedAt ?? .distantPast) > inFlight.effectiveTakeoff(of: flight))
    }

    /// The forecast's entries in the phone's order. Each component says where it goes on a spread.
    private func items(_ m: Moment) -> [AdaptiveItem] {
        var items: [AdaptiveItem] = []
        // An official warning is the first thing on the screen.
        if let warning = forecast.officialWarnings.first {
            items.append(AdaptiveItem(WarningBanner(warning: warning) { openWarning = warning }))
        }
        if let grade = forecast.grade {
            items.append(AdaptiveItem(GradeCard(
                grade: grade, forecast: forecast, confidence: m.confidence,
                departureNote: flight.status?.forecastNote(for: flight, forecast: forecast),
                inAirLine: m.underWay ? m.confidence.savedLine(issuedAt: forecast.issuedAt, inAir: m.inAir) : nil,
                usPart: usPart, now: m.now
            ) { showOutlookSheet = true }))
        }
        // Free users see the grade only: the time in the air and the minutes of chop are Pro (a
        // subscription or a pass for this flight). Unlocking needs a connection, as the timeline's does.
        items.append(AdaptiveItem(StatTiles(
            forecast: forecast, flight: flight, fromMinute: m.minute,
            leftToFly: m.minute.map { _ in
                InFlightCopy.minutesLeft(to: inFlight.landing(of: flight, forecast: forecast), now: m.now)
            },
            offlineInAir: m.minute != nil && m.connection.isConnectionProblem,
            unlock: m.fullAccess ? nil : { paywalls.unlock(.timelineLocked, flight: flight) {} })))
        if m.fullAccess {
            items.append(AdaptiveItem(TimelineCard(
                forecast: forecast, flight: flight, confidence: m.confidence, nowMinute: m.minute,
                sweepFromAdvance: justConfirmed)))
            if !forecast.segments.isEmpty {
                // In the air, only what's still ahead; once nothing is, say so.
                let stretches = forecast.expectedStretches(departure: flight.departureAt)
                    .filter { segment in m.minute.map { segment.endMin >= $0 } ?? true }
                items.append(AdaptiveItem(StretchesTitle(inAir: m.minute != nil)))
                if stretches.isEmpty {
                    items.append(AdaptiveItem(ClearToLandingCard(outlook: forecast.isGlobalOutlook), phoneSpacing: 12))
                }
                for (index, segment) in stretches.enumerated() {
                    items.append(AdaptiveItem(
                        StretchCard(
                            segment: segment, forecast: forecast, flight: flight, nowMinute: m.minute,
                            isMain: segment.startMin == mainStretch?.startMin, index: index, visible: rowsVisible
                        ) { openWarning = $0 },
                        id: "stretch-\(segment.startMin)", phoneSpacing: 12))
                }
            }
        } else {
            items.append(AdaptiveItem(LockedTimelineCard(
                forecast: forecast, offlineInAir: m.minute != nil && m.connection.isConnectionProblem,
                isOpening: paywalls.isOpening
            ) {
                paywalls.unlock(.timelineLocked, flight: flight) {}
            }))
        }
        items.append(AdaptiveItem(BreathingButton()))
        items.append(AdaptiveItem(ForecastFooter(
            forecast: forecast, confidence: m.confidence, underWay: m.underWay, offline: m.connection != .none,
            checkedAt: OfflineCopy.lastChecked(syncedAt: store.syncedAt, issued: [forecast.issuedAt]), now: m.now,
            airportZone: flight.originTimeZone)))
        // On the phone 18 pt apart (12 within the stretches), the first under the screen's entries above.
        return items.enumerated().map { index, item in
            let spaced = item.spaced(index == 0 ? leadSpacing : item.phoneSpacing ?? 18)
            return fade < 1 ? spaced.faded(fade) : spaced
        }
    }

    /// The stretch the "Why it's bumpy here" link explains: the strongest, then the longest.
    private var mainStretch: Forecast.Segment? {
        forecast.segments.max { ($0.severity, $0.minutes) < ($1.severity, $1.minutes) }
    }
}

/// "What to expect", or in the air "Still ahead".
private struct StretchesTitle: View, DuoPlaced {
    let inAir: Bool
    var duoRole: DuoRole { .heading }

    var body: some View {
        Text(inAir ? InFlightCopy.stillAhead : "What to expect").font(.bcSection)
    }
}

/// Nothing left ahead in the air.
private struct ClearToLandingCard: View, DuoPlaced {
    let outlook: Bool
    var duoRole: DuoRole { .pair }

    var body: some View {
        HStack(spacing: 12) {
            // An outlook never says smooth, so its glass stays the dashed "not known".
            WaterGlass(severity: outlook ? nil : .smooth, size: 26)
            Text(InFlightCopy.clearToLanding(outlook: outlook) + ".").font(.bcHeadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .skyCard(cornerRadius: 16, padding: 14)
    }
}

/// One stretch of "What to expect", settling in one after another.
private struct StretchCard: View, DuoPlaced {
    let segment: Forecast.Segment
    let forecast: Forecast
    let flight: Flight
    let nowMinute: Int?
    let isMain: Bool
    let index: Int
    let visible: Bool
    let openWarning: (Forecast.Warning) -> Void
    var duoRole: DuoRole { .pair }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if forecast.isOutlook(segment, departure: flight.departureAt) {
                OutlookSegmentRow(
                    segment: segment, warning: forecast.warning(for: segment),
                    showsBetaTag: !forecast.confirmedStretches.isEmpty, openWarning: openWarning)
            } else {
                SegmentRow(
                    segment: segment, isMain: isMain, nowMinute: nowMinute,
                    gustyCity: segment.gustyEnd.flatMap(flight.gustyCity))
            }
        }
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 14)
            .animation(Theme.motion(reduceMotion).delay(0.15 * Double(index)), value: visible)
    }
}

/// Into the breathing screen.
private struct BreathingButton: View, DuoPlaced {
    @Environment(Router.self) private var router
    var duoRole: DuoRole { .flow }

    var body: some View {
        Button {
            router.breathingFrom = "forecast"
            router.showBreathing = true
        } label: {
            Label("Practice breathing", systemImage: "wind")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
    }
}

/// Remembers the confidence each flight was last shown with, so the app can mark the moment
/// an advance forecast is confirmed (one soft haptic, a sweep across the timeline).
enum ConfidenceMemory {
    static func didFirmUp(flight: UUID, now confidence: Forecast.Confidence) -> Bool {
        let key = "confidence.\(flight)"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(confidence.attributeValue, forKey: key)
        return previous == "early" && ["partly_confirmed", "confirmed"].contains(confidence.attributeValue)
    }
}

private struct GradeCard: View, DuoPlaced {
    var duoRole: DuoRole { .trailing }
    let grade: Forecast.Grade
    let forecast: Forecast
    let confidence: Forecast.Confidence
    /// "Updated for the new 7:55 AM departure", when a delay moved the forecast.
    var departureNote: String?
    /// Once the flight is under way: what's saved and how old it is, instead of when it firms up.
    var inAirLine: String?
    var usPart: Forecast.USPart?
    var now: Date = .now
    let openOutlook: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if confidence.isBeta {
                Button(action: openOutlook) { ConfidenceBadge(confidence: confidence) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Explains the global outlook")
            } else {
                ConfidenceBadge(confidence: confidence)
            }
            if let departureNote {
                Label(departureNote, systemImage: "arrow.clockwise")
                    .font(.bcFootnoteStrong)
                    .foregroundStyle(Theme.accent)
            }
            AdaptiveStack {
                WaterGlass(severity: forecast.worstSeverity, size: 44)
                Text(forecast.isGlobalOutlook ? grade.outlookHeadline : grade.headline)
                    .font(.bcDisplay)
                    .displayTypeLimit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(forecast.isGlobalOutlook ? grade.outlookSummary : grade.summary)
            // Shown to everyone, free included: an advance forecast firms up closer to the flight.
            Text(
                !forecast.officialWarnings.isEmpty
                    ? GlobalOutlookCopy.statusWarning
                    : inAirLine ?? confidence.statusLine(now: now, durationMin: forecast.durationMin, usPart: usPart))
                .font(.bcSubheadlineStrong)
                .foregroundStyle(.secondary)
        }
        .skyCard()
        .accessibilityElement(children: .combine)
    }
}

struct ConfidenceBadge: View {
    let confidence: Forecast.Confidence

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(confidence.title)
                if confidence.isBeta { BetaTag() }
            }
        } icon: {
            Image(systemName: confidence.symbol)
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.bcCaptionStrong)
        .foregroundStyle(confidence.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.background.opacity(0.7), in: .capsule)
        .animation(Theme.spring, value: confidence.title)
    }
}

/// Minutes of smooth air, light chop, and moderate or stronger, adding up to the whole flight;
/// in the air, only the minutes still ahead. Outlook routes keep the flight's length and an
/// approximate total. Without full access the numbers stay hidden.
private struct StatTiles: View, DuoPlaced {
    var duoRole: DuoRole { .trailing }
    let forecast: Forecast
    let flight: Flight
    /// Minutes since takeoff while flying: the chop tiles count only what's ahead.
    var fromMinute: Int?
    /// Minutes to landing while flying, the same count as the in-flight card's landing line.
    var leftToFly: Int?
    /// In the air with no connection: unlocking needs one, so locked tiles say so instead of acting as a button.
    var offlineInAir = false
    /// Set when the numbers are locked: tapping a tile opens the paywall.
    var unlock: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var locked: Bool { unlock != nil }

    var body: some View {
        if locked, offlineInAir {
            // Not a button: nothing can open until there's a connection. The same note as the
            // locked timeline card.
            VStack(alignment: .leading, spacing: 8) {
                tiles
                Label(InFlightCopy.timelineOffline, systemImage: "wifi")
                    .font(.bcSubheadlineStrong)
                    .foregroundStyle(.secondary)
            }
        } else if let unlock {
            Button(action: unlock) { tiles }
                .buttonStyle(.plain)
                .accessibilityHint(
                    forecast.isGlobalOutlook
                        ? "Unlock to see the time in the air and minutes of turbulence"
                        : "Unlock to see minutes of smooth air and turbulence")
        } else {
            tiles
        }
    }

    @ViewBuilder
    private var tiles: some View {
        if forecast.isGlobalOutlook {
            outlookTiles
        } else {
            exactTiles
        }
    }

    private var from: Int { max(fromMinute ?? 0, 0) }
    /// Counting from the plane's minute rather than over the whole flight.
    private var countsAhead: Bool { fromMinute != nil }

    /// Outlook routes only. The whole flight on the ground; what's left of it in the air.
    @ViewBuilder
    private var timeTile: some View {
        if let leftToFly {
            tile("Left to fly", leftToFly.durationText, spoken: leftToFly.spokenDurationText)
        } else {
            let minutes = forecast.durationMin ?? 0
            tile("In the air", minutes.durationText, spoken: minutes.spokenDurationText)
        }
    }

    /// Outlook routes: no exact minutes of chop. The flight's length and an approximate total.
    private var outlookTiles: some View {
        let bumpy = forecast.segments.map { max($0.endMin - max($0.startMin, from) + 1, 0) }.reduce(0, +)
        return HStack(alignment: .top, spacing: 10) {
            timeTile
            tile(
                countsAhead ? "Bumps possible ahead" : "Bumps possible",
                bumpy == 0 ? "None major" : "About \(bumpy.roughMinutes.durationText)",
                spoken: bumpy == 0 ? nil : "About \(bumpy.roughMinutes.spokenDurationText)")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var exactTiles: some View {
        // The samples run from takeoff to landing inclusive, one more than the flight's minutes:
        // the landing minute isn't counted, so the three tiles add up to the flight.
        let end = forecast.durationMin ?? Int.max
        let ahead = forecast.samples.filter { $0.min >= from && $0.min < end }
        let smooth = ahead.filter { $0.severity == .smooth }.count
        let light = ahead.filter { $0.severity == .light }.count
        let moderate = ahead.filter { $0.severity >= .moderate }.count
        let strong = ahead.filter { $0.severity == .severe }.count
        // Locked, the title is the same either way, so it doesn't give away whether there's strong air.
        let strongTitle = locked || strong > 0
        let third = strongTitle ? "Moderate or strong" : "Moderate"
        // Three across, all the same height; one per row at accessibility sizes.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            tile(countsAhead ? "Smooth ahead" : "Smooth", smooth.durationText, spoken: smooth.spokenDurationText)
            tile(countsAhead ? "Light chop ahead" : "Light chop", light.durationText, spoken: light.spokenDurationText)
            // The plum line is the only colour on a tile: it means strong, as everywhere else.
            tile(
                countsAhead ? "\(third) ahead" : third, moderate.durationText, spoken: moderate.spokenDurationText,
                note: strong > 0 ? "\(strong.durationText) strong" : nil,
                spokenNote: "\(strong.spokenDurationText) strong")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// `spoken` and `spokenNote` are what VoiceOver says for the value and the note ("3 hours 32
    /// minutes" for "3 h 32 min").
    private func tile(
        _ title: String, _ value: String, spoken: String? = nil, note: String? = nil, spokenNote: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if locked {
                    // A stand-in, never the real number, so nothing reads through the blur or VoiceOver.
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.bcSubheadline).foregroundStyle(Theme.accent)
                        Text("00 min").blur(radius: 6).accessibilityHidden(true)
                    }
                    .accessibilityLabel("Locked")
                } else {
                    Text(value).contentTransition(.numericText())
                        .accessibilityLabel(spoken ?? value)
                }
            }
            .font(.bcFigure)
            // "4 h 54 min" stays on one line in a third of a small phone.
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(title).font(.bcCaption).foregroundStyle(.secondary)
            if let note, !locked {
                Text(note).font(.bcCaption).foregroundStyle(Theme.color(.severe))
                    .accessibilityLabel(spokenNote ?? note)
            }
        }
        .frame(maxWidth: locked ? .infinity : nil, maxHeight: .infinity, alignment: .topLeading)
        .skyCard(cornerRadius: 16, padding: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Bumpiness minute by minute. Draws takeoff → landing on first open, sweeps when an advance
/// forecast is confirmed, scrubs with a tick when crossing into a different severity.
private struct TimelineCard: View {
    let forecast: Forecast
    let flight: Flight
    let confidence: Forecast.Confidence
    var nowMinute: Int? = nil
    var sweepFromAdvance = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    @State private var reveal: CGFloat = 1
    @State private var selectedMinute: Int?
    @State private var focusedStretch = 0
    /// The plot's width, for spacing the hour labels (`TimelineAxis`). Only the labels follow it.
    @State private var plotWidth: CGFloat = 0
    /// How much larger the caption labels are than at the default text size.
    @ScaledMetric(relativeTo: .caption) private var labelScale: CGFloat = 1
    /// The Duo spaces its hour marks to fit; the iPhone keeps one an hour.
    @Environment(\.isWideLayout) private var isWideLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bumps along the way").font(.bcSection)
            ZStack {
                // Underneath: the advance forecast (sweep) or nothing yet (first draw).
                chart(dimmed: true)
                    .opacity(sweepFromAdvance ? 0.4 : 0)
                chart(dimmed: false)
                    .mask(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle().frame(width: geo.size.width * reveal)
                        }
                    }
            }
            // 190 pt as on the iPhone; lower when it runs across a wide screen.
            .modifier(ChartHeightForWidth())
            .chartXSelection(value: $selectedMinute)
            .sensoryFeedback(.selection, trigger: selectedSeverity) { _, _ in hapticsEnabled }
            .accessibilityElement()
            .accessibilityLabel("Turbulence timeline")
            .accessibilityValue(accessibilityStretch)
            .accessibilityAdjustableAction { direction in
                let count = max(forecast.segments.count, 1)
                switch direction {
                case .increment: focusedStretch = min(focusedStretch + 1, count - 1)
                case .decrement: focusedStretch = max(focusedStretch - 1, 0)
                @unknown default: break
                }
            }
            .accessibilityChartDescriptor(TimelineAudioGraph(forecast: forecast))
            Legend()
            if forecast.isGlobalOutlook {
                OutlookLegend(hasConfirmed: !forecast.confirmedStretches.isEmpty)
            }
        }
        .skyCard()
        .onAppear(perform: animateIn)
    }

    private var yMax: Double { max(0.4, forecast.samples.map(\.edr).max() ?? 0) }

    /// Global outlook: confirmed minutes stay exact; outlook minutes become coarse 30-minute blocks.
    private var exactSamples: [Forecast.Sample] {
        forecast.isGlobalOutlook ? forecast.samples.filter { !isAdvance($0.min) } : forecast.samples
    }

    private var outlookBlocks: [OutlookBlock] {
        guard forecast.isGlobalOutlook else { return [] }
        let outlook = forecast.samples.filter { isAdvance($0.min) }
        return Dictionary(grouping: outlook) { $0.min / OutlookBlock.minutes }
            .values
            .compactMap { group in
                guard let first = group.map(\.min).min(), let last = group.map(\.min).max() else { return nil }
                // On its own the outlook shows light at most, like its rows; near a warning or pilot report it keeps its level.
                let peak = group.map(\.edr).max() ?? 0
                let nearWarning = (forecast.warnings ?? []).contains { $0.startMin <= last && first <= $0.endMin }
                return OutlookBlock(start: first, end: last + 1, edr: nearWarning ? peak : min(peak, OutlookBlock.lightCap))
            }
            .sorted { $0.start < $1.start }
    }

    private func chart(dimmed: Bool) -> some View {
        let axis = TimelineAxis(totalMinutes: (forecast.samples.last?.min ?? 0) + 1, plotWidth: plotWidth, labelScale: labelScale)
        return Chart {
            ForEach(exactSamples, id: \.min) { sample in
                RectangleMark(
                    xStart: .value("Minutes into flight", sample.min),
                    xEnd: .value("Minutes into flight", sample.min + 1),
                    yStart: .value("Bumpiness", 0),
                    yEnd: .value("Bumpiness", max(sample.edr, 0.02))
                )
                .foregroundStyle(Theme.color(sample.severity).gradient)
                .opacity(!dimmed && !forecast.isGlobalOutlook && isAdvance(sample.min) ? 0.4 : 1)
            }
            ForEach(outlookBlocks, id: \.start) { block in
                RectangleMark(
                    xStart: .value("Minutes into flight", block.start),
                    xEnd: .value("Minutes into flight", block.end),
                    yStart: .value("Bumpiness", 0),
                    yEnd: .value("Bumpiness", max(block.edr, 0.02))
                )
                // Never smooth: below light, an outlook block is neutral ink, not the smooth colour.
                .foregroundStyle(Severity(edr: block.edr) < .light ? Theme.secondaryInk : Theme.color(Severity(edr: block.edr)))
                .opacity(OutlookBlock.opacity)
            }
            if forecast.isGlobalOutlook {
                // A solid accent strip under the axis marks what's confirmed.
                ForEach(forecast.confirmedStretches, id: \.lowerBound) { range in
                    RectangleMark(
                        xStart: .value("Minutes into flight", range.lowerBound),
                        xEnd: .value("Minutes into flight", range.upperBound + 1),
                        yStart: .value("Bumpiness", 0),
                        yEnd: .value("Bumpiness", yMax * 0.025)
                    )
                    .foregroundStyle(Theme.accent)
                }
            }
            if !dimmed {
                ForEach(forecast.warnings ?? []) { warning in
                    if warning.isOfficial {
                        RectangleMark(
                            xStart: .value("Minutes into flight", warning.startMin),
                            xEnd: .value("Minutes into flight", warning.endMin + 1),
                            yStart: .value("Bumpiness", 0),
                            yEnd: .value("Bumpiness", yMax)
                        )
                        .foregroundStyle(Theme.ink.opacity(0.08))
                        .annotation(position: .overlay, alignment: .top) {
                            Text("⚑ Official warning")
                                .font(.bcCaption2Strong)
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Theme.ink, in: .capsule)
                                .fixedSize()
                        }
                    } else {
                        PointMark(
                            x: .value("Minutes into flight", warning.startMin),
                            y: .value("Bumpiness", yMax * 0.92)
                        )
                        .symbolSize(0)
                        .annotation(position: .overlay) {
                            Image(systemName: "flag").font(.bcCaption2Strong).foregroundStyle(Theme.secondaryInk)
                        }
                    }
                }
            }
            if !dimmed, let nowMinute {
                RuleMark(x: .value("Now", nowMinute))
                    .foregroundStyle(Theme.ink)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .annotation(position: .top, alignment: .leading) {
                        Text("You are here").font(.bcCaption2Strong)
                    }
            }
            if !dimmed, let selectedMinute, let sample = sample(at: selectedMinute) {
                RuleMark(x: .value("Selected", selectedMinute))
                    .foregroundStyle(Theme.secondaryInk)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        Text(selectionText(selectedMinute, sample))
                            .font(.bcCaptionStrong.monospacedDigit())
                            .padding(6)
                            .background(.regularMaterial, in: .capsule)
                    }
            }
        }
        .chartYScale(domain: 0...yMax)
        // Takeoff to landing: wide marks (outlook blocks, warning bands) mustn't pad it below zero.
        .chartXScale(domain: 0...max((forecast.samples.last?.min ?? 0) + 1, 1))
        .chartYAxis {
            AxisMarks(values: [0.10, 0.22, 0.34]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel {
                    if let edr = value.as(Double.self) { Text(Severity(edr: edr).title) }
                }
            }
        }
        .chartXAxis {
            if isWideLayout {
                // The Duo's widths change with the fold: hour marks spaced to fit, never touching.
                AxisMarks(values: axis.ticks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let minute = value.as(Int.self) {
                            Text(minute == 0 ? "Takeoff" : "\(minute / 60) h").monospacedDigit()
                                // A label with no room keeps its gridline but isn't drawn.
                                .opacity(axis.labeled.contains(minute) ? 1 : 0)
                        }
                    }
                }
            } else {
                AxisMarks(values: .stride(by: 60)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let minute = value.as(Int.self) { Text(minute == 0 ? "Takeoff" : "\(minute / 60) h").monospacedDigit() }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let width = proxy.plotFrame.map { geo[$0].width } ?? 0
                Color.clear
                    .onAppear { plotWidth = width }
                    // A change of hour marks crossfades once the card has finished changing width.
                    .onChange(of: width) {
                        if abs(plotWidth - width) > 0.5 {
                            withAnimation(.easeInOut(duration: 0.25).delay(0.45)) { plotWidth = width }
                        }
                    }
            }
        }
    }

    private func isAdvance(_ minute: Int) -> Bool {
        switch confidence {
        case .early: true
        case .partly(let ranges), .globalOutlook(let ranges): !ranges.contains { $0.contains(minute) }
        case .confirmed: false
        }
    }

    /// Exact for confirmed minutes; approximate with a range on outlook minutes.
    private func selectionText(_ minute: Int, _ sample: Forecast.Sample) -> String {
        guard forecast.isGlobalOutlook, isAdvance(minute) else {
            return "\(minute == 0 ? "Takeoff" : "\(minute.durationText) in") · \(sample.severity.title)"
        }
        let when = minute < 5 ? "Soon after takeoff" : "About \(minute.roughMinutes.durationText) in"
        let segment = forecast.segments.first { $0.startMin <= minute && minute <= $0.endMin }
        let level = segment.map { $0.outlookRange(warning: forecast.warning(for: $0)) } ?? "No major bumps"
        return "\(when) · \(level)"
    }

    private func sample(at minute: Int) -> Forecast.Sample? {
        forecast.samples.first { $0.min == minute }
    }

    private var selectedSeverity: Severity? { selectedMinute.flatMap { sample(at: $0)?.severity } }

    private var accessibilityStretch: String {
        guard forecast.segments.indices.contains(focusedStretch) else {
            return forecast.isGlobalOutlook ? "No major bumps expected" : "Smooth the whole way"
        }
        let s = forecast.segments[focusedStretch]
        if forecast.isOutlook(s, departure: flight.departureAt) {
            return "\(s.approximateTiming): \(s.outlookRange(warning: forecast.warning(for: s)).lowercased()). "
                + "Stretch \(focusedStretch + 1) of \(forecast.segments.count)."
        }
        let when = s.startMin == 0 ? "Right after takeoff" : "\(s.startMin.spokenDurationText) in"
        return "\(when), \(s.severity.title.lowercased()) for \(s.minutes.spokenDurationText). Stretch \(focusedStretch + 1) of \(forecast.segments.count)."
    }

    /// First open of each forecast draws the timeline from takeoff to landing; a forecast that
    /// was just confirmed sweeps from the faded advance version. Reduce Motion: a cross-fade.
    private func animateIn() {
        let key = "revealed.\(flight.id).\(forecast.issuedAt?.timeIntervalSince1970 ?? 0)"
        let firstOpen = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        guard firstOpen || sweepFromAdvance else { return }
        if reduceMotion {
            reveal = 1
            return
        }
        reveal = 0
        withAnimation(.smooth(duration: sweepFromAdvance ? 0.7 : 1.4)) { reveal = 1 }
    }
}

/// The timeline's hour marks: every 1, 2, 3, 4, 6 or 12 hours, whichever is the closest that
/// leaves room between labels at this width, so a long flight in a narrow card never runs them
/// together. A label that would touch "Takeoff" or run past the end keeps its gridline only.
struct TimelineAxis {
    // The caption labels' widths with a margin at the default text size: "Takeoff", and "10 h"
    // for the hour marks. Larger text scales them by `labelScale`.
    static let takeoffWidth: CGFloat = 42
    static let hourWidth: CGFloat = 24
    static let gap: CGFloat = 6

    let ticks: [Int]
    let labeled: Set<Int>

    init(totalMinutes: Int, plotWidth: CGFloat, labelScale: CGFloat = 1) {
        let takeoffWidth = Self.takeoffWidth * labelScale
        let hourWidth = Self.hourWidth * labelScale
        guard totalMinutes > 0 else {
            ticks = [0]
            labeled = [0]
            return
        }
        // Until the plot is measured, hourly, as before.
        guard plotWidth > 0 else {
            ticks = Array(stride(from: 0, to: totalMinutes, by: 60))
            labeled = Set(ticks)
            return
        }
        let perMinute = plotWidth / CGFloat(totalMinutes)
        let hours = [1, 2, 3, 4, 6, 12].first { CGFloat($0 * 60) * perMinute >= hourWidth + Self.gap } ?? 12
        ticks = Array(stride(from: 0, to: totalMinutes, by: hours * 60))
        var labeled: Set<Int> = [0]
        for minute in ticks.dropFirst() {
            let x = CGFloat(minute) * perMinute
            if x >= takeoffWidth + Self.gap, x + hourWidth <= plotWidth { labeled.insert(minute) }
        }
        self.labeled = labeled
    }

    /// Where a label starts on the plot (labels start at their gridline).
    static func x(of minute: Int, totalMinutes: Int, plotWidth: CGFloat) -> CGFloat {
        CGFloat(minute) * plotWidth / CGFloat(max(totalMinutes, 1))
    }
}

/// The chart's height from the width it's given: 190 pt at phone and column widths, easing to
/// 150 pt as it runs across a wide screen. Decided in layout, so the card needs no idea where it is.
/// When its width changes (the Duo's fold), the plot's width is animated and the chart laid out
/// again at every step, so the bars stretch, the height follows and the marks stay on their minutes.
private struct ChartHeightForWidth: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Only a wide layout eases the height; a phone keeps 190 pt in any orientation.
    @Environment(\.isWideLayout) private var isWideLayout
    /// The width the chart appears at: animated towards the width it's laid out at.
    @State private var shownWidth: CGFloat = 0

    // The chart is laid out once, at the width it's given. While the card changes width, a
    // render-only scale carries it from the old size, so Swift Charts isn't laid out every frame.
    func body(content: Content) -> some View {
        if isWideLayout {
            morphing(content)
        } else {
            // The iPhone: a fixed 190 pt, as it always was.
            content.frame(height: 190)
        }
    }

    private func morphing(_ content: Content) -> some View {
        ChartHeightLayout(eases: true) { content }
            // Straight to the new size, unanimated: the chart lays out once, not at every size between.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if shownWidth == 0 || reduceMotion || abs(shownWidth - width) < 1 {
                    shownWidth = width
                } else {
                    withAnimation(DuoMotion.move) { shownWidth = width }
                }
            }
            .transaction { $0.animation = nil }
            // Flattened, so the scale moves a finished image instead of redrawing the chart.
            .drawingGroup()
            .modifier(ChartWidthMorph(shownWidth: shownWidth, eases: isWideLayout))
    }
}

/// Scales the chart from the size it had at `shownWidth` to the size it's laid out at; the
/// identity once the animation ends. The now line and the warning band scale with it.
private struct ChartWidthMorph: GeometryEffect {
    var shownWidth: CGFloat
    var eases: Bool

    var animatableData: CGFloat {
        get { shownWidth }
        set { shownWidth = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard shownWidth > 0, size.width > 0, size.height > 0 else { return ProjectionTransform() }
        let x = shownWidth / size.width
        let y = ChartHeightLayout.height(for: shownWidth, eases: eases) / size.height
        return ProjectionTransform(CGAffineTransform(scaleX: x, y: y))
    }
}

private struct ChartHeightLayout: Layout {
    /// Whether the height eases lower with width (a wide layout); otherwise always 190 pt.
    var eases: Bool

    /// 190 pt up to 480 pt wide, 150 pt from 640 pt, and in between in proportion, so a widening
    /// chart grows lower continuously instead of snapping.
    static func height(for width: CGFloat, eases: Bool = true) -> CGFloat {
        eases ? 190 - 40 * min(max((width - 480) / 160, 0), 1) : 190
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: Self.height(for: width, eases: eases))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

/// Swift Charts audio graph: VoiceOver can play the bumpiness through the flight.
private struct TimelineAudioGraph: AXChartDescriptorRepresentable {
    let forecast: Forecast

    func makeChartDescriptor() -> AXChartDescriptor {
        let minutes = Double(forecast.samples.last?.min ?? 1)
        let x = AXNumericDataAxisDescriptor(
            title: "Minutes into flight", range: 0...max(minutes, 1), gridlinePositions: []
        ) { "\(Int($0).durationText)" }
        let y = AXNumericDataAxisDescriptor(title: "Bumpiness", range: 0...0.5, gridlinePositions: [0.10, 0.22, 0.34]) {
            Severity(edr: $0).title
        }
        let series = AXDataSeriesDescriptor(
            name: "Bumpiness", isContinuous: true,
            dataPoints: forecast.samples.map { .init(x: Double($0.min), y: $0.edr) })
        return AXChartDescriptor(
            title: "Turbulence timeline", summary: forecast.grade?.summary, xAxis: x, yAxis: y,
            additionalAxes: [], series: [series])
    }
}

/// A coarse block of outlook minutes on the chart.
private struct OutlookBlock {
    static let minutes = 30
    static let opacity = 0.42
    /// The top of light chop on the EDR scale (moderate starts at 0.22).
    static let lightCap = 0.21
    let start: Int
    let end: Int
    let edr: Double
}

/// "Confirmed, exact" · "Outlook, approximate" under global outlook charts.
private struct OutlookLegend: View {
    let hasConfirmed: Bool

    @Environment(\.isWideLayout) private var isWideLayout

    var body: some View {
        // On the Duo, side by side when they fit and one above the other at large text sizes.
        Group {
            if isWideLayout {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { items }
                    VStack(alignment: .leading, spacing: 6) { items }
                }
            } else {
                HStack(spacing: 14) { items }
            }
        }
        .font(.bcCaption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var items: some View {
        if hasConfirmed {
            HStack(spacing: 4) {
                Capsule().fill(Theme.accent).frame(width: 14, height: 4)
                Text(GlobalOutlookCopy.legendConfirmed)
            }
        }
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.secondaryInk.opacity(OutlookBlock.opacity)).frame(width: 14, height: 8)
            Text(GlobalOutlookCopy.legendOutlook)
        }
    }
}

private struct Legend: View {
    @Environment(\.isWideLayout) private var isWideLayout

    var body: some View {
        if isWideLayout {
            wrapping
        } else {
            HStack(spacing: 14) {
                ForEach(Severity.allCases, id: \.self) { severity in
                    HStack(spacing: 4) {
                        WaterGlass(severity: severity, size: 14)
                        Text(severity.title)
                    }
                }
            }
            .font(.bcCaption)
            .foregroundStyle(.secondary)
        }
    }

    /// On the Duo: one row when it fits; two columns at large text sizes, never a word broken.
    private var wrapping: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                ForEach(Severity.allCases, id: \.self) { item($0) }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: Severity.allCases.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(Severity.allCases[start..<min(start + 2, Severity.allCases.count)], id: \.self) { item($0) }
                    }
                }
            }
        }
        .font(.bcCaption)
        .foregroundStyle(.secondary)
    }

    private func item(_ severity: Severity) -> some View {
        HStack(spacing: 4) {
            WaterGlass(severity: severity, size: 14)
            Text(severity.title).fixedSize()
        }
    }
}

/// Free users see the grade; the timeline is Pro. Show its shape without the detail.
private struct LockedTimelineCard: View {
    let forecast: Forecast
    /// In the air with no connection: unlocking needs one, so say so instead of offering a button.
    var offlineInAir = false
    /// The paywall is on its way (it can take a minute on plane wifi).
    var isOpening = false
    let unlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bumps along the way").font(.bcSection)
            WaveTimeline(forecast: forecast, height: 90)
                .blur(radius: 8)
                .accessibilityHidden(true)
            Text(teaser).font(.bcSubheadline)
            if offlineInAir {
                Label(InFlightCopy.timelineOffline, systemImage: "wifi")
                    .font(.bcSubheadlineStrong)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: unlock) {
                    Label {
                        Text(forecast.segments.isEmpty ? "See the full timeline" : "See when the bumps are")
                    } icon: {
                        if isOpening {
                            ProgressView().controlSize(.small).tint(Theme.onAccent)
                        } else {
                            Image(systemName: "lock.open")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                .tint(Theme.accent)
                .disabled(isOpening)
            }
            Text("Includes the full timeline, update alerts and in-flight countdowns.")
                .font(.bcFootnote)
                .foregroundStyle(.secondary)
        }
        .skyCard()
    }

    private var teaser: String {
        switch forecast.segments.count {
        case 0: "No bumpy stretches expected. See the minute-by-minute timeline."
        case 1: "1 bumpy stretch on this flight. See exactly when, and how it'll feel."
        default: "\(forecast.segments.count) bumpy stretches on this flight. See exactly when, and how they'll feel."
        }
    }
}

/// On the Duo a stretch card fills its row, so two side by side match; on the iPhone, as it was.
struct FillsPairHeight: ViewModifier {
    @Environment(\.isWideLayout) private var isWideLayout

    func body(content: Content) -> some View {
        if isWideLayout {
            content.frame(maxHeight: .infinity, alignment: .top)
        } else {
            content
        }
    }
}

private struct SegmentRow: View {
    let segment: Forecast.Segment
    let isMain: Bool
    /// Minutes since takeoff while flying, to count down to the stretch (only those still ahead are listed).
    var nowMinute: Int?
    /// Where it's gusty, when gusty wind at takeoff or landing explains the stretch.
    var gustyCity: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WaterGlass(severity: segment.severity, size: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(timing).font(.bcHeadline.monospacedDigit())
                Text("\(segment.severity.title) for about \(segment.minutes) min while \(FlightPhase.title(segment.phase))")
                    .font(.bcSubheadline)
                Text(segment.severity.feelsLike).font(.bcSubheadline).foregroundStyle(.secondary)
                if let gustyCity, let label = segment.gustyLabel(city: gustyCity),
                    let sentence = segment.gustySentence(city: gustyCity)
                {
                    GustyRowLabel(label: label, sentence: sentence)
                }
                if isMain {
                    NavigationLink {
                        ExplainerView(explainer: Explainer.forStretch(segment), from: "forecast")
                    } label: {
                        Label("Why it's bumpy here", systemImage: "book.pages")
                            .font(.bcSubheadlineStrong)
                    }
                    .tint(Theme.accent)
                    .padding(.top, 2)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(FillsPairHeight())
        .skyCard(cornerRadius: 16, padding: 14)
    }

    /// "Right after takeoff" · "22 min into the flight"; in the air
    /// "Now · about 4 min to go" · "In about 6 min · 22 min into the flight".
    private var timing: String {
        let into = segment.startMin == 0 ? "Right after takeoff" : "\(segment.startMin.durationText) into the flight"
        guard let now = nowMinute else { return into }
        if segment.startMin <= now { return "Now · about \((segment.endMin - now + 1).durationText) to go" }
        return "In about \((segment.startMin - now).durationText) · \(segment.startMin.durationText) into the flight"
    }
}

/// Confidence label, when it was updated and when it next updates. No source names. Once the
/// flight is under way, or offline, it says what's saved on the phone instead of promising an update.
private struct ForecastFooter: View, DuoPlaced {
    var duoRole: DuoRole { .flow }
    let forecast: Forecast
    let confidence: Forecast.Confidence
    /// Flying, or past departure.
    var underWay = false
    /// Showing what's saved: no connection, or the last update didn't go through.
    var offline = false
    /// When the phone last heard from us: the later of its last sync and this forecast.
    var checkedAt: Date?
    var now: Date = .now
    /// The departure airport's zone: these times are the phone's, so they name it when the two differ.
    var airportZone: TimeZone?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                HStack(spacing: 6) {
                    Text(confidence.title)
                    if confidence.isBeta { BetaTag() }
                }
            } icon: {
                Image(systemName: confidence.symbol)
            }
            .font(.bcCardTitle)
            .foregroundStyle(confidence.color)
            Text(underWay ? confidence.inFlightExplanation : confidence.explanation(now: now)).font(.bcSubheadline)
            if confidence.isBeta {
                Text("Based on: \(GlobalOutlookCopy.basedOn)").font(.bcSubheadline).foregroundStyle(.secondary)
            }
            if let meta {
                Text(meta)
                    .font(.bcMeta)
                    .foregroundStyle(.secondary)
            }
        }
        .skyCard()
    }

    /// "Updated 2:20 PM · next update around 3:20 PM" on the ground;
    /// "Forecast from 1:20 PM · checked for updates at 2:10 PM" in the air or offline. "Checked" can't
    /// contradict "saved before takeoff": a check in the air can find nothing new.
    private var meta: String? {
        guard let issued = forecast.issuedAt else { return nil }
        let time = { (date: Date) in date.phoneTime(nextTo: airportZone) }
        if underWay || offline {
            return "Forecast from \(time(issued))" + (checkedAt.map { " · checked for updates at \(time($0))" } ?? "")
        }
        return "Updated \(time(issued))"
            + (confidence.nextUpdate(after: issued, now: now).map { " · next update around \(time($0))" } ?? "")
    }
}
