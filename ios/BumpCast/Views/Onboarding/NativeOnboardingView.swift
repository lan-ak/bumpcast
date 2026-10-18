import SwiftUI

/// The onboarding flow, natively: used only when the Superwall flow can't load (offline at first
/// launch, a configuration error, no campaign). Same pages, copy and answer values as
/// `superwall/paywalls/onboarding`, minus the paywall, which needs Superwall to sell.
struct NativeOnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, feeling, reassure, how, help, frequency, source, notifications

        /// Where the "Calm line" sunrise sits behind the page.
        var scene: SceneMode {
            switch self {
            case .welcome: .hero
            case .feeling, .help, .frequency, .source: .fill
            case .reassure, .how, .notifications: .off
            }
        }
    }

    enum SceneMode { case hero, fill, off }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var step: Step = .welcome
    @State private var forward = true
    @State private var answers = Answers()

    struct Answers {
        var feeling: String?
        var help: [String] = []
        var frequency: String?
        var source: String?
    }

    var body: some View {
        ZStack(alignment: .top) {
            background
            page
                .id(step)
                .transition(pageTransition)
            chrome
        }
        .animation(Theme.motion(reduceMotion), value: step)
        .environment(\.colorScheme, isNight ? .dark : colorScheme)
        // Light status bar over the night sky.
        .preferredColorScheme(isNight ? .dark : nil)
    }

    // MARK: Background and chrome

    private var isNight: Bool { step == .notifications }
    private var palette: CalmLinePalette { isNight || colorScheme == .dark ? .dark : .light }

    private var background: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                LinearGradient(colors: palette.sky, startPoint: .top, endPoint: .bottom)
                if isNight {
                    SkyBackground(sky: .night)
                }
                sunrise(width: geo.size.width)
            }
            .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.8), value: isNight)
    }

    /// The icon's horizon across the screen: bump, sun and still water.
    private func sunrise(width: CGFloat) -> some View {
        let height: CGFloat = 420
        let offset: CGFloat = switch step.scene {
        case .hero: 0
        case .fill: 90
        case .off: height
        }
        let progress = CGFloat(step.rawValue) / CGFloat(Step.allCases.count - 1)
        return CalmLineScene(palette: palette, sunRise: step == .welcome ? 0.5 : 0.3 + progress * 0.6)
            .frame(width: width, height: height)
            .offset(y: offset)
            .opacity(step.scene == .off ? 0 : 1)
            .animation(.smooth(duration: 1), value: step)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var chrome: some View {
        if step != .welcome {
            HStack(spacing: 12) {
                Button {
                    go(to: Step(rawValue: step.rawValue - 1) ?? .welcome, forward: false)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(isNight ? 0.1 : 0.6), in: .circle)
                }
                .accessibilityLabel("Back")
                ProgressView(value: Double(step.rawValue), total: Double(Step.allCases.count - 1))
                    .tint(palette.line)
                Color.clear.frame(width: 44, height: 44)
            }
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading),
            removal: .move(edge: forward ? .leading : .trailing))
    }

    private func go(to next: Step, forward: Bool = true) {
        self.forward = forward
        step = next
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) { go(to: next) }
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: welcome
        case .feeling:
            question(
                "How do you feel about flying?", key: "fly_feeling",
                options: [
                    ("Calm, just curious", "calm"), ("A little uneasy", "a-little-uneasy"),
                    ("Nervous most flights", "nervous"), ("Very anxious", "very-anxious"),
                ],
                selected: answers.feeling
            ) { answers.feeling = $0 }
        case .reassure: reassure
        case .how: HowItWorksPage(onContinue: advance)
        case .help: help
        case .frequency:
            question(
                "How often do you fly?", key: "fly_frequency",
                options: [("Once a year or less", "yearly-or-less"), ("A few times a year", "few-a-year"), ("Monthly or more", "monthly-plus")],
                selected: answers.frequency
            ) { answers.frequency = $0 }
        case .source:
            question(
                "How did you hear about us?", key: "source", eyebrow: "Last one",
                options: [("App Store", "app-store"), ("TikTok or Instagram", "social"), ("A friend", "friend"), ("Somewhere else", "other")],
                selected: answers.source
            ) { answers.source = $0 }
        case .notifications: notifications
        }
    }

    private var welcome: some View {
        PageLayout(topPadding: 16) {
            HStack(spacing: 10) {
                CalmLineIcon(palette: .light)
                    .frame(width: 34, height: 34)
                    .clipShape(.rect(cornerRadius: 8, style: .continuous))
                Text("BumpCast").font(.bcTitle2)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Know what your flight will feel like.").font(.bcDisplay)
                Text("Turbulence forecasts in plain words, before you board and while you fly.")
                    .foregroundStyle(Theme.secondaryInk)
            }
            .padding(.top, 36)
        } footer: {
            PrimaryButton("Get started", action: advance)
        }
    }

    private func question(
        _ title: String, key: String, eyebrow: String? = nil, options: [(String, String)], selected: String?,
        choose: @escaping (String) -> Void
    ) -> some View {
        PageLayout {
            if let eyebrow { Text(eyebrow).eyebrow().foregroundStyle(Theme.brandLine) }
            Text(title).font(.bcTitle).padding(.bottom, 12)
            ForEach(options, id: \.1) { label, value in
                OptionRow(label: label, isSelected: selected == value) {
                    choose(value)
                    Paywalls.shared.setUserAttributes([key: value])
                    let from = step
                    Task {
                        try? await Task.sleep(for: .milliseconds(380))
                        if step == from { advance() }
                    }
                }
            }
        }
    }

    private var reassure: some View {
        let calm = answers.feeling == "calm"
        return PageLayout(centered: true) {
            VStack(alignment: .leading, spacing: 10) {
                Text(calm ? "Turbulence is weather. Weather can be forecast." : "You're not alone. Knowing what's coming helps.")
                    .font(.bcTitle)
                Text("BumpCast tells you when the bumps come, how long they last and what they'll feel like.")
                    .foregroundStyle(Theme.secondaryInk)
            }
            SampleForecastCard().padding(.top, 36)
        } footer: {
            PrimaryButton("Continue", action: advance)
        }
    }

    @State private var helpError = false

    private var help: some View {
        let options = [
            ("Knowing when it'll get bumpy", "when"), ("Knowing how long it'll last", "how-long"),
            ("Knowing it's normal", "normal"), ("Something to calm me down", "calm-down"),
        ]
        return PageLayout {
            Text("What would help most on your next flight?").font(.bcTitle)
            Text("Pick any that apply.").foregroundStyle(Theme.secondaryInk).padding(.bottom, 8)
            ForEach(options, id: \.1) { label, value in
                OptionRow(label: label, isSelected: answers.help.contains(value), multi: true) {
                    if let index = answers.help.firstIndex(of: value) {
                        answers.help.remove(at: index)
                    } else {
                        answers.help.append(value)
                    }
                    helpError = false
                }
            }
        } footer: {
            if helpError {
                Text("Pick at least one")
                    .font(.bcFootnoteStrong)
                    .foregroundStyle(Theme.color(.severe))
                    .frame(maxWidth: .infinity)
            }
            PrimaryButton("Continue") {
                guard !answers.help.isEmpty else {
                    helpError = true
                    return
                }
                Paywalls.shared.setUserAttributes([
                    "help_most": answers.help.joined(separator: ","), "help_most_count": answers.help.count,
                ])
                advance()
            }
            .opacity(answers.help.isEmpty ? 0.5 : 1)
        }
    }

    private var notifications: some View {
        PageLayout(centered: true) {
            HStack(spacing: 12) {
                CalmLineIcon(palette: .light)
                    .frame(width: 38, height: 38)
                    .clipShape(.rect(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("BumpCast").font(.bcSubheadlineStrong)
                        Spacer()
                        Text("now").font(.bcFootnote).foregroundStyle(Theme.secondaryInk)
                    }
                    Text("Your forecast is ready").font(.bcSubheadline)
                    Text("A few bumps, mostly calm.").font(.bcSubheadline).foregroundStyle(Theme.secondaryInk)
                }
            }
            .skyCard(cornerRadius: 22, padding: 14)
            VStack(alignment: .leading, spacing: 10) {
                Text("We'll tell you when your forecast is ready.").font(.bcTitle)
                Text("Overnight, we wait until morning unless you're flying soon.").foregroundStyle(Theme.secondaryInk)
            }
            .padding(.top, 40)
        } footer: {
            PrimaryButton("Turn on notifications") {
                Task {
                    let granted = await PushNotifications.shared.requestPermission()
                    Paywalls.shared.setUserAttributes(["notifications_prompt": granted ? "granted" : "denied"])
                    await Onboarding.shared.finishNative()
                }
            }
            Button("Not now") {
                Paywalls.shared.setUserAttributes(["notifications_prompt": "not-now"])
                Task { await Onboarding.shared.finishNative() }
            }
            .font(.bcBody)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

// MARK: - Building blocks

/// Content at the top (or centred), actions pinned at the bottom; scrolls at large text sizes.
private struct PageLayout<Content: View, Footer: View>: View {
    var topPadding: CGFloat = 64
    var centered = false
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, topPadding)
                    .padding(.horizontal, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .foregroundStyle(Theme.ink)
            .defaultScrollAnchor(centered ? .center : .top)
            VStack(spacing: 4) { footer }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        .font(.bcBody)
    }
}

extension PageLayout where Footer == EmptyView {
    init(topPadding: CGFloat = 64, centered: Bool = false, @ViewBuilder content: () -> Content) {
        self.topPadding = topPadding
        self.centered = centered
        self.content = content()
        self.footer = EmptyView()
    }
}

private struct OptionRow: View {
    let label: String
    let isSelected: Bool
    var multi = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var fill: Double {
        colorScheme == .dark ? (isSelected ? 0.16 : 0.08) : (isSelected ? 0.95 : 0.6)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if multi {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accent)
                }
                Text(label).font(.bcBody).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(.white.opacity(fill), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : .white.opacity(colorScheme == .dark ? 0.12 : 0.7), lineWidth: isSelected ? 2 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.bcHeadline)
                .foregroundStyle(colorScheme == .dark ? Color(hex: 0x0B1322) : .white)
                .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(Theme.accent)
    }
}

/// The sample forecast on the reassure page: a light-chop flight with its wave line.
private struct SampleForecastCard: View {
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your flight").eyebrow().foregroundStyle(Theme.brandLine)
                    Text("Takeoff → Landing").font(.bcTitle)
                }
                Spacer()
                WaterGlass(severity: .light, size: 44)
            }
            Text("A few bumps, mostly calm.").font(.bcTitle2)
            ZStack(alignment: .topLeading) {
                GeometryReader { geo in
                    let w = geo.size.width / 250
                    Rectangle().fill(Theme.color(.light).opacity(0.25))
                        .frame(width: 34 * w).offset(x: 62 * w)
                    Rectangle().fill(Theme.color(.light).opacity(0.25))
                        .frame(width: 22 * w).offset(x: 168 * w)
                    SampleWave()
                        .trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 48)
            HStack {
                Text("Takeoff")
                Spacer()
                Circle().fill(Theme.color(.light)).frame(width: 8, height: 8)
                Text("Light chop 6 min")
                Spacer()
                Text("Landing")
            }
            .font(.bcEyebrow)
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondaryInk)
            .lineLimit(1)
        }
        .skyCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample forecast: a few bumps, mostly calm, with 6 minutes of light chop.")
        .onAppear {
            if reduceMotion { drawn = true } else { withAnimation(.smooth(duration: 1.4).delay(0.4)) { drawn = true } }
        }
    }
}

private struct SampleWave: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 250, sy = rect.height / 44
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var path = Path()
        path.move(to: p(0, 40))
        path.addCurve(to: p(62, 35), control1: p(30, 40), control2: p(50, 36))
        path.addCurve(to: p(79, 18), control1: p(70, 33), control2: p(74, 18))
        path.addCurve(to: p(96, 34), control1: p(84, 18), control2: p(88, 33))
        path.addLine(to: p(168, 35))
        path.addCurve(to: p(179, 23), control1: p(172, 34), control2: p(175, 23))
        path.addCurve(to: p(190, 35), control1: p(183, 23), control2: p(186, 34))
        path.addCurve(to: p(250, 41), control1: p(215, 36), control2: p(235, 40))
        return path
    }
}

/// "Your forecast gets sharper as you get closer": one card stepping through the confidence
/// labels the app uses (Copy.swift), with the bars firming up as it's confirmed.
private struct HowItWorksPage: View {
    let onContinue: () -> Void
    @State private var stage = 0
    @State private var auto = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bars: [CGFloat] = [2, 3, 3, 4, 3, 9, 12, 10, 4, 3, 3, 2, 3, 3, 4, 3, 3, 8, 11, 4, 3, 3, 2, 2, 3, 2]
    private static let stages: [(when: String, badge: String, symbol: String, line: String, confirmed: Bool)] = [
        ("48 hours before", "Advance forecast", "binoculars", "An early look. It can still change.", false),
        ("The day before", "Confirmed forecast", "checkmark.seal.fill", "Confirmed for your route and altitude.", true),
        ("Until takeoff", "Updated hourly", "arrow.clockwise", "Kept fresh every hour until you fly.", true),
    ]

    var body: some View {
        let current = Self.stages[stage]
        PageLayout(centered: true) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your forecast gets sharper as you get closer.").font(.bcTitle)
                Text("The first one arrives 48 hours before you fly.").foregroundStyle(Theme.secondaryInk)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(current.when).eyebrow().foregroundStyle(Theme.brandLine)
                    Spacer()
                    Label(current.badge, systemImage: current.symbol)
                        .font(.bcCaptionStrong)
                        .foregroundStyle(current.confirmed ? Theme.accent : Theme.secondaryInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.background.opacity(0.7), in: .capsule)
                        .contentTransition(.symbolEffect(.replace))
                }
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Self.bars.indices, id: \.self) { i in
                        let b = Self.bars[i]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.color(b > 7 ? .light : .smooth))
                            .frame(height: (current.confirmed ? b : max(3, b * 0.75)) / 12 * 106)
                            .opacity(current.confirmed ? 1 : 0.4)
                    }
                }
                .frame(height: 110, alignment: .bottom)
                .accessibilityHidden(true)
                Text(current.line).font(.bcHeadline)
            }
            .skyCard(padding: 20)
            .padding(.top, 36)
            HStack(spacing: 0) {
                ForEach(Self.stages.indices, id: \.self) { i in
                    Button {
                        auto = false
                        stage = i
                    } label: {
                        Capsule()
                            .fill(i == stage ? Theme.accent : Theme.secondaryInk.opacity(0.25))
                            .frame(width: i == stage ? 22 : 8, height: 8)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Self.stages[i].when)
                }
            }
            .frame(maxWidth: .infinity)
            .sensoryFeedback(.selection, trigger: stage)
        } footer: {
            Text("With Pro, we update you each time it gets more accurate.")
                .font(.bcFootnote)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)
            PrimaryButton("Continue", action: onContinue)
        }
        .animation(reduceMotion ? Theme.fade : .smooth(duration: 0.7), value: stage)
        .task(id: auto) {
            while auto, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.6))
                if auto { stage = (stage + 1) % Self.stages.count }
            }
        }
    }
}

/// The icon's horizon stretched across the screen, for the onboarding background.
private struct CalmLineScene: View {
    let palette: CalmLinePalette
    /// 0 → 1: how far the sun has risen above the horizon.
    var sunRise: CGFloat

    var body: some View {
        GeometryReader { geo in
            let horizon: CGFloat = 150
            let sunX = geo.size.width * 0.64
            ZStack(alignment: .topLeading) {
                Circle()
                    .fill(palette.sun)
                    .frame(width: 108, height: 108)
                    .position(x: sunX, y: horizon + 54 - sunRise * 80)
                LinearGradient(colors: palette.water, startPoint: .top, endPoint: .bottom)
                    .frame(height: geo.size.height - horizon)
                    .offset(y: horizon)
                Path { path in
                    path.move(to: CGPoint(x: sunX - 29, y: horizon + 29))
                    path.addLine(to: CGPoint(x: sunX + 29, y: horizon + 29))
                    path.move(to: CGPoint(x: sunX - 14, y: horizon + 47))
                    path.addLine(to: CGPoint(x: sunX + 14, y: horizon + 47))
                }
                .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Path { path in
                    path.move(to: CGPoint(x: 50, y: horizon))
                    path.addCurve(to: CGPoint(x: 118, y: horizon - 36), control1: CGPoint(x: 80, y: horizon), control2: CGPoint(x: 92, y: horizon - 36))
                    path.addCurve(to: CGPoint(x: 186, y: horizon), control1: CGPoint(x: 144, y: horizon - 36), control2: CGPoint(x: 156, y: horizon))
                    path.addLine(to: CGPoint(x: geo.size.width + 20, y: horizon))
                }
                .stroke(palette.line, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

#Preview {
    NativeOnboardingView()
}

extension Theme {
    /// The icon's line colour (DESIGN_SPEC §8), for onboarding eyebrows.
    static let brandLine = Color(light: 0x1F5F6E, dark: 0x8FD7E0)
}
