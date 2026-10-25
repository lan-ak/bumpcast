import SwiftUI
import UIKit
import Combine

/// BumpCast design tokens (docs/design/DESIGN_SPEC.md §2). Used by the app, widgets and Live Activity.
/// Turbulence never uses red, warning symbols or warning/error haptics.
enum Theme {
    static let ink = Color(light: Hex.ink, dark: Hex.nightInk)
    static let secondaryInk = Color(light: 0x45576C, dark: 0xB7C3D0)
    /// Chevrons, placeholders and other quiet marks.
    static let tertiaryInk = secondaryInk.opacity(0.6)
    static let accent = Color(light: 0x2A7385, dark: 0x6FBCCC)
    /// Label colour on accent-filled buttons. White on the light-mode accent; deep ink on the
    /// lighter dark-mode accent, where white would be about 2:1 contrast.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x0F1C2C)
    /// The icon's line colour (DESIGN_SPEC §8), for onboarding eyebrows.
    static let brandLine = Color(light: Hex.brandLine, dark: Hex.nightBrandLine)
    /// The route line on the map: a deeper teal than the accent, so it reads over the fields.
    static let routeInk = Color(light: 0x1B5664, dark: 0x8FD3E0)
    /// The white halo around marks on the map (route casing, report dots), so they read over any field.
    static let mapHalo = Color.white

    /// Surfaces that are always night whatever the phone's appearance (the Live Activity).
    static let nightInk = Color(hex: Hex.nightInk)
    static let nightSecondaryInk = Color(hex: 0xB7C3D0)

    /// The breathing orb on the Calm tab and the breathing screen.
    static let orb: [Color] = [Color(hex: 0xF4FBFD), Color(hex: 0xA8DBE3), Color(hex: 0x4F9BAB)]
    static let orbGlow = Color(hex: Hex.nightBrandLine)

    /// Hex values shared between tokens and the icon palette, so each colour is written once.
    fileprivate enum Hex {
        static let ink: UInt32 = 0x15253A
        static let nightInk: UInt32 = 0xF2F5F8
        static let brandLine: UInt32 = 0x1F5F6E
        static let nightBrandLine: UInt32 = 0x8FD7E0
        static let nightSkyTop: UInt32 = 0x1B2A45
    }

    static func color(_ severity: Severity?) -> Color {
        switch severity {
        case .smooth: Color(light: 0x3A9A8F, dark: 0x5CC0B3)
        case .light: Color(light: 0xC99A2E, dark: 0xE0B54E)
        case .moderate: Color(light: 0xC9733A, dark: 0xE38F55)
        case .severe: Color(light: 0x8E4A6B, dark: 0xC57EA0)  // muted plum, never red
        case nil: secondaryInk
        }
    }

    /// The soft spring every animation uses: critically damped, no bounce.
    static let spring = Animation.smooth(duration: 0.6)
    /// The Reduce Motion fallback: a cross-fade.
    static let fade = Animation.easeInOut(duration: 0.35)

    static func motion(_ reduceMotion: Bool) -> Animation { reduceMotion ? fade : spring }
}

/// Time-of-day sky behind content, chosen from the departure's local time.
enum Sky: String, CaseIterable {
    case dawn, day, dusk, night

    init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch calendar.component(.hour, from: date) {
        case 5..<9: self = .dawn
        case 9..<17: self = .day
        case 17..<20: self = .dusk
        default: self = .night
        }
    }

    var colors: [Color] {
        switch self {
        case .dawn: [Color(hex: 0xF6D9C4), Color(hex: 0xDFE3EC), Color(hex: 0xB9D0E6)]
        case .day: [Color(hex: 0xCFE3F3), Color(hex: 0xE6EFF6), Color(hex: 0xF4F7FA)]
        case .dusk: [Color(hex: 0xE7C3C9), Color(hex: 0xC9BFD9), Color(hex: 0x9FB0D0)]
        case .night: [Color(hex: Theme.Hex.nightSkyTop), Color(hex: 0x121D31), Color(hex: 0x0B1322)]
        }
    }

    /// Night skies (and dark mode) switch to light ink.
    var isDark: Bool { self == .night }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

/// A sky gradient background that follows dark mode: dark mode always uses the night sky.
/// Private: screens use `.skyBackground(_:)`, which also sets the ink, so a dark sky can never
/// sit behind dark text.
private struct SkyBackground: View {
    let sky: Sky
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shown = colorScheme == .dark ? Sky.night : sky
        // Every sky stays laid out and only the shown one is opaque, so a new departure time
        // cross-fades the sky instead of cutting it. The shown sky's middle colour sits behind,
        // so the screen never thins out halfway through the fade.
        ZStack {
            shown.colors[1]
            ForEach(Sky.allCases, id: \.self) { $0.gradient.opacity($0 == shown ? 1 : 0) }
        }
        .animation(Theme.fade, value: shown)
        .ignoresSafeArea()
    }
}

extension View {
    /// Content on the sky: a translucent card with a hairline border. Not used on glass.
    func skyCard(cornerRadius: CGFloat = 22, padding: CGFloat = 16) -> some View {
        modifier(SkyCard(cornerRadius: cornerRadius, padding: padding))
    }

    /// The card's translucent fill and hairline in any shape, for chips, option rows and round
    /// buttons that sit on the sky. `raised` is the brighter fill for a selected option.
    func skySurface<S: InsettableShape>(_ shape: S, raised: Bool = false) -> some View {
        modifier(SkySurface(shape: shape, raised: raised))
    }

    /// The house style, applied once at the root of the app and of the Live Activity: brand body
    /// type and the accent tint. Sheets and covers inherit it, so screens only override it, never
    /// restate it. The ink comes from `skyBackground(_:)`, not here: a foreground style at the root
    /// also reaches the tab bar and toolbar buttons, and dims their symbols.
    func bumpCastTheme() -> some View {
        font(.bcBody).tint(Theme.accent)
    }

    /// Theme ink for primary, secondary and tertiary text, so `.secondary` and `.tertiary` mean the
    /// theme's inks rather than the system greys. Part of `skyBackground(_:)`.
    func themeInk() -> some View {
        foregroundStyle(Theme.ink, Theme.secondaryInk, Theme.tertiaryInk)
    }

    /// The app root only: switches the app to its night appearance after dark (see `NightAppearance`).
    func nightAppearanceAfterDark() -> some View {
        modifier(NightAppearance())
    }

    /// The one way to put a screen on the sky, and so every screen's style root: paints the
    /// gradient and sets the theme ink to match it.
    /// Night skies (and dark mode, which always shows the night sky) get light text; every
    /// other sky gets dark text, so the two can never disagree.
    func skyBackground(_ sky: Sky) -> some View {
        themeInk().background { SkyBackground(sky: sky) }.modifier(OnSky(sky: sky))
    }
}

private struct SkyCard: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .skySurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct SkySurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let raised: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .background(Color.white.opacity(dark ? (raised ? 0.16 : 0.08) : (raised ? 0.95 : 0.6)), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.12 : 0.7), lineWidth: 0.5))
    }
}

private struct OnSky: ViewModifier {
    let sky: Sky
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let scheme: ColorScheme = sky.isDark || systemScheme == .dark ? .dark : .light
        content.environment(\.colorScheme, scheme)
    }
}

/// After dark the whole app takes its night appearance, so the system bars (navigation titles,
/// toolbar buttons, the tab bar, the status bar) match the night sky behind them. Bars are UIKit
/// and only follow the window's appearance, never a screen's environment.
private struct NightAppearance: ViewModifier {
    @State private var sky = Sky(date: .now)
    @Environment(\.scenePhase) private var scenePhase
    private let tick = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(sky.isDark ? .dark : nil)
            .onChange(of: scenePhase) { sky = Sky(date: .now) }
            .onReceive(tick) { _ in sky = Sky(date: .now) }
    }
}

/// The app icon's colours by appearance (DESIGN_SPEC §8 "Colours by appearance"), for the
/// launch screen and onboarding horizon. Fixed per appearance, so they don't adapt on their own.
struct CalmLinePalette {
    let sky: [Color]
    let water: [Color]
    let sun: Color
    let line: Color
    let ink: Color
    /// The sun's reflection on the water.
    var glint: Color { .white.opacity(0.7) }

    static let light = CalmLinePalette(
        sky: [Color(hex: 0xF6D9C4), Color(hex: 0xDFE6EF)],
        water: [Color(hex: 0xA9C6E2), Color(hex: 0x7FA6CC)],
        sun: Color(hex: 0xFFF3E8, opacity: 0.95),
        line: Color(hex: Theme.Hex.brandLine),
        ink: Color(hex: Theme.Hex.ink))

    static let dark = CalmLinePalette(
        sky: [Color(hex: Theme.Hex.nightSkyTop), Color(hex: 0x2C4262)],
        water: [Color(hex: 0x13203A), Color(hex: 0x0B1322)],
        sun: Color(hex: 0xF2D8B8, opacity: 0.85),
        line: Color(hex: Theme.Hex.nightBrandLine),
        ink: Color(hex: Theme.Hex.nightInk))
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// Adapts to light and dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor(light: light, dark: dark))
    }
}

extension UIColor {
    /// Adapts to light and dark mode, for UIKit bars that resolve colours against their own traits.
    convenience init(light: UInt32, dark: UInt32) {
        self.init { traits in UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light)) }
    }
}

/// BumpCast type scale (DESIGN_SPEC §2 "Type"): Familjen Grotesk for display, Atkinson
/// Hyperlegible for body, IBM Plex Mono for data. All scale with Dynamic Type through
/// `relativeTo:`. System chrome (tab bars, nav bars, alerts, menus) stays on SF Pro.
enum BrandFont {
    static let displaySemiBold = "FamiljenGrotesk-SemiBold"
    static let displayBold = "FamiljenGrotesk-Bold"
    static let body = "AtkinsonHyperlegible-Regular"
    static let bodyBold = "AtkinsonHyperlegible-Bold"
    static let mono = "IBMPlexMono-Regular"
    static let monoMedium = "IBMPlexMono-Medium"
}

extension BrandFont {
    /// No system font (DESIGN_SPEC §2): brand faces on the native bars and controls, scaled with
    /// Dynamic Type. Only the text changes; the components stay native Liquid Glass.
    @MainActor
    static func applyToSystemControls() {
        func scaled(_ name: String, _ size: CGFloat, _ style: UIFont.TextStyle, max: CGFloat = .greatestFiniteMagnitude) -> UIFont? {
            UIFont(name: name, size: size).map { UIFontMetrics(forTextStyle: style).scaledFont(for: $0, maximumPointSize: max) }
        }
        let navigation = UINavigationBar.appearance()
        let ink = UIColor(light: Theme.Hex.ink, dark: Theme.Hex.nightInk)
        if let large = scaled(displayBold, 34, .largeTitle) {
            navigation.largeTitleTextAttributes = [.font: large, .foregroundColor: ink]
        }
        if let inline = scaled(displaySemiBold, 17, .headline) {
            navigation.titleTextAttributes = [.font: inline, .foregroundColor: ink]
        }
        if let button = scaled(body, 17, .body) {
            for state: UIControl.State in [.normal, .highlighted, .disabled] {
                UIBarButtonItem.appearance().setTitleTextAttributes([.font: button], for: state)
            }
        }
        if let tab = scaled(body, 10, .caption2), let tabSelected = scaled(bodyBold, 10, .caption2) {
            UITabBarItem.appearance().setTitleTextAttributes([.font: tab], for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes([.font: tabSelected], for: .selected)
        }
        // Capped, so a two-segment control ("Upcoming", "Flown") never cuts a word at the largest sizes.
        if let segment = scaled(body, 13, .footnote, max: 24), let segmentSelected = scaled(bodyBold, 13, .footnote, max: 24) {
            UISegmentedControl.appearance().setTitleTextAttributes([.font: segment], for: .normal)
            UISegmentedControl.appearance().setTitleTextAttributes([.font: segmentSelected], for: .selected)
        }
        if let search = scaled(body, 17, .body) {
            UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).font = search
        }
    }
}

extension Font {
    /// Grade headlines and hero routes.
    static let bcDisplay = Font.custom(BrandFont.displayBold, size: 34, relativeTo: .largeTitle)
    /// Big status lines ("Breathe in").
    static let bcTitle = Font.custom(BrandFont.displayBold, size: 28, relativeTo: .title)
    /// Card titles ("Too early to tell").
    static let bcTitle2 = Font.custom(BrandFont.displaySemiBold, size: 22, relativeTo: .title2)
    /// Section titles ("What to expect").
    static let bcSection = Font.custom(BrandFont.displaySemiBold, size: 20, relativeTo: .title3)
    /// Headings inside cards ("In flight", "Good to know").
    static let bcCardTitle = Font.custom(BrandFont.displaySemiBold, size: 18, relativeTo: .headline)
    /// Row titles and routes.
    static let bcHeadline = Font.custom(BrandFont.bodyBold, size: 17, relativeTo: .headline)
    /// Body copy on cards.
    static let bcBody = Font.custom(BrandFont.body, size: 17, relativeTo: .body)
    /// Secondary lines and explanations.
    static let bcSubheadline = Font.custom(BrandFont.body, size: 15, relativeTo: .subheadline)
    static let bcSubheadlineStrong = Font.custom(BrandFont.bodyBold, size: 15, relativeTo: .subheadline)
    /// Routes, departure times and update times ("Mon, Oct 19 at 11:22 AM EDT", "Updated 6:41 AM").
    static let bcMeta = Font.custom(BrandFont.mono, size: 13, relativeTo: .footnote)
    static let bcFootnote = Font.custom(BrandFont.body, size: 13, relativeTo: .footnote)
    static let bcFootnoteStrong = Font.custom(BrandFont.bodyBold, size: 13, relativeTo: .footnote)
    /// Small uppercase labels ("NEXT FLIGHT"); pair with `.textCase(.uppercase)` and `.tracking(1.4)`.
    static let bcEyebrow = Font.custom(BrandFont.monoMedium, size: 12, relativeTo: .caption)
    /// Labels, badges and legends.
    static let bcCaption = Font.custom(BrandFont.body, size: 12, relativeTo: .caption)
    static let bcCaptionStrong = Font.custom(BrandFont.bodyBold, size: 12, relativeTo: .caption)
    static let bcCaption2 = Font.custom(BrandFont.body, size: 11, relativeTo: .caption2)
    static let bcCaption2Strong = Font.custom(BrandFont.bodyBold, size: 11, relativeTo: .caption2)
    /// Figures in stat tiles (the display face has tabular digits).
    static let bcFigure = Font.custom(BrandFont.displaySemiBold, size: 20, relativeTo: .title3)
    /// Countdowns that tick every second.
    static let bcBigFigure = Font.custom(BrandFont.displayBold, size: 34, relativeTo: .largeTitle)

    /// SF Symbols that stand alone (not beside text), sized with Dynamic Type.
    /// A sheet's hero symbol.
    static let bcSymbolHero = Font.system(.largeTitle, weight: .light)
    /// Symbols in round controls (the onboarding back button).
    static let bcSymbolControl = Font.system(.body, weight: .semibold)
    /// Check circles on multi-select rows.
    static let bcSymbolSelect = Font.system(.title2)
}

extension View {
    /// Small uppercase data label in Plex Mono.
    func eyebrow() -> some View {
        font(.bcEyebrow).textCase(.uppercase).tracking(1.4)
    }
}

/// Side by side at normal text sizes; stacked at accessibility sizes, so text keeps a
/// full-width column instead of squeezing beside an icon.
struct AdaptiveStack<Content: View>: View {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        layout { content }
    }
}

extension View {
    /// Display headlines stop growing at the first accessibility size, so a two-word grade
    /// never fills the screen. Body text keeps scaling all the way.
    func displayTypeLimit() -> some View {
        dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}
