import SwiftUI
import UIKit

/// BumpCast design tokens (docs/design/DESIGN_SPEC.md §2). Used by the app, widgets and Live Activity.
/// Turbulence never uses red, warning symbols or warning/error haptics.
enum Theme {
    static let ink = Color(light: 0x15253A, dark: 0xF2F5F8)
    static let secondaryInk = Color(light: 0x45576C, dark: 0xB7C3D0)
    static let accent = Color(light: 0x2A7385, dark: 0x6FBCCC)
    /// Label colour on accent-filled buttons. White on the light-mode accent; deep ink on the
    /// lighter dark-mode accent, where white would be about 2:1 contrast.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x0F1C2C)

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
        case .night: [Color(hex: 0x1B2A45), Color(hex: 0x121D31), Color(hex: 0x0B1322)]
        }
    }

    /// Night skies (and dark mode) switch to light ink.
    var isDark: Bool { self == .night }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

/// A sky gradient background that follows dark mode: dark mode always uses the night sky.
struct SkyBackground: View {
    let sky: Sky
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        (colorScheme == .dark ? Sky.night : sky).gradient.ignoresSafeArea()
    }
}

extension View {
    /// Content on the sky: a translucent card with a hairline border. Not used on glass.
    func skyCard(cornerRadius: CGFloat = 22, padding: CGFloat = 16) -> some View {
        modifier(SkyCard(cornerRadius: cornerRadius, padding: padding))
    }

    /// Sets light text when the sky is dark.
    func onSky(_ sky: Sky) -> some View {
        modifier(OnSky(sky: sky))
    }
}

private struct SkyCard: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.6), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.7), lineWidth: 0.5))
    }
}

private struct OnSky: ViewModifier {
    let sky: Sky
    func body(content: Content) -> some View {
        content.environment(\.colorScheme, sky.isDark ? .dark : .light)
    }
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
        self.init(
            uiColor: UIColor { traits in
                UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
            })
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
        func scaled(_ name: String, _ size: CGFloat, _ style: UIFont.TextStyle) -> UIFont? {
            UIFont(name: name, size: size).map { UIFontMetrics(forTextStyle: style).scaledFont(for: $0) }
        }
        let navigation = UINavigationBar.appearance()
        if let large = scaled(displayBold, 34, .largeTitle) {
            navigation.largeTitleTextAttributes = [.font: large]
        }
        if let inline = scaled(displaySemiBold, 17, .headline) {
            navigation.titleTextAttributes = [.font: inline]
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
        if let segment = scaled(body, 13, .footnote), let segmentSelected = scaled(bodyBold, 13, .footnote) {
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
