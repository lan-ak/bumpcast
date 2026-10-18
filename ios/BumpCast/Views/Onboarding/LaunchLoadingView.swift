import SwiftUI

/// Shown on first launch while Superwall loads the onboarding flow: the "Calm line" icon draws
/// itself (DESIGN_SPEC §8), the sun rises behind the horizon, then it breathes slowly until the
/// flow is ready. Reduce Motion shows the finished icon.
struct LaunchLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var drawn = false
    @State private var breathing = false

    var body: some View {
        ZStack {
            LinearGradient(colors: palette.sky, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                CalmLineIcon(palette: palette, lineProgress: drawn ? 1 : 0, sunRise: drawn ? 1 : 0)
                    .frame(width: 132, height: 132)
                    .clipShape(.rect(cornerRadius: 30, style: .continuous))
                    .scaleEffect(breathing ? 1.03 : 1)
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
                Text("BumpCast")
                    .font(.bcTitle)
                    .foregroundStyle(palette.ink)
                    .opacity(drawn ? 1 : 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("BumpCast is loading")
        .onAppear {
            if reduceMotion {
                drawn = true
                return
            }
            withAnimation(.smooth(duration: 1.6)) { drawn = true }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true).delay(1.6)) {
                breathing = true
            }
        }
    }

    private var palette: CalmLinePalette { colorScheme == .dark ? .dark : .light }
}

/// The app icon's colours by appearance (DESIGN_SPEC §8 "Colours by appearance").
struct CalmLinePalette {
    let sky: [Color]
    let water: [Color]
    let sun: Color
    let line: Color
    let ink: Color

    static let light = CalmLinePalette(
        sky: [Color(hex: 0xF6D9C4), Color(hex: 0xDFE6EF)],
        water: [Color(hex: 0xA9C6E2), Color(hex: 0x7FA6CC)],
        sun: Color(hex: 0xFFF3E8, opacity: 0.95),
        line: Color(hex: 0x1F5F6E),
        ink: Color(hex: 0x15253A))

    static let dark = CalmLinePalette(
        sky: [Color(hex: 0x1B2A45), Color(hex: 0x2C4262)],
        water: [Color(hex: 0x13203A), Color(hex: 0x0B1322)],
        sun: Color(hex: 0xF2D8B8, opacity: 0.85),
        line: Color(hex: 0x8FD7E0),
        ink: Color(hex: 0xF2F5F8))
}

/// The icon drawn live, on the 1024-point master geometry, so the line and sun can animate.
struct CalmLineIcon: View {
    let palette: CalmLinePalette
    /// 0 → 1: how much of the line is drawn, left to right.
    var lineProgress: CGFloat = 1
    /// 0 → 1: the sun from below the horizon to its resting place (half above it).
    var sunRise: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let unit = geo.size.width / 1024
            let horizon = 604 * unit
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: palette.sky, startPoint: .top, endPoint: .bottom)
                    .frame(height: horizon)
                Circle()
                    .fill(palette.sun)
                    .frame(width: 308 * unit, height: 308 * unit)
                    .position(x: 655 * unit, y: horizon + (1 - sunRise) * 154 * unit)
                LinearGradient(colors: palette.water, startPoint: .top, endPoint: .bottom)
                    .frame(height: geo.size.height - horizon)
                    .offset(y: horizon)
                Path { path in
                    path.move(to: CGPoint(x: 573 * unit, y: 686 * unit))
                    path.addLine(to: CGPoint(x: 737 * unit, y: 686 * unit))
                    path.move(to: CGPoint(x: 614 * unit, y: 737 * unit))
                    path.addLine(to: CGPoint(x: 696 * unit, y: 737 * unit))
                }
                .stroke(Color.white.opacity(0.7 * sunRise), style: StrokeStyle(lineWidth: 15 * unit, lineCap: .round))
                CalmLineShape()
                    .trim(from: 0, to: lineProgress)
                    .stroke(palette.line, style: StrokeStyle(lineWidth: 51 * unit, lineCap: .round, lineJoin: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// One small bump that settles into a long level line, past the right edge.
struct CalmLineShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 1024
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        var path = Path()
        path.move(to: point(133, 604))
        path.addCurve(to: point(317, 502), control1: point(215, 604), control2: point(246, 502))
        // "S420 604 502 604": the first control point mirrors (246, 502) about (317, 502).
        path.addCurve(to: point(502, 604), control1: point(388, 502), control2: point(420, 604))
        path.addLine(to: point(1085, 604))
        return path
    }
}

#Preview {
    LaunchLoadingView()
}
