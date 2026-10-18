import SwiftUI

/// The severity indicator (never a brand mark): a tumbler whose water surface gains more of
/// the logo's gentle bumps as severity rises. Flat when smooth; an empty dashed outline when
/// it's too early to tell.
struct WaterGlass: View {
    let severity: Severity?
    var size: CGFloat = 24

    var body: some View {
        // Severity colours only, never the brand teal (DESIGN_SPEC §2): the glass is an
        // indicator, not a logo.
        let color = Theme.color(severity)
        let line = max(1.2, size / 16)
        ZStack {
            if let severity {
                WaterShape(severity: severity)
                    .fill(color.opacity(0.55))
                // The surface in the logo's line style: round caps and joins, gentle bumps.
                WaterSurface(severity: severity)
                    .stroke(color, style: StrokeStyle(lineWidth: line * 1.3, lineCap: .round, lineJoin: .round))
                GlassShape()
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            } else {
                GlassShape()
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round, dash: [size / 8, size / 10]))
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

/// The water surface, drawn like the app icon's line: flat when smooth (a small horizon),
/// then one, two or three of the icon's gentle bumps as severity rises. Never sharp peaks.
enum WaterSurfaceGeometry {
    static let levelFraction: CGFloat = 0.45
    static let wallInset: CGFloat = 0.12

    static func bumps(_ severity: Severity) -> (count: Int, height: CGFloat) {
        switch severity {
        case .smooth: (0, 0)
        case .light: (1, 0.07)
        case .moderate: (2, 0.085)
        case .severe: (3, 0.1)
        }
    }

    /// Adds the surface from the left wall to the right wall at the water line.
    static func addSurface(to path: inout Path, in rect: CGRect, severity: Severity, moveToStart: Bool) {
        let level = rect.minY + rect.height * levelFraction
        let inset = rect.width * wallInset * (level - rect.minY) / rect.height
        let left = rect.minX + inset + rect.width * 0.06
        let right = rect.maxX - inset - rect.width * 0.06
        if moveToStart { path.move(to: CGPoint(x: left, y: level)) } else { path.addLine(to: CGPoint(x: left, y: level)) }
        let (count, heightFraction) = bumps(severity)
        guard count > 0 else {
            path.addLine(to: CGPoint(x: right, y: level))
            return
        }
        let h = rect.height * heightFraction
        let slot = (right - left) / CGFloat(count)
        for k in 0..<count {
            // The icon's bump: flat lead-in, eased rise to a rounded crest, eased fall, flat.
            let x0 = left + slot * CGFloat(k)
            let w = slot
            path.addCurve(
                to: CGPoint(x: x0 + w * 0.5, y: level - h),
                control1: CGPoint(x: x0 + w * 0.22, y: level),
                control2: CGPoint(x: x0 + w * 0.31, y: level - h))
            path.addCurve(
                to: CGPoint(x: x0 + w, y: level),
                control1: CGPoint(x: x0 + w * 0.69, y: level - h),
                control2: CGPoint(x: x0 + w * 0.78, y: level))
        }
        path.addLine(to: CGPoint(x: right, y: level))
    }
}

/// Just the surface line, for the stroke.
struct WaterSurface: Shape {
    let severity: Severity

    func path(in rect: CGRect) -> Path {
        var path = Path()
        WaterSurfaceGeometry.addSurface(to: &path, in: rect, severity: severity, moveToStart: true)
        return path
    }
}

/// The water body under the surface, for the fill.
struct WaterShape: Shape {
    let severity: Severity

    func path(in rect: CGRect) -> Path {
        let inset = rect.width * WaterSurfaceGeometry.wallInset
        let level = rect.minY + rect.height * WaterSurfaceGeometry.levelFraction
        let wall = rect.width * WaterSurfaceGeometry.wallInset * (level - rect.minY) / rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + wall, y: level))
        WaterSurfaceGeometry.addSurface(to: &path, in: rect, severity: severity, moveToStart: false)
        path.addLine(to: CGPoint(x: rect.maxX - wall, y: level))
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
