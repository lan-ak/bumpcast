import SwiftUI

/// The Learn library ("Field Guide"): short, factual explainers, bundled so they work offline.
struct LearnView: View {
    @Environment(Router.self) private var router
    /// With list and explainer side by side (the open Duo): the explainer shown.
    @State private var selected = Explainer.causes[0]

    /// Tests render the open layout's panes without the navigation stack (which can't be rendered).
    private let contentOnly: Bool

    init(contentOnly: Bool = false) {
        self.contentOnly = contentOnly
    }

    var body: some View {
        if contentOnly {
            panes.skyBackground(Sky(date: .now))
        } else {
            screen
        }
    }

    private var screen: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.learnPath) {
            OpenLayout {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        group("Why it gets bumpy", Explainer.causes)
                        group("Good to know", Explainer.basics)
                    }
                    .padding()
                }
            } open: {
                panes
            }
            .skyBackground(Sky(date: .now))
            .navigationTitle("Learn")
            .navigationDestination(for: Explainer.self) { ExplainerView(explainer: $0) }
        }
    }

    /// Side by side (the open Duo): the list and the explainer picked, each scrolling on its own.
    /// Its own header, as Calm has, so the explainer starts at the top too. An explainer opened
    /// from elsewhere (Calm's reading cards) is picked instead of pushed.
    private var panes: some View {
        Panes(fillsHeight: true) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Learn")
                        .font(.bcDisplay)
                        .displayTypeLimit()
                        .accessibilityAddTraits(.isHeader)
                    group("Why it gets bumpy", Explainer.causes) { selected = $0 }
                    group("Good to know", Explainer.basics) { selected = $0 }
                }
                .padding(.vertical)
            }
        } trailing: {
            ExplainerView(explainer: selected, select: { selected = $0 })
                .id(selected)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: selected) { _, picked in ExplainerView.logOpened(picked, from: nil) }
        .onChange(of: router.learnPath, initial: true) { _, path in
            guard let last = path.last else { return }
            selected = last
            router.learnPath = []
        }
    }

    /// The rows push the explainer, or with `pick` (side by side) show it beside the list.
    private func group(_ title: String, _ items: [Explainer], pick: ((Explainer) -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).eyebrow().foregroundStyle(.secondary)
            ForEach(items) { explainer in
                if let pick {
                    Button { pick(explainer) } label: { row(explainer, isSelected: explainer == selected) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(explainer == selected ? .isSelected : [])
                } else {
                    NavigationLink(value: explainer) { row(explainer) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    /// The picked row on the Duo spread is raised, with the accent hairline.
    private func row(_ explainer: Explainer, isSelected: Bool = false) -> some View {
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .skySurface(RoundedRectangle(cornerRadius: 18, style: .continuous), raised: isSelected)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1.5)
            }
        }
    }
}

struct ExplainerView: View {
    let explainer: Explainer
    /// On the Duo spread, beside the list: related types are picked there instead of pushed.
    var select: ((Explainer) -> Void)? = nil
    /// Where it was opened from, for `explainer_opened`; nil reads `Router.explainerFrom`.
    var from: String? = nil

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
                                Group {
                                    if let select {
                                        Button(other.title) { select(other) }
                                    } else {
                                        NavigationLink(other.title) { ExplainerView(explainer: other, from: "related") }
                                    }
                                }
                                    .buttonStyle(.bordered)
                                    .tint(Theme.accent)
                            }
                        }
                    }
                }
            }
            .padding(select == nil ? .all : [.vertical, .trailing])
        }
        // Beside the Learn list, the list's sky is already behind it.
        .modifier(SkyUnlessSpread(onSpread: select != nil))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Beside the list, the spread logs what's picked (one shows before anything is).
            guard select == nil else { return }
            ExplainerView.logOpened(explainer, from: from)
        }
    }

    static func logOpened(_ explainer: Explainer, from: String?) {
        Analytics.log(.explainerOpened, ["id": explainer.id, "where": from ?? Router.shared.explainerFrom])
        Router.shared.explainerFrom = "learn"
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
            case .gusty:
                // Muted ground, a low building, and soft wind lines flowing over them.
                context.fill(Path(CGRect(x: 0, y: h * 0.85, width: w, height: h * 0.15)), with: .color(Theme.secondaryInk.opacity(0.3)))
                context.fill(Path(CGRect(x: w * 0.72, y: h * 0.7, width: w * 0.08, height: h * 0.15)), with: .color(Theme.secondaryInk.opacity(0.25)))
                for (i, y) in [0.62, 0.74].enumerated() {
                    context.stroke(
                        wave(y: h * y, amplitude: h * 0.03, waves: 1.5 + Double(i) * 0.5),
                        with: .color(line.opacity(0.5 + 0.25 * Double(i))), lineWidth: 2)
                }
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
    enum Diagram: Hashable { case jetStream, mountain, clouds, lowLevel, gusty, calm }

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

    /// The explainer for a stretch: "Gusty at the airport" for a light one gusty wind explains,
    /// otherwise by phase of flight.
    static func forStretch(_ segment: Forecast.Segment) -> Explainer {
        if segment.gustyEnd != nil, segment.severity == .light { return byID("gusty-airport")! }
        return segment.phase == "cruise" ? byID("clear-air")! : byID("low-level")!
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
            relatedIDs: ["gusty-airport", "clear-air", "clouds"]),
        // No "What will light chop feel like?" here: on a gusty day there's now and then a firmer one.
        Explainer(
            id: "gusty-airport", title: "Gusty at the airport", subtitle: "Windy days near the ground",
            diagram: .gusty,
            happening: "On a windy day, the wind near the ground speeds up and slows down as it flows over buildings and land, a bit like a river over stones. You feel it for a few minutes as you climb out and on the way down.",
            crew: "Pilots plan every takeoff and landing around the wind. In gusty air they fly the approach a little faster for extra control, and keep the seatbelt sign on until the air settles.",
            feel: "Bumps and some side-to-side sway, now and then a firmer one, that ease as you climb or once you touch down.",
            goodToKnow: "Gusty takeoffs and landings happen every day at busy airports. Some airports don't have a wind forecast, or not until a few hours before. Your forecast still covers the climb and descent either way.",
            relatedIDs: ["low-level", "clear-air", "built"]),
    ]

    static let basics: [Explainer] = [
        Explainer(
            id: "built", title: "Planes are built for it", subtitle: "Why turbulence is a comfort issue",
            diagram: .calm,
            happening: "Airliners are designed and tested to handle forces well beyond anything turbulence produces in normal flight. Wings flex on purpose; that's why you may see them move.",
            crew: "In bumps, pilots slow to a speed that gives the aircraft extra margin and keep flying normally.",
            feel: "Movement can feel big, but most drops are a change in height of only a few meters.",
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

/// The explainer's own sky, except on the Duo spread, where it sits on the Learn list's.
private struct SkyUnlessSpread: ViewModifier {
    let onSpread: Bool

    func body(content: Content) -> some View {
        if onSpread { content } else { content.skyBackground(Sky(date: .now)) }
    }
}
