import SwiftUI

/// The Calm tab: breathing, timed to the flight when one is in progress.
struct CalmView: View {
    @Environment(Router.self) private var router
    @Environment(FlightStore.self) private var store
    @Environment(InFlight.self) private var inFlight

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                WaterGlass(severity: .smooth, size: 64)
                Text("Breathe through the bumps").font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text(subtitle).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button {
                    router.showBreathing = true
                } label: {
                    Label("Start breathing", systemImage: "wind").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                Spacer()
            }
            .padding(24)
            .background { SkyBackground(sky: .night) }
            .onSky(.night)
            .navigationTitle("Calm")
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
            guard let forecast = store.forecasts[flight.id], inFlight.isFlying(flight, forecast: forecast, now: now) else { continue }
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
                        .font(.headline)
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
                        Text(inhaling ? "Breathe in" : "Breathe out").font(.title.bold())
                        Text("\(Int(remaining.rounded(.up)))").font(.largeTitle.monospacedDigit())
                            .contentTransition(.numericText(countsDown: true))
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Text("Unclench your hands and let your shoulders drop. The seatbelt is doing the work.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .background { SkyBackground(sky: .night) }
        .onSky(.night)
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
