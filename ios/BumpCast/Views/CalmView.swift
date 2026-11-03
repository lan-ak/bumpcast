import SwiftUI

/// The Calm tab: breathing, timed to the flight when one is in progress.
struct CalmView: View {
    @Environment(Router.self) private var router
    @Environment(FlightStore.self) private var store
    @Environment(InFlight.self) private var inFlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var breathing = false
    /// Tests render the open layout's panes at the Duo's height, without the navigation stack.
    private let contentOnly: Bool

    init(contentOnly: Bool = false) {
        self.contentOnly = contentOnly
    }

    var body: some View {
        if contentOnly {
            panes(height: 635).skyBackground(.night)
        } else {
            screen
        }
    }

    private var screen: some View {
        NavigationStack {
            GeometryReader { geo in
                // Scrolls at large text sizes; otherwise fills the screen, with the orb sized to
                // the screen so tall phones don't end up with empty bands above and below.
                ScrollView {
                    OpenLayout {
                        VStack(spacing: 20) {
                            header
                            Spacer(minLength: 8)
                            // Smaller at accessibility text sizes, so the button stays near the top.
                            orb(diameter: min(geo.size.width * 0.5, geo.size.height * 0.24)
                                * (typeSize.isAccessibilitySize ? 0.5 : 1))
                            breathe
                            Spacer(minLength: 16)
                            readingCards
                        }
                        .padding(24)
                        .frame(minHeight: geo.size.height)
                    } open: {
                        panes(height: geo.size.height)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .skyBackground(.night)
            .toolbar(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    /// Its own header: the system title can't follow the night sky's light ink.
    private var header: some View {
        Text("Calm")
            .font(.bcDisplay)
            .displayTypeLimit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// "Breathe through the bumps", the heads-up, and the way in.
    @ViewBuilder
    private var breathe: some View {
        Text("Breathe through the bumps")
            .font(.bcDisplay)
            .displayTypeLimit()
            .multilineTextAlignment(.center)
        // On the flight's own minutes, like the flight screen, so the two agree.
        TimelineView(.flightMinutes(takeoff: NextStretch.current(store: store, inFlight: inFlight)?.takeoff ?? .now)) {
            context in
            Text(subtitle(at: max(context.date, .now))).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        Button {
            router.showBreathing = true
        } label: {
            Label("Start breathing", systemImage: "wind").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
        .tint(Theme.accent)
        .controlSize(.large)
    }

    /// Side by side (the open Duo): the orb and Start breathing in one pane, the reading cards in
    /// the other.
    private func panes(height: CGFloat) -> some View {
        VStack(spacing: 20) {
            header
            Spacer(minLength: 8)
            Panes(alignment: .center) {
                VStack(spacing: 16) {
                    orb(diameter: height * 0.27 * (typeSize.isAccessibilitySize ? 0.5 : 1))
                    breathe
                }
            } trailing: {
                readingCards
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 22)
        .frame(minHeight: height)
    }

    /// The same orb as the breathing screen, breathing slowly here too (a glow with Reduce Motion).
    private func orb(diameter: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: Theme.orb,
                center: UnitPoint(x: 0.38, y: 0.32), startRadius: 0, endRadius: diameter * 0.6))
            .frame(width: diameter, height: diameter)
            .shadow(color: Theme.orbGlow.opacity(0.35), radius: diameter * 0.2)
            // Only the breath repeats: the orb's place on screen never rides the animation, so it
            // doesn't drift in while the Duo's columns settle as the screen appears.
            .animation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) { orb in
                orb
                    .scaleEffect(reduceMotion ? 1 : (breathing ? 1 : 0.88))
                    .opacity(reduceMotion ? (breathing ? 1 : 0.7) : 1)
            }
            .onAppear { breathing = true }
            .accessibilityHidden(true)
    }

    /// Two short reads that help mid-flight, so the lower half of the screen has a purpose.
    private var readingCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Good to read now").eyebrow().foregroundStyle(.secondary)
            ForEach(["built", "seatbelt"], id: \.self) { id in
                if let explainer = Explainer.byID(id) {
                    Button {
                        router.explainerFrom = "calm"
                        router.learnPath = [explainer]
                        router.tab = .learn
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(explainer.title).font(.bcHeadline)
                                Text(explainer.subtitle).font(.bcSubheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .skyCard(cornerRadius: 18, padding: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func subtitle(at now: Date) -> String {
        if let next = NextStretch.current(store: store, inFlight: inFlight, now: now) {
            return next.headsUp(now: now)
        }
        return "Breathe in for 4, out for 6. A longer out-breath steadies your body when the plane moves."
    }
}

/// The flight in progress, for heads-ups: the stretch it's in, the next one, or that none is left.
/// Only for people with the countdown, since stretch timing is what it sells, and never for a
/// cancelled or diverted flight.
struct NextStretch {
    let forecast: Forecast
    let takeoff: Date
    let departure: Date

    @MainActor
    static func current(store: FlightStore, inFlight: InFlight, now: Date = .now) -> NextStretch? {
        for flight in store.upcomingFlights {
            guard let forecast = store.forecasts[flight.id], forecast.isShown,
                InFlightMode.isFlying(flight, forecast: forecast, inFlight: inFlight, now: now)
            else { continue }
            guard Paywalls.shared.hasFullAccess(to: flight) else { return nil }
            return NextStretch(forecast: forecast, takeoff: inFlight.effectiveTakeoff(of: flight), departure: flight.departureAt)
        }
        return nil
    }

    /// "Moderate bumps in about 6 min, for about 27 min." · "Light chop now, about 4 min to go." ·
    /// "Smooth to landing." Outlook stretches stay approximate.
    func headsUp(now: Date) -> String {
        let minute = max(0, Int(now.timeIntervalSince(takeoff) / 60))
        if let current = forecast.segments.first(where: { $0.startMin <= minute && minute <= $0.endMin }) {
            if forecast.isOutlook(current, departure: departure) { return "Bumps possible now." }
            return "\(current.severity.phrase.sentenceCased) now, about \((current.endMin - minute + 1).durationText) to go."
        }
        if let next = forecast.segments.first(where: { $0.startMin > minute }) {
            let wait = next.startMin - minute
            if forecast.isOutlook(next, departure: departure) {
                return "Bumps possible in about \(wait.roughMinutes.durationText)."
            }
            return "\(next.severity.phrase.sentenceCased) in about \(wait.durationText), for about \(next.minutes.durationText)."
        }
        return InFlightCopy.clearToLanding(outlook: forecast.isGlobalOutlook) + "."
    }
}

/// Breathe: night sky, an orb that swells on a 4 s inhale and settles on a 6 s exhale, with an
/// optional Core Haptics pattern that follows the breath. Reduce Motion: the orb glows instead.
struct BreathingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(FlightStore.self) private var store
    @Environment(InFlight.self) private var inFlight
    @AppStorage("haptics.enabled") private var hapticsEnabled = true
    @State private var startedAt = Date.now
    /// Left with Done, rather than swiped away.
    @State private var finished = false

    static let inhale: TimeInterval = 4
    static let exhale: TimeInterval = 6
    private var cycle: TimeInterval { Self.inhale + Self.exhale }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let (inhaling, progress, remaining) = phase(at: context.date)
            OpenLayout {
                VStack(spacing: 28) {
                    controls
                    headsUp(at: context.date)
                    Spacer()
                    breath(inhaling: inhaling, progress: progress, remaining: remaining)
                    Spacer()
                    reminder()
                }
                .padding(28)
            } open: {
                panes(at: context.date, inhaling: inhaling, progress: progress, remaining: remaining)
            }
        }
        .skyBackground(.night)
        .onAppear {
            startedAt = .now
            if hapticsEnabled { Haptics.shared.startBreathing(inhale: Self.inhale, exhale: Self.exhale) }
            Analytics.log(.breathingStarted, ["where": Router.shared.breathingFrom, "haptics": hapticsEnabled])
            Router.shared.breathingFrom = "calm"
        }
        .onChange(of: hapticsEnabled) { _, on in
            on ? Haptics.shared.startBreathing(inhale: Self.inhale, exhale: Self.exhale) : Haptics.shared.stop()
            Analytics.log(.hapticsSet, ["on": on, "where": "breathing"])
        }
        .onDisappear {
            Haptics.shared.stop()
            Analytics.log(.breathingFinished, ["seconds": Int(Date.now.timeIntervalSince(startedAt)), "done": finished])
        }
    }

    /// Side by side (the open Duo): the same pieces, the orb in one pane and the heads-up and the
    /// reminder in the other.
    private func panes(at date: Date, inhaling: Bool, progress: Double, remaining: Double) -> some View {
        VStack(spacing: 0) {
            controls
            Panes(alignment: .center) {
                breath(inhaling: inhaling, progress: progress, remaining: remaining)
                    .frame(maxWidth: .infinity)
            } trailing: {
                VStack(alignment: .leading, spacing: 22) {
                    headsUp(at: date, alignment: .leading)
                    reminder(alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 22)
    }

    // MARK: The breathing screen's pieces, shared by the iPhone and Duo layouts

    private var controls: some View {
        HStack {
            Toggle(isOn: $hapticsEnabled) {
                Label("Haptics", systemImage: "hand.tap")
            }
            .toggleStyle(.button)
            .disabled(!Haptics.isSupported)
            Spacer()
            Button("Done") {
                finished = true
                dismiss()
            }
                .buttonStyle(.bordered)
        }
    }

    /// Where the flight's bumps are, while one is in the air. The colour goes on after the
    /// alignment, as a view style rather than the text's own: on the night sky that keeps its
    /// lighter, vibrant secondary.
    @ViewBuilder
    private func headsUp(at date: Date, alignment: TextAlignment = .center) -> some View {
        if let next = NextStretch.current(store: store, inFlight: inFlight, now: date) {
            Text(next.headsUp(now: date))
                .font(.bcHeadline)
                .multilineTextAlignment(alignment)
                .foregroundStyle(.secondary)
        }
    }

    /// The orb with the count.
    private func breath(inhaling: Bool, progress: Double, remaining: Double) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.accent.opacity(0.7), Theme.accent.opacity(0.1)], center: .center, startRadius: 10, endRadius: 170))
                .frame(width: 280, height: 280)
                .scaleEffect(reduceMotion ? 1 : orbScale(inhaling: inhaling, progress: progress))
                .opacity(reduceMotion ? 0.45 + 0.55 * glow(inhaling: inhaling, progress: progress) : 1)
            VStack(spacing: 8) {
                Text(inhaling ? "Breathe in" : "Breathe out").font(.bcTitle)
                Text("\(Int(remaining.rounded(.up)))").font(.bcBigFigure)
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func reminder(alignment: TextAlignment = .center) -> some View {
        Text("Unclench your hands and let your shoulders drop. The seatbelt is doing the work.")
            .font(.bcSubheadline)
            .multilineTextAlignment(alignment)
            .foregroundStyle(.secondary)
    }

    private func phase(at date: Date) -> (inhaling: Bool, progress: Double, remaining: Double) {
        let t = date.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: cycle)
        if t < Self.inhale { return (true, t / Self.inhale, Self.inhale - t) }
        let out = t - Self.inhale
        return (false, out / Self.exhale, Self.exhale - out)
    }

    /// 0.8 → 1.08 on the inhale, back on the exhale, eased.
    private func orbScale(inhaling: Bool, progress: Double) -> Double {
        0.8 + 0.28 * glow(inhaling: inhaling, progress: progress)
    }

    private func glow(inhaling: Bool, progress: Double) -> Double {
        let eased = 0.5 - 0.5 * cos(progress * .pi)
        return inhaling ? eased : 1 - eased
    }
}
