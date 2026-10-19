import SwiftUI

/// The Learn library ("Field Guide"): short, factual explainers, bundled so they work offline.
struct LearnView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.learnPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("Why it gets bumpy", Explainer.causes)
                    group("Good to know", Explainer.basics)
                }
                .padding()
            }
            .skyBackground(Sky(date: .now))
            .navigationTitle("Learn")
            .navigationDestination(for: Explainer.self) { ExplainerView(explainer: $0) }
        }
    }

    private func group(_ title: String, _ items: [Explainer]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).eyebrow().foregroundStyle(.secondary)
            ForEach(items) { explainer in
                NavigationLink(value: explainer) {
                    HStack(spacing: 14) {
                        // The diagram moves above the text at accessibility sizes.
                        AdaptiveStack {
                            ExplainerDiagram(kind: explainer.diagram)
                                .frame(width: 56, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(explainer.title).font(.bcHeadline)
                                Text(explainer.subtitle).font(.bcSubheadline).foregroundStyle(.secondary)
                            }
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

struct ExplainerView: View {
    let explainer: Explainer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ExplainerDiagram(kind: explainer.diagram)
                    .frame(height: 140)
                    .skyCard()
                    .accessibilityHidden(true)
                Text(explainer.title).font(.bcDisplay).displayTypeLimit()
                section("What's happening", explainer.happening)
                section("What the crew is doing", explainer.crew)
                section("What you'll feel", explainer.feel)
                if explainer.offersLightChopFeel {
                    LightChopPreview()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Good to know", systemImage: "hand.thumbsup").font(.bcCardTitle).foregroundStyle(Theme.accent)
                    Text(explainer.goodToKnow)
                }
                .skyCard()
                if !explainer.related.isEmpty {
                    Text("More turbulence types").font(.bcCardTitle)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(explainer.related) { other in
                                NavigationLink(other.title) { ExplainerView(explainer: other) }
                                    .buttonStyle(.bordered)
                                    .tint(Theme.accent)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .skyBackground(Sky(date: .now))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.bcCardTitle)
            Text(text)
        }
    }
}

/// Opt-in: a gentle haptic of what light chop feels like. Never offered for moderate or strong.
private struct LightChopPreview: View {
    @AppStorage("haptics.enabled") private var hapticsEnabled = true

    var body: some View {
        if hapticsEnabled && Haptics.isSupported {
            Button {
                Haptics.shared.playLightChop()
            } label: {
                Label("What will light chop feel like?", systemImage: "hand.tap")
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
    }
}

/// Simple calm diagrams: a plane in air of different kinds.
struct ExplainerDiagram: View {
    let kind: Explainer.Diagram

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let line = Theme.accent
            func wave(y: CGFloat, amplitude: CGFloat, waves: CGFloat) -> Path {
                var p = Path()
                for i in 0...40 {
                    let x = w * CGFloat(i) / 40
                    let point = CGPoint(x: x, y: y + sin(CGFloat(i) / 40 * .pi * 2 * waves) * amplitude)
                    i == 0 ? p.move(to: point) : p.addLine(to: point)
                }
                return p
            }
            switch kind {
            case .jetStream:
                for (i, y) in [0.3, 0.5, 0.7].enumerated() {
                    context.stroke(
                        wave(y: h * y, amplitude: h * 0.04 * CGFloat(i + 1), waves: 2 + CGFloat(i)),
                        with: .color(line.opacity(0.35 + 0.2 * Double(i))), lineWidth: 2)
                }
            case .mountain:
                var ridge = Path()
                ridge.move(to: CGPoint(x: 0, y: h))
                ridge.addLine(to: CGPoint(x: w * 0.3, y: h * 0.55))
                ridge.addLine(to: CGPoint(x: w * 0.45, y: h * 0.75))
                ridge.addLine(to: CGPoint(x: w * 0.6, y: h * 0.5))
                ridge.addLine(to: CGPoint(x: w, y: h))
                context.fill(ridge, with: .color(Theme.secondaryInk.opacity(0.3)))
                context.stroke(wave(y: h * 0.3, amplitude: h * 0.08, waves: 2), with: .color(line), lineWidth: 2)
            case .clouds:
                for (x, y, r) in [(0.3, 0.55, 0.22), (0.5, 0.45, 0.28), (0.7, 0.55, 0.2)] {
                    context.fill(
                        Path(ellipseIn: CGRect(x: w * x - h * r, y: h * y - h * r, width: h * r * 2, height: h * r * 2)),
                        with: .color(Theme.secondaryInk.opacity(0.25)))
                }
                context.stroke(wave(y: h * 0.25, amplitude: h * 0.05, waves: 3), with: .color(line), lineWidth: 2)
            case .lowLevel:
                context.fill(Path(CGRect(x: 0, y: h * 0.85, width: w, height: h * 0.15)), with: .color(Theme.secondaryInk.opacity(0.3)))
                context.stroke(wave(y: h * 0.6, amplitude: h * 0.05, waves: 4), with: .color(line), lineWidth: 2)
            case .calm:
                context.stroke(wave(y: h * 0.55, amplitude: 0, waves: 1), with: .color(line), lineWidth: 2)
            }
            // The plane, small, flying through.
            if let plane = context.resolveSymbol(id: 0) {
                context.draw(plane, at: CGPoint(x: w * 0.5, y: h * 0.4))
            }
        } symbols: {
            Image(systemName: "airplane").font(.bcCaptionStrong).foregroundStyle(Theme.ink).tag(0)
        }
    }
}

/// Short, factual explainers. Calm and accurate, no false reassurance, no data-source names.
struct Explainer: Identifiable, Hashable {
    enum Diagram: Hashable { case jetStream, mountain, clouds, lowLevel, calm }

    let id: String
    let title: String
    let subtitle: String
    let diagram: Diagram
    let happening: String
    let crew: String
    let feel: String
    let goodToKnow: String
    var relatedIDs: [String] = []
    var offersLightChopFeel = false

    var related: [Explainer] { relatedIDs.compactMap(Explainer.byID) }

    static func byID(_ id: String) -> Explainer? { (causes + basics).first { $0.id == id } }

    /// Generic explainer for a stretch, by phase of flight (the worker doesn't output causes yet).
    static func forStretch(_ segment: Forecast.Segment) -> Explainer {
        segment.phase == "cruise" ? byID("clear-air")! : byID("low-level")!
    }

    static let causes: [Explainer] = [
        Explainer(
            id: "clear-air", title: "Clear-air turbulence", subtitle: "Bumps at cruise, often in clear skies",
            diagram: .jetStream,
            happening: "High up, fast rivers of wind (the jet stream) flow next to slower air. Where they meet, the air tumbles a little, like water where a fast stream meets a still pool.",
            crew: "Pilots get forecasts and reports from planes ahead, and often climb or descend a few thousand feet to find smoother air. They turn on the seatbelt sign before it starts.",
            feel: "Usually light chop: a gentle, rhythmic rocking. Your drink ripples.",
            goodToKnow: "This is the most common kind of bump at cruise, and the plane is built for far more than it can produce.",
            relatedIDs: ["mountain-wave", "clouds", "low-level"], offersLightChopFeel: true),
        Explainer(
            id: "mountain-wave", title: "Mountain waves", subtitle: "Wind rolling over high ground",
            diagram: .mountain,
            happening: "Strong wind blowing across mountains makes waves in the air, much like water flowing over rocks in a stream. They can reach cruising height.",
            crew: "Crews know where mountain waves are likely and plan altitudes around them. They slow to a calmer speed if needed.",
            feel: "A slow rise and fall, sometimes with light chop.",
            goodToKnow: "The bumps follow the terrain, so they usually pass once you're beyond the mountains.",
            relatedIDs: ["clear-air", "low-level"]),
        Explainer(
            id: "clouds", title: "Around clouds", subtitle: "Rising air near big clouds",
            diagram: .clouds,
            happening: "Warm air rising inside and around big clouds stirs the air nearby.",
            crew: "Pilots see storms on radar and fly around them, often by many miles. That's why your route might curve.",
            feel: "Short bumps as you pass through puffy clouds; usually brief.",
            goodToKnow: "Avoiding storms is routine; air traffic control expects planes to route around them.",
            relatedIDs: ["clear-air", "low-level"]),
        Explainer(
            id: "low-level", title: "Near the ground", subtitle: "Climbing and descending",
            diagram: .lowLevel,
            happening: "Close to the ground, wind flows over buildings, hills and warm patches of land, so the lowest few thousand feet are often a bit bumpy.",
            crew: "Takeoff and landing are planned with wind in mind. Pilots keep the seatbelt sign on until the air settles.",
            feel: "Small bumps during the climb or the final descent, which ease as you go higher or touch down.",
            goodToKnow: "This is normal on many flights and usually lasts only a few minutes.",
            relatedIDs: ["clear-air", "clouds"]),
    ]

    static let basics: [Explainer] = [
        Explainer(
            id: "built", title: "Planes are built for it", subtitle: "Why turbulence is a comfort issue",
            diagram: .calm,
            happening: "Airliners are designed and tested to handle forces well beyond anything turbulence produces in normal flight. Wings flex on purpose; that's why you may see them move.",
            crew: "In bumps, pilots slow to a speed that gives the aircraft extra margin and keep flying normally.",
            feel: "Movement can feel big, but most drops are a change in height of only a few metres.",
            goodToKnow: "Turbulence is a comfort issue, not a structural one."),
        Explainer(
            id: "seatbelt", title: "Why the seatbelt matters", subtitle: "The one thing that keeps you safe",
            diagram: .calm,
            happening: "Almost all turbulence injuries happen to people who aren't buckled in, usually while standing or walking.",
            crew: "When flight attendants sit down, it's routine caution, not an emergency.",
            feel: "With your belt on, even strong bumps are just uncomfortable.",
            goodToKnow: "Keep it loosely fastened whenever you're seated, even with the sign off."),
        Explainer(
            id: "levels", title: "Light, moderate, strong", subtitle: "What each one feels like",
            diagram: .jetStream,
            happening: "Light chop is small rhythmic bumps. Moderate is noticeable jolts. Strong is hard jolts that push you against your belt.",
            crew: "Pilots work to avoid moderate and strong bumps, changing altitude or route when they can.",
            feel: "Light: your drink ripples. Moderate: walking is tricky and drinks can spill. Strong: rare, and your belt keeps you safe.",
            goodToKnow: "Most flights see light chop at most.", offersLightChopFeel: true),
        Explainer(
            id: "forecast", title: "How BumpCast forecasts", subtitle: "Advance, then confirmed",
            diagram: .calm,
            happening: "Up to two days before your flight, you get an advance forecast. It can still change. About 18 hours before departure it's confirmed with a more detailed forecast along your likely route and altitude, then updated every hour until you fly.",
            crew: "Your crew has their own forecasts and live reports, and adjusts on the day.",
            feel: "We assume a direct route and a typical climb, cruise and descent, so treat it as a guide, not a guarantee.",
            goodToKnow: "We'll notify you when your forecast is confirmed and if anything changes."),
    ]
}
