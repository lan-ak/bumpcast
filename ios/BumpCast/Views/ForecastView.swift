import Accessibility
import Charts
import SwiftUI

struct ForecastView: View {
    let forecast: Forecast
    let flight: Flight

    @Environment(Paywalls.self) private var paywalls
    @Environment(InFlight.self) private var inFlight
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    /// Set when this forecast moved from advance to confirmed since the user last saw it.
    @State private var justConfirmed = false
    @State private var rowsVisible = false
    @State private var openWarning: Forecast.Warning?
    @State private var showOutlookSheet = false

    var body: some View {
        let confidence = forecast.confidence(departure: flight.departureAt)
        let fullAccess = paywalls.hasFullAccess(to: flight)
        VStack(alignment: .leading, spacing: 18) {
            // An official warning is the first thing on the screen.
            if let warning = forecast.officialWarnings.first {
                WarningBanner(warning: warning) { openWarning = warning }
            }
            if let grade = forecast.grade {
                GradeCard(grade: grade, forecast: forecast, confidence: confidence) { showOutlookSheet = true }
            }
            StatTiles(forecast: forecast, flight: flight)
            if fullAccess {
                TimelineCard(
                    forecast: forecast, flight: flight, confidence: confidence,
                    nowMinute: inFlight.elapsedMinutes(flight, forecast: forecast),
                    sweepFromAdvance: justConfirmed)
                if !forecast.segments.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("What to expect").font(.bcSection)
                        ForEach(Array(forecast.expectedStretches(departure: flight.departureAt).enumerated()), id: \.element.startMin) {
                            index, segment in
                            Group {
                                if forecast.isOutlook(segment, departure: flight.departureAt) {
                                    OutlookSegmentRow(
                                        segment: segment, warning: forecast.warning(for: segment),
                                        showsBetaTag: !forecast.confirmedStretches.isEmpty
                                    ) { openWarning = $0 }
                                } else {
                                    SegmentRow(segment: segment, isMain: segment.startMin == mainStretch?.startMin)
                                }
                            }
                                .opacity(rowsVisible ? 1 : 0)
                                .offset(y: rowsVisible || reduceMotion ? 0 : 14)
                                .animation(Theme.motion(reduceMotion).delay(0.15 * Double(index)), value: rowsVisible)
                        }
                    }
                }
            } else {
                LockedTimelineCard(forecast: forecast) {
                    paywalls.unlock(.timelineLocked, flight: flight) {}
                }
            }
            Button {
                router.showBreathing = true
            } label: {
                Label("Practise breathing", systemImage: "wind")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            ForecastFooter(forecast: forecast, confidence: confidence)
        }
        .sheet(item: $openWarning) { warning in
            Group {
                if warning.isOfficial { WarningSheet(warning: warning) } else { PilotReportNoteSheet(warning: warning) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showOutlookSheet) {
            GlobalOutlookSheet().presentationDetents([.medium, .large])
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: justConfirmed) { _, new in new && hapticsEnabled }
        .onAppear {
            paywalls.firstGradeViewed(flight)
            justConfirmed = ConfidenceMemory.didFirmUp(flight: flight.id, now: confidence)
            rowsVisible = true
        }
    }

    /// The stretch the "Why it's bumpy here" link explains: the strongest, then the longest.
    private var mainStretch: Forecast.Segment? {
        forecast.segments.max { ($0.severity, $0.minutes) < ($1.severity, $1.minutes) }
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

private struct GradeCard: View {
    let grade: Forecast.Grade
    let forecast: Forecast
    let confidence: Forecast.Confidence
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
            AdaptiveStack {
                WaterGlass(severity: forecast.worstSeverity, size: 44)
                Text(forecast.isGlobalOutlook ? grade.outlookHeadline : grade.headline)
                    .font(.bcDisplay)
                    .displayTypeLimit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(forecast.isGlobalOutlook ? grade.outlookSummary : grade.summary)
            // Shown to everyone, free included: an advance forecast firms up closer to the flight.
            TimelineView(.everyMinute) { context in
                Text(
                    forecast.officialWarnings.isEmpty
                        ? confidence.statusLine(now: context.date, durationMin: forecast.durationMin)
                        : GlobalOutlookCopy.statusWarning)
                    .font(.bcSubheadlineStrong)
                    .foregroundStyle(.secondary)
            }
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

/// Time in the air, minutes of light chop, minutes of moderate or stronger.
private struct StatTiles: View {
    let forecast: Forecast
    let flight: Flight
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if forecast.isGlobalOutlook {
            outlookTiles
        } else {
            exactTiles
        }
    }

    /// Outlook routes: no exact minutes of chop. The flight's length and an approximate total.
    private var outlookTiles: some View {
        let bumpy = forecast.segments.map(\.minutes).reduce(0, +)
        return HStack(alignment: .top, spacing: 10) {
            tile("In the air", (forecast.durationMin ?? 0).durationText)
            tile("Bumps possible", bumpy == 0 ? "None major" : "About \(bumpy.roughMinutes.durationText)")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var exactTiles: some View {
        let light = forecast.samples.filter { $0.severity == .light }.count
        let moderate = forecast.samples.filter { $0.severity >= .moderate }.count
        // Three across, all the same height; one per row at accessibility sizes.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            tile("In the air", (forecast.durationMin ?? 0).durationText)
            tile("Light chop", "\(light) min")
            tile("Moderate", "\(moderate) min")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.bcFigure)
                // "4 h 54 min" stays on one line in a third of a small phone.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(title).font(.bcCaption).foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
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
            .frame(height: 190)
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
                return OutlookBlock(start: first, end: last + 1, edr: group.map(\.edr).max() ?? 0)
            }
            .sorted { $0.start < $1.start }
    }

    private func chart(dimmed: Bool) -> some View {
        Chart {
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
                .foregroundStyle(Theme.color(Severity(edr: block.edr)))
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
            AxisMarks(values: .stride(by: 60)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minute = value.as(Int.self) { Text(minute == 0 ? "Takeoff" : "\(minute / 60) h").monospacedDigit() }
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
        let when = s.startMin == 0 ? "Right after takeoff" : "\(s.startMin.durationText) in"
        return "\(when), \(s.severity.title.lowercased()) for \(s.minutes) minutes. Stretch \(focusedStretch + 1) of \(forecast.segments.count)."
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
    let start: Int
    let end: Int
    let edr: Double
}

/// "Confirmed, exact" · "Outlook, approximate" under global outlook charts.
private struct OutlookLegend: View {
    let hasConfirmed: Bool

    var body: some View {
        HStack(spacing: 14) {
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
        .font(.bcCaption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct Legend: View {
    var body: some View {
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

/// Free users see the grade; the timeline is Pro. Show its shape without the detail.
private struct LockedTimelineCard: View {
    let forecast: Forecast
    let unlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bumps along the way").font(.bcSection)
            WaveTimeline(forecast: forecast, height: 90)
                .blur(radius: 8)
                .accessibilityHidden(true)
            Text(teaser).font(.bcSubheadline)
            Button(action: unlock) {
                Label(forecast.segments.isEmpty ? "See the full timeline" : "See when the bumps are", systemImage: "lock.open")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
            .tint(Theme.accent)
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

private struct SegmentRow: View {
    let segment: Forecast.Segment
    let isMain: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WaterGlass(severity: segment.severity, size: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(timing).font(.bcHeadline.monospacedDigit())
                Text("\(segment.severity.title) for about \(segment.minutes) min while \(FlightPhase.title(segment.phase))")
                    .font(.bcSubheadline)
                Text(segment.severity.feelsLike).font(.bcSubheadline).foregroundStyle(.secondary)
                if isMain {
                    NavigationLink {
                        ExplainerView(explainer: Explainer.forStretch(segment))
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
        .skyCard(cornerRadius: 16, padding: 14)
    }

    private var timing: String {
        segment.startMin == 0 ? "Right after takeoff" : "\(segment.startMin.durationText) into the flight"
    }
}

/// Confidence label, when it was updated and when it next updates. No source names.
private struct ForecastFooter: View {
    let forecast: Forecast
    let confidence: Forecast.Confidence

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
            Text(confidence.explanation).font(.bcSubheadline)
            if confidence.isBeta {
                Text("Based on: \(GlobalOutlookCopy.basedOn)").font(.bcSubheadline).foregroundStyle(.secondary)
            }
            Group {
                if let issued = forecast.issuedAt {
                    Text("Updated \(issued.formatted(date: .omitted, time: .shortened))")
                        + Text(nextUpdate(after: issued).map { " · next update around \($0)" } ?? "")
                }
            }
            .font(.bcMeta)
            .foregroundStyle(.secondary)
        }
        .skyCard()
    }

    private func nextUpdate(after issued: Date) -> String? {
        switch confidence {
        case .globalOutlook: max(issued.addingTimeInterval(6 * 3600), .now.addingTimeInterval(300))
            .formatted(date: .omitted, time: .shortened)
        case .early(let expected): expected > .now ? expected.formatted(date: .omitted, time: .shortened) : nil
        case .partly, .confirmed: max(issued.addingTimeInterval(3600), .now.addingTimeInterval(300))
            .formatted(date: .omitted, time: .shortened)
        }
    }
}
