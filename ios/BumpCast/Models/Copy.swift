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

    /// Short calm sentence for headlines ("A few bumps, mostly calm.").
    var headline: String {
        switch self {
        case .smooth: "Smooth all the way."
        case .mostlySmooth: "Mostly smooth."
        case .someBumps: "A few bumps, mostly calm."
        case .bumpy: "Bumpy in places."
        case .rough: "Some rough patches."
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
        case .smooth, .light, .moderate, .severe: Theme.color(self)
        }
    }
}

extension Forecast.Confidence {
    var title: String {
        switch self {
        case .early: "Advance forecast"
        case .partly: "Partly confirmed"
        case .confirmed: "Confirmed forecast"
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
        case .early: Theme.secondaryInk
        case .partly, .confirmed: Theme.accent
        }
    }

    /// One line under the grade, for everyone: when the forecast firms up (the badge says which kind).
    func statusLine(now: Date = .now) -> String {
        switch self {
        case .early(let expected):
            guard expected > now else { return "Being confirmed now" }
            return "Confirmed \(expected.approximateDayAndTime(now: now))"
        case .partly:
            return "Fully confirmed within the hour"
        case .confirmed:
            return "Updated hourly until you fly"
        }
    }

    /// Short version for the flights list.
    func shortStatus(now: Date = .now) -> String {
        switch self {
        case .early(let expected):
            guard expected > now else { return "Advance · confirming now" }
            return "Advance · confirms \(expected.relativeDay(now: now))"
        case .partly:
            return "Partly confirmed"
        case .confirmed:
            return "Confirmed"
        }
    }

    var explanation: String {
        switch self {
        case .early(let expected):
            return "An early look at your flight, so it can still change. "
                + "We'll confirm it \(expected.dayAndTime) with a more detailed forecast, and let you know if anything changes."
        case .partly(let minutes):
            return "The first \(minutes.durationText) of your flight is confirmed. "
                + "The rest is still an advance forecast (faded in the chart) and will be confirmed closer to departure, usually within the hour."
        case .confirmed:
            return "Confirmed with our detailed forecast for your route and altitude. "
                + "We keep updating it every hour until you fly."
        }
    }
}

extension Date {
    /// "today around 7:15 PM", "tomorrow around 6 AM", "Tuesday around 9:30 AM".
    func approximateDayAndTime(now: Date = .now) -> String {
        let time = formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(self, inSameDayAs: now) { return "today around \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(self, inSameDayAs: tomorrow) {
            return "tomorrow around \(time)"
        }
        return "\(formatted(.dateTime.weekday(.wide))) around \(time)"
    }

    /// "this afternoon", "tonight", "tomorrow morning", "Tuesday".
    func relativeDay(now: Date = .now) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: self)
        let part = hour < 12 ? "morning" : hour < 17 ? "afternoon" : "evening"
        if calendar.isDate(self, inSameDayAs: now) { return part == "evening" ? "tonight" : "this \(part)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(self, inSameDayAs: tomorrow) {
            return part == "evening" ? "tomorrow night" : "tomorrow \(part)"
        }
        return formatted(.dateTime.weekday(.wide))
    }

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
