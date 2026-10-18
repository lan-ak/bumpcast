import SwiftUI

/// The signature glyph: a tumbler whose water surface ripples more as severity rises.
/// Flat when smooth, small ripple for light chop, bigger for moderate, choppy for strong.
/// With no severity ("too early to tell") it's an empty dashed outline.
struct WaterGlass: View {
    let severity: Severity?
    var size: CGFloat = 24

    var body: some View {
        let color = Theme.color(severity)
        ZStack {
            if let severity {
                WaterShape(severity: severity)
                    .fill(color.opacity(0.85))
                GlassShape()
                    .stroke(color, style: StrokeStyle(lineWidth: max(1.2, size / 16), lineJoin: .round))
            } else {
                GlassShape()
                    .stroke(color, style: StrokeStyle(lineWidth: max(1.2, size / 16), lineJoin: .round, dash: [size / 8, size / 10]))
            }
        }
        .frame(width: size * 0.8, height: size)
        .accessibilityLabel(severity?.accessibilityName ?? "Too early to tell")
    }
}

extension Severity {
    var accessibilityName: String {
        switch self {
        case .smooth: "Smooth"
        case .light: "Light chop"
        case .moderate: "Moderate"
        case .severe: "Strong"
        }
    }

    /// How wavy the water surface is, 0 (flat) to 1 (choppy).
    var ripple: CGFloat {
        switch self {
        case .smooth: 0
        case .light: 0.35
        case .moderate: 0.65
        case .severe: 1
        }
    }
}

/// A slightly tapered tumbler outline.
struct GlassShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.12
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// The water inside the glass, filled to ~55% with a sine surface.
struct WaterShape: Shape {
    let severity: Severity

    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.12
        let level = rect.minY + rect.height * 0.45
        let amplitude = rect.height * 0.09 * severity.ripple
        let waves = 1.5 + 1.5 * severity.ripple
        // Left/right walls at the water line (the glass tapers toward the base).
        let leftAtLevel = rect.minX + inset * (level - rect.minY) / rect.height
        let rightAtLevel = rect.maxX - inset * (level - rect.minY) / rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: leftAtLevel, y: level))
        let steps = 24
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let x = leftAtLevel + (rightAtLevel - leftAtLevel) * t
            let y = level + sin(t * .pi * 2 * waves) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    HStack(spacing: 20) {
        ForEach(Severity.allCases, id: \.self) { WaterGlass(severity: $0, size: 44) }
        WaterGlass(severity: nil, size: 44)
    }
    .padding()
}
