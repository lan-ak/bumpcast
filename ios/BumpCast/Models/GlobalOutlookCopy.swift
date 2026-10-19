import Foundation

// Wording for the global outlook (beta), from docs/design/global-forecasts-copy.md.
// The outlook must read rougher than a confirmed forecast: approximate times, one-step
// ranges, never "smooth", and strong turbulence only ever "possible", near a warning or report.
// Never name a data source.

enum GlobalOutlookCopy {
    static let title = "Global outlook (beta)"
    static let body = "Your route leaves the area we can forecast in full detail, so this is our worldwide outlook. "
        + "It's newer and less detailed than our forecasts for US routes, and it updates every 6 hours until you fly."
    static let basedOn = "Worldwide weather forecasts, checked against official warnings and recent pilot reports."
    static let howToRead = "Times are approximate and levels are ranges. It can miss bumps, so treat it as a guide and keep your seatbelt fastened."
    static let helpImprove = "After you land, tell us how it felt. Every rating makes the outlook better."
    static let anyFlight = "Light bumps are possible on any flight."
    static let statusWarning = "Official warning on your route"
    static let listWarning = "Official warning on route"
    static let listBetaAvailable = "Beta available"
    static let legendConfirmed = "Confirmed, exact"
    static let legendOutlook = "Outlook, approximate"

    // Opt-in
    static let waitlistTitle = "Try the global outlook for this flight"
    static let waitlistBody = "A newer, less detailed forecast for routes outside the US. Times are approximate and it can miss bumps."
    static let turnOn = "Turn on the beta"
    static let notNow = "Not now"
    static let settingsLabel = "Global outlooks"
    static let settingsFooter = "Forecasts for flights outside the US. Less detailed than US forecasts, and updated every 6 hours. After each one, we'll ask how it felt."
    static let addQuestion = "Get the global outlook (beta) for this flight?"
    static let addFirstPartConfirmed = "The first part, over the US, is confirmed. "
    static let addExplanation = "The rest is our newer worldwide outlook."
    static let addExplanationAll = "It's our newer worldwide outlook: less detailed than US forecasts, with approximate times."
    static let notForecastYet = "Not forecast yet"
    static let notForecastYetBody = "This route can use our global outlook (beta). Turn it on to get a forecast for this flight."
    static let unsupportedTitle = "We can't forecast this route yet"
    static let unsupportedBody = "We're adding more of the world. We'll tell you when we can forecast it."
    static let unsupportedAction = "Notify me when we can"

    // After landing
    static func landingBody() -> String {
        "How bumpy was it? You flew with our beta global outlook, and your two taps help us improve it."
    }
    static let compareTitle = "How did it compare?"
    static let compareFooter = "Your answer helps us improve global outlooks."
}

extension Forecast.Grade {
    /// Outlook headline: never "smooth".
    var outlookHeadline: String {
        switch self {
        case .smooth, .mostlySmooth: "No major bumps expected."
        case .someBumps: "A few bumps possible."
        case .bumpy, .rough: "Bumpy in places."
        }
    }

    /// Outlook summary: always ends with "Light bumps are possible on any flight."
    var outlookSummary: String {
        switch self {
        case .smooth, .mostlySmooth: GlobalOutlookCopy.anyFlight
        case .someBumps: "A few stretches could be bumpy. \(GlobalOutlookCopy.anyFlight)"
        case .bumpy, .rough: "Some stretches could get noticeably bumpy. \(GlobalOutlookCopy.anyFlight)"
        }
    }

    /// Outlook title for the flights list.
    var outlookTitle: String {
        switch self {
        case .smooth, .mostlySmooth: "No major bumps"
        case .someBumps: "A few bumps possible"
        case .bumpy, .rough: "Bumpy in places"
        }
    }
}

extension Forecast.Segment {
    /// "About 1 h 30 min in, for around 30 min" (outlook stretches only).
    var approximateTiming: String {
        let length = minutes.roughMinutes.durationText
        if startMin < 5 { return "Soon after takeoff, for around \(length)" }
        return "About \(startMin.roughMinutes.durationText) in, for around \(length)"
    }

    /// A one-step range. Strong is only ever possible near a warning or a pilot report.
    func outlookRange(warning: Forecast.Warning?) -> String {
        if let warning, warning.isOfficial || warning.severity == .severe {
            return "Moderate to strong possible near the \(warning.isOfficial ? "warning" : "pilot report")"
        }
        return "Light to moderate possible"
    }

    func outlookBody(warning: Forecast.Warning?) -> String {
        "\(outlookRange(warning: warning)) while \(FlightPhase.title(phase))."
    }
}

extension Forecast.Warning {
    var hazardName: String {
        switch hazard {
        case "thunderstorms": "Thunderstorms"
        case "mountain_wave": "Mountain-wave turbulence"
        case "tropical_cyclone": "A tropical storm"
        default: "Strong turbulence"
        }
    }

    /// "Thunderstorms over Recife, about 1 h 30 min in"
    var bannerText: String {
        let place = region.map { " over \($0)" } ?? " on your route"
        let when = startMin < 5 ? "soon after takeoff" : "about \(startMin.roughMinutes.durationText) in"
        return "\(hazardName)\(place), \(when)"
    }

    /// "⚑ Official warning · thunderstorms" for stretch rows.
    var rowLabel: String {
        isOfficial ? "Official warning · \(hazardName.lowercased())" : "Pilot report · \(severity.title.lowercased()) bumps"
    }

    var sheetBody: String {
        let length = minutes.roughMinutes.durationText
        let when = startMin < 5 ? "soon after takeoff" : "around \(startMin.roughMinutes.durationText) after takeoff"
        return "Aviation weather offices issue warnings where strong turbulence or storms are likely. "
            + "This one covers about \(length) of your route, \(when)."
    }

    var whatYouMightFeel: String {
        let near = hazard == "thunderstorms" || hazard == "tropical_cyclone" ? "near the storms" : "in this area"
        let belt = startMin >= 40
            ? "Keep your seatbelt fastened from about \((startMin - 30).roughMinutes.durationText) in."
            : "Keep your seatbelt fastened from takeoff."
        return "Moderate to strong bumps are possible \(near). \(belt)"
    }

    static let sheetHeading = "What this means for your flight"
    static let crewTitle = "Your crew has this warning too."
    static let crewBody = "Pilots fly around storms, often by many miles, and turn the seatbelt sign on early."
    static let sheetFooter = "Warnings are updated through the day. We'll tell you if this one changes or clears."
    static let pilotReportTitle = "Pilots reported bumps here"
    static func pilotReportBody(_ warning: Forecast.Warning) -> String {
        "A pilot near this part of your route reported \(warning.severity.title.lowercased()) bumps in the last couple of hours. "
            + "Pilots share what they feel so the crews behind them can pick a smoother height. Most reports are routine."
    }
}

extension FeltRating {
    /// After a beta flight: compared with the outlook.
    var outlookTitle: String {
        switch self {
        case .smoother: "Smoother than the outlook"
        case .aboutRight: "About what it said"
        case .bumpier: "Bumpier than the outlook"
        }
    }
}
