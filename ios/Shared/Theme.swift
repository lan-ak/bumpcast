import SwiftUI
import UIKit

/// BumpCast design tokens (docs/design/DESIGN_SPEC.md §2). Used by the app, widgets and Live Activity.
/// Turbulence never uses red, warning symbols or warning/error haptics.
enum Theme {
    static let ink = Color(light: 0x15253A, dark: 0xF2F5F8)
    static let secondaryInk = Color(light: 0x45576C, dark: 0xB7C3D0)
    static let accent = Color(light: 0x2A7385, dark: 0x6FBCCC)

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
