import SwiftUI

struct CalmView: View {
    @Environment(Router.self) private var router
    @Environment(FlightStore.self) private var store
    @Environment(InFlight.self) private var inFlight

    var body: some View {
        @Bindable var router = router
        NavigationStack {
            List {
                Section {
                    Button {
                        router.showBreathing = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "wind").font(.title2).foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Breathe through the bumps").font(.headline)
                                Text(breathingSubtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .tint(.primary)
                }
                Section("Why turbulence is safe") {
                    ForEach(Explainer.all) { explainer in
                        NavigationLink(explainer.title) { ExplainerView(explainer: explainer) }
                    }
                }
            }
            .navigationTitle("Calm")
            .fullScreenCover(isPresented: $router.showBreathing) {
                BreathingView(nextStretch: nextStretch)
            }
        }
    }

    private var activeFlight: (Flight, Forecast)? {
        for flight in store.flights {
            if let forecast = store.forecasts[flight.id], inFlight.isFlying(flight, forecast: forecast) {
                return (flight, forecast)
            }
        }
        return nil
    }

    /// When the next bumpy stretch starts (or the current one ends), while flying.
    private var nextStretch: BreathingView.Stretch? {
        guard let (flight, forecast) = activeFlight else { return nil }
        let takeoff = inFlight.effectiveTakeoff(of: flight)
        let minute = Int(Date.now.timeIntervalSince(takeoff) / 60)
        guard let segment = forecast.segments.first(where: { $0.endMin >= minute }) else { return nil }
        return .init(
            severity: segment.severity,
            start: takeoff.addingTimeInterval(TimeInterval(segment.startMin * 60)),
            end: takeoff.addingTimeInterval(TimeInterval((segment.endMin + 1) * 60)))
    }

    private var breathingSubtitle: String {
        if let next = nextStretch {
            return next.start <= .now ? "\(next.severity.title) now. Breathe along until it passes." :
                "\(next.severity.title) in \(Int(next.start.timeIntervalSinceNow / 60) + 1) min. Start a little before."
        }
        return "A slow 4-4-6 breath. Steadies your body when the plane moves."
    }
}

/// Paced breathing: in for 4, hold for 4, out for 6. A longer out-breath calms the body.
struct BreathingView: View {
    struct Stretch {
        let severity: Severity
        let start: Date
        let end: Date
    }

    let nextStretch: Stretch?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date.now

    private let phases: [(name: String, seconds: Double, scale: Double)] = [
        ("Breathe in", 4, 1.0), ("Hold", 4, 1.0), ("Breathe out", 6, 0.45),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            let (phase, remaining) = phase(at: context.date)
            VStack(spacing: 32) {
                if let nextStretch {
                    Text(stretchText(nextStretch, now: context.date))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ZStack {
                    Circle()
                        .fill(.teal.opacity(0.25))
                        .frame(width: 280, height: 280)
                        .scaleEffect(reduceMotion ? 1 : circleScale(at: context.date))
                    VStack(spacing: 8) {
                        Text(phase.name).font(.title.bold())
                        Text("\(Int(remaining.rounded(.up)))").font(.largeTitle.monospacedDigit())
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Text("Unclench your hands and let your shoulders drop. The seatbelt is doing the work.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(32)
        }
        .onAppear { startedAt = .now }
    }

    private var cycle: Double { phases.map(\.seconds).reduce(0, +) }

    private func phase(at date: Date) -> (phase: (name: String, seconds: Double, scale: Double), remaining: Double) {
        var t = date.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: cycle)
        for phase in phases {
            if t < phase.seconds { return (phase, phase.seconds - t) }
            t -= phase.seconds
        }
        return (phases[0], phases[0].seconds)
    }

    /// Grows while breathing in, holds, shrinks while breathing out.
    private func circleScale(at date: Date) -> Double {
        let (phase, remaining) = phase(at: date)
        let progress = 1 - remaining / phase.seconds
        switch phase.name {
        case "Breathe in": return 0.45 + 0.55 * progress
        case "Hold": return 1
        default: return 1 - 0.55 * progress
        }
    }

    private func stretchText(_ stretch: Stretch, now: Date) -> String {
        if now >= stretch.end { return "That stretch has passed. Smooth air now." }
        if now >= stretch.start {
            return "\(stretch.severity.title) now, about \(Int(stretch.end.timeIntervalSince(now) / 60) + 1) min to go."
        }
        return "\(stretch.severity.title) in about \(Int(stretch.start.timeIntervalSince(now) / 60) + 1) min."
    }
}

struct ExplainerView: View {
    let explainer: Explainer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(explainer.title).font(.largeTitle.bold())
                ForEach(explainer.paragraphs, id: \.self) { Text($0) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Short, factual explainers. Calm and accurate, no false reassurance.
struct Explainer: Identifiable, Hashable {
    let id: String
    let title: String
    let paragraphs: [String]

    static let all: [Explainer] = [
        Explainer(
            id: "what",
            title: "What turbulence actually is",
            paragraphs: [
                "Turbulence is uneven air: the plane passes through pockets moving at slightly different speeds or directions, like a boat crossing small waves.",
                "Most of it comes from wind shear near the jet stream (clear-air turbulence), air flowing over mountains, or rising air in and around clouds and storms.",
                "It feels dramatic because your body is sensitive to small changes. A bump that feels like a drop is usually a change in height of a few metres.",
            ]),
        Explainer(
            id: "built",
            title: "Planes are built for it",
            paragraphs: [
                "Airliners are designed and tested to handle forces well beyond anything turbulence produces in normal flight. Wings are made to flex; that's why you may see them move.",
                "Turbulence is a comfort issue, not a structural one. Pilots slow down to a 'turbulence penetration speed' that gives the aircraft extra margin.",
            ]),
        Explainer(
            id: "crew",
            title: "What the crew is doing",
            paragraphs: [
                "Pilots get turbulence forecasts and live reports from other aircraft before and during the flight.",
                "They change altitude or route to find smoother air when they can, and turn on the seatbelt sign early. When flight attendants sit down, it's routine caution, not an emergency.",
            ]),
        Explainer(
            id: "seatbelt",
            title: "Why the seatbelt matters",
            paragraphs: [
                "Almost all turbulence injuries happen to people who aren't buckled in, usually crew or passengers standing or walking.",
                "Keeping your belt loosely fastened whenever you're seated is the single most effective thing you can do. With it on, even strong bumps are just uncomfortable.",
            ]),
        Explainer(
            id: "levels",
            title: "Light, moderate, strong: what they feel like",
            paragraphs: [
                "Light chop: rhythmic small bumps. Your drink ripples. Very common on most flights.",
                "Moderate: noticeable jolts. Walking is tricky and drinks can spill. Uncomfortable, still routine for the crew.",
                "Strong (severe): hard jolts that can push you against your belt. Rare; pilots work hard to avoid it, and your seatbelt keeps you safe.",
            ]),
        Explainer(
            id: "forecast",
            title: "How BumpCast forecasts",
            paragraphs: [
                "Up to two days before your flight, you get an advance forecast. It's labelled as advance because it can still change.",
                "About 18 hours before departure, it's confirmed with a more detailed forecast along your likely route and altitude, then updated every hour until you fly. We'll notify you when anything changes.",
                "We assume a direct route and a typical climb, cruise and descent. Your real routing and altitude may differ, and forecasts can miss storm-related bumps, so treat it as a guide, not a guarantee.",
            ]),
    ]
}
