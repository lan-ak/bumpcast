import SwiftUI

// Plain-language wording for grades and severities. Calm, concrete, never alarming.

extension Forecast.Grade {
    var title: String {
        switch self {
        case .smooth: "Smooth flight"
        case .mostlySmooth: "Mostly smooth"
        case .someBumps: "A few bumps"
        case .bumpy: "Bumpy in places"
        case .rough: "Some rough patches"
        }
    }

    var summary: String {
        switch self {
        case .smooth: "Calm air the whole way. A good day to fly."
        case .mostlySmooth: "Calm air almost the whole way, with a moment or two of light chop."
        case .someBumps: "Mostly calm, with a few bumpy stretches. Normal for most flights."
        case .bumpy: "Some stretches where the bumps get noticeable. Uncomfortable, but routine for the crew."
        case .rough: "A few stronger patches. Keep your seatbelt on and the crew will handle the rest."
        }
    }

    var color: Color {
        switch self {
        case .smooth, .mostlySmooth: Severity.smooth.color
        case .someBumps: Severity.light.color
        case .bumpy: Severity.moderate.color
        case .rough: Severity.severe.color
        }
    }

    var symbol: String {
        switch self {
        case .smooth, .mostlySmooth: "sun.max"
        case .someBumps: "wind"
        case .bumpy, .rough: "cloud.bolt"
        }
    }
}

extension Severity {
    var title: String {
        switch self {
        case .smooth: "Smooth"
        case .light: "Light chop"
        case .moderate: "Moderate"
        case .severe: "Strong"
        }
    }

    var feelsLike: String {
        switch self {
        case .smooth: "Your drink stays still."
        case .light: "Your drink ripples. The seatbelt sign may come on."
        case .moderate: "Walking is tricky and drinks can spill. Stay seated, belt on."
        case .severe: "Hard jolts. Rare. Your seatbelt is what keeps you safe, so keep it fastened."
        }
    }

    var color: Color {
        switch self {
        case .smooth: .teal
        case .light: Color(hue: 0.12, saturation: 0.95, brightness: 0.8)  // amber, readable on light backgrounds
        case .moderate: Color(hue: 0.06, saturation: 0.9, brightness: 0.9)
        case .severe: .red
        }
    }
}

extension Forecast.Confidence {
    var title: String {
        switch self {
        case .early: "Early outlook"
        case .partly: "Partly confirmed"
        case .confirmed: "NOAA forecast"
        }
    }

    var symbol: String {
        switch self {
        case .early: "binoculars"
        case .partly: "checkmark.seal"
        case .confirmed: "checkmark.seal.fill"
        }
    }

    var color: Color {
        switch self {
        case .early: .secondary
        case .partly, .confirmed: .blue
        }
    }

    var explanation: String {
        switch self {
        case .early(let expected):
            return "Based on global weather models, so it can still change. "
                + "NOAA's detailed turbulence forecast reaches your flight \(expected.dayAndTime), and we'll update this then."
        case .partly(let minutes):
            return "The first \(minutes.durationText) uses NOAA's detailed turbulence forecast. "
                + "The rest is our early outlook (faded in the chart) until NOAA's forecast reaches it, usually within the hour."
        case .confirmed:
            return "Based on NOAA's Graphical Turbulence Guidance, the same forecast US airline dispatchers use. "
                + "It's refreshed every hour until you fly."
        }
    }
}

extension Date {
    /// "today at 7:15 PM", "tomorrow at 6:00 AM", or "on Tuesday at 9:30 AM".
    var dayAndTime: String {
        let time = formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "today at \(time)" }
        if calendar.isDateInTomorrow(self) { return "tomorrow at \(time)" }
        return "on \(formatted(.dateTime.weekday(.wide))) at \(time)"
    }
}

enum FlightPhase {
    static func title(_ phase: String) -> String {
        switch phase {
        case "climb": "climbing"
        case "descent": "descending"
        default: "cruising"
        }
    }
}

extension Int {
    /// 95 -> "1 h 35 min"
    var durationText: String {
        let h = self / 60, m = self % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
