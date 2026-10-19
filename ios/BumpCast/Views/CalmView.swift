import SwiftUI

/// The Calm tab: breathing, timed to the flight when one is in progress.
struct CalmView: View {
    @Environment(Router.self) private var router
    @Environment(FlightStore.self) private var store
    @Environment(InFlight.self) private var inFlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var breathing = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // Scrolls at large text sizes; otherwise fills the screen, with the orb sized to
                // the screen so tall phones don't end up with empty bands above and below.
                ScrollView {
                    VStack(spacing: 20) {
                        // Its own header: the system title can't follow the night sky's light ink.
                        Text("Calm")
                            .font(.bcDisplay)
                            .displayTypeLimit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        // Smaller at accessibility text sizes, so the button stays near the top.
                        orb(diameter: min(geo.size.width * 0.5, geo.size.height * 0.24)
                            * (typeSize.isAccessibilitySize ? 0.5 : 1))
                        Text("Breathe through the bumps")
                            .font(.bcDisplay)
                            .displayTypeLimit()
                            .multilineTextAlignment(.center)
                        Text(subtitle).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button {
                            router.showBreathing = true
                        } label: {
                            Label("Start breathing", systemImage: "wind").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
                        .tint(Theme.accent)
                        .controlSize(.large)
                        Spacer(minLength: 16)
                        readingCards
                    }
                    .padding(24)
                    .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .skyBackground(.night)
            .toolbar(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    /// The same orb as the breathing screen, breathing slowly here too (a glow with Reduce Motion).
    private func orb(diameter: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: Theme.orb,
                center: UnitPoint(x: 0.38, y: 0.32), startRadius: 0, endRadius: diameter * 0.6))
            .frame(width: diameter, height: diameter)
            .shadow(color: Theme.orbGlow.opacity(0.35), radius: diameter * 0.2)
            .scaleEffect(reduceMotion ? 1 : (breathing ? 1 : 0.88))
            .opacity(reduceMotion ? (breathing ? 1 : 0.7) : 1)
            .animation(.easeInOut(duration: 5).repeatForever(autoreverses: true), value: breathing)
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

    private var subtitle: String {
        if let next = NextStretch.current(store: store, inFlight: inFlight) {
            return next.headsUp(now: .now)
        }
        return "Breathe in for 4, out for 6. A longer out-breath steadies your body when the plane moves."
    }
}

/// The next bumpy stretch of the flight in progress, for heads-ups.
struct NextStretch {
    let severity: Severity
    let start: Date
    let end: Date

    @MainActor
    static func current(store: FlightStore, inFlight: InFlight, now: Date = .now) -> NextStretch? {
        for flight in store.flights {
            guard let forecast = store.forecasts[flight.id], forecast.isShown, inFlight.isFlying(flight, forecast: forecast, now: now)
            else { continue }
            let takeoff = inFlight.effectiveTakeoff(of: flight)
            let minute = Int(now.timeIntervalSince(takeoff) / 60)
            guard let segment = forecast.segments.first(where: { $0.endMin >= minute }) else { return nil }
            return NextStretch(
                severity: segment.severity,
                start: takeoff.addingTimeInterval(TimeInterval(segment.startMin * 60)),
                end: takeoff.addingTimeInterval(TimeInterval((segment.endMin + 1) * 60)))
        }
        return nil
    }

    func headsUp(now: Date) -> String {
        if now >= end { return "That stretch has passed. Smooth air now." }
        if now >= start { return "\(severity.title) now, about \(Int(end.timeIntervalSince(now) / 60) + 1) min to go." }
        return "\(severity.title) in about \(Int(start.timeIntervalSince(now) / 60) + 1) min."
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

    static let inhale: TimeInterval = 4
    static let exhale: TimeInterval = 6
    private var cycle: TimeInterval { Self.inhale + Self.exhale }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let (inhaling, progress, remaining) = phase(at: context.date)
            VStack(spacing: 28) {
                HStack {
                    Toggle(isOn: $hapticsEnabled) {
                        Label("Haptics", systemImage: "hand.tap")
                    }
                    .toggleStyle(.button)
                    .disabled(!Haptics.isSupported)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.bordered)
                }
                if let next = NextStretch.current(store: store, inFlight: inFlight, now: context.date) {
                    Text(next.headsUp(now: context.date))
                        .font(.bcHeadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
                Spacer()
                Text("Unclench your hands and let your shoulders drop. The seatbelt is doing the work.")
                    .font(.bcSubheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .skyBackground(.night)
        .onAppear {
            startedAt = .now
            if hapticsEnabled { Haptics.shared.startBreathing(inhale: Self.inhale, exhale: Self.exhale) }
        }
        .onChange(of: hapticsEnabled) { _, on in
            on ? Haptics.shared.startBreathing(inhale: Self.inhale, exhale: Self.exhale) : Haptics.shared.stop()
        }
        .onDisappear { Haptics.shared.stop() }
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
