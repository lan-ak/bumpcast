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
        case .globalOutlook: "Global outlook"
        }
    }

    /// The badge carries a BETA tag on global outlooks.
    var isBeta: Bool {
        if case .globalOutlook = self { true } else { false }
    }

    var symbol: String {
        switch self {
        case .early: "binoculars"
        case .partly: "checkmark.seal"
        case .confirmed: "checkmark.seal.fill"
        case .globalOutlook: "globe"
        }
    }

    var color: Color {
        switch self {
        case .early, .globalOutlook: Theme.secondaryInk
        case .partly, .confirmed: Theme.accent
        }
    }

    /// One line under the grade, for everyone: when the forecast firms up (the badge says which kind).
    func statusLine(now: Date = .now, durationMin: Int? = nil) -> String {
        switch self {
        case .early(let expected):
            guard expected > now else { return "Being confirmed now" }
            return "Confirmed \(expected.approximateDayAndTime(now: now))"
        case .partly:
            return "Fully confirmed within the hour"
        case .confirmed:
            return "Updated hourly until you fly"
        case .globalOutlook(let confirmed):
            guard let text = Self.confirmedText(confirmed, durationMin: durationMin) else {
                return "Updated every 6 hours until you fly"
            }
            return "\(text) The rest is a beta outlook, updated every 6 hours."
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
        case .globalOutlook:
            return "Global outlook · beta"
        }
    }

    var explanation: String { explanation(now: .now) }

    /// Never promises a time that has passed: once the expected confirmation is behind us, it says
    /// it's being confirmed instead.
    func explanation(now: Date) -> String {
        switch self {
        case .early(let expected):
            guard expected > now else {
                return "An early look at your flight, so it can still change. "
                    + "We're confirming it with a more detailed forecast, and we'll let you know if anything changes."
            }
            return "An early look at your flight, so it can still change. "
                + "We'll confirm it \(expected.dayAndTime) with a more detailed forecast, and let you know if anything changes."
        case .partly(let confirmed):
            return "\(Self.confirmedText(confirmed) ?? "Part of your flight is confirmed.") "
                + "The rest is still an advance forecast (faded in the chart) and will be confirmed closer to departure, usually within the hour."
        case .confirmed:
            return "Confirmed with our detailed forecast for your route and altitude. "
                + "We keep updating it every hour until you fly."
        case .globalOutlook:
            return GlobalOutlookCopy.body
        }
    }

    /// When the forecast should next update on the ground, or nil when we can't say: an advance
    /// forecast waits for its confirmation, the rest follow the worker's hourly (6-hourly for global
    /// outlooks) runs. Never a time that has already passed.
    func nextUpdate(after issued: Date, now: Date = .now) -> Date? {
        let next: Date = switch self {
        case .early(let expected): expected
        case .globalOutlook: issued.addingTimeInterval(6 * 3600)
        case .partly, .confirmed: issued.addingTimeInterval(3600)
        }
        return next > now ? next : nil
    }

    /// In the air, under the grade: what's saved and how old it is.
    /// "Confirmed forecast from 2:20 PM, saved before takeoff." · "… updated in the air."
    func savedLine(issuedAt: Date?, inAir: Bool) -> String {
        let kind = switch self {
        case .early: "Advance forecast"
        case .partly: "Partly confirmed forecast"
        case .confirmed: "Confirmed forecast"
        case .globalOutlook: "Global outlook"
        }
        let from = issuedAt.map { " from \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        let line = "\(kind)\(from), \(inAir ? "updated in the air" : "saved before takeoff")."
        if case .early = self { return line + " It wasn't confirmed in time, so treat it as a guide." }
        return line
    }

    /// The footer's explanation once the flight is under way: nothing about updates to come.
    var inFlightExplanation: String {
        switch self {
        case .early:
            "An early look that wasn't confirmed before takeoff, so treat it as a guide. "
                + "If the seatbelt sign comes on, keep your belt fastened."
        case .partly:
            "Part of this is confirmed. The faded parts of the chart are an advance forecast, so treat them as a guide."
        case .confirmed:
            "Confirmed with our detailed forecast for your route and altitude, and saved on your phone so it works without a connection."
        case .globalOutlook:
            GlobalOutlookCopy.howToRead
        }
    }

    /// "First 41 min confirmed." · "First 41 min and last 30 min confirmed." ·
    /// "Confirmed from 1 h 10 min to 2 h 05 min in." · "3 stretches confirmed, 2 h 15 min in total."
    /// `nil` when nothing is confirmed. Pass the flight's length to recognise "last".
    static func confirmedText(_ stretches: [ClosedRange<Int>], durationMin: Int? = nil) -> String? {
        guard let first = stretches.first else { return nil }
        let isLast = { (r: ClosedRange<Int>) in durationMin.map { r.upperBound >= $0 } ?? false }
        func length(_ r: ClosedRange<Int>) -> String { (r.count).durationText }
        switch stretches.count {
        case 1 where first.lowerBound == 0:
            return "First \(length(first)) confirmed."
        case 1 where isLast(first):
            return "Last \(length(first)) confirmed."
        case 1:
            return "Confirmed from \(first.lowerBound.clockText) to \((first.upperBound + 1).clockText) in."
        case 2 where first.lowerBound == 0 && isLast(stretches[1]):
            return "First \(length(first)) and last \(length(stretches[1])) confirmed."
        default:
            let total = stretches.map(\.count).reduce(0, +)
            return "\(stretches.count) stretches confirmed, \(total.durationText) in total."
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

// MARK: In the air

/// Wording once the flight is under way: present tense, about what's left, and honest about what's
/// saved on the phone. Wifi advice only promises what we do (re-time to takeoff, pick up a new forecast).
enum InFlightCopy {
    /// "In the air · just took off" · "In the air · 12 min in"
    static func eyebrow(minute: Int) -> String {
        minute < 1 ? "In the air · just took off" : "In the air · \(minute.durationText) in"
    }

    /// "Landing in about 25 min, around 3:45 PM EDT" · "Landing soon"
    static func landing(_ landing: Date, now: Date, tz: TimeZone) -> String {
        guard landing.timeIntervalSince(now) >= 120 else { return "Landing soon" }
        return "Landing in about \(minutesLeft(to: landing, now: now).durationText), around \(landing.localTimeWithZone(in: tz))"
    }

    /// Whole minutes to landing, to the nearest minute. "Left to fly" uses it too, so the two agree.
    static func minutesLeft(to landing: Date, now: Date) -> Int {
        max(0, Int((landing.timeIntervalSince(now) / 60).rounded()))
    }

    /// Which takeoff the countdown counts from, so a re-time never looks like a glitch.
    static func basis(_ basis: InFlight.TakeoffBasis, takeoff: Date, tz: TimeZone) -> String {
        let time = takeoff.localTime(in: tz)
        return switch basis {
        case .reported: "Timed from takeoff at \(time)."
        case .tapped: "Timed from when you tapped takeoff, at \(time)."
        case .expected: "Timed from the expected takeoff, around \(time)."
        }
    }

    static let offline = "Offline. Your forecast and countdown still work."
    /// On a network that isn't reaching the internet.
    static let notOnline = "Not online yet. Your forecast and countdown still work."
    /// Online, but the last update didn't go through for some other reason.
    static let syncFailed = "Couldn't check for updates just now. Your forecast and countdown still work."
    static let wifiInAir = "If your plane has wifi, connect to it. "
        + "We'll update your forecast and countdown if your takeoff time or the forecast changes."
    static let wifiBeforeTakeoff = "If your plane has wifi, connect to it after takeoff. "
        + "We'll update your forecast and countdown if your takeoff time or the forecast changes. Without wifi, everything still works."
    /// A network that isn't reaching the internet yet, usually wifi waiting for a sign-in (it can be cellular).
    static let notOnlineYet = "Connected, but not reaching the internet. If the plane's wifi needs a sign-in, finish it in Safari."
    /// After a sync that worked in the air.
    static func connected(at date: Date) -> String {
        "Connected. Checked for updates at \(date.formatted(date: .omitted, time: .shortened))."
    }

    /// Before boarding, not armed yet. True whether the Live Activity starts now or later.
    static func boardingBody(takeoff: String) -> String {
        "Get your bump countdown ready before you board. From takeoff, around \(takeoff), your Lock Screen "
            + "counts down to each bumpy stretch and reminds you before it starts. Works without wifi."
    }

    /// Armed on the ground. The Live Activity comes up about 15 minutes before departure.
    static func armedBody(takeoff: String, onLockScreen: Bool) -> String {
        onLockScreen
            ? "It's on your Lock Screen now. From takeoff, around \(takeoff), it counts down to each bumpy "
                + "stretch and reminds you before it starts. Works without wifi."
            : "It comes up on your Lock Screen shortly before departure. From takeoff, around \(takeoff), it "
                + "counts down to each bumpy stretch and reminds you before it starts. Works without wifi."
    }
    /// Armed with no connection: the tap is the only way the countdown hears about wheels-up.
    static let tapWhenUp = "No connection up there? Tap “We've taken off” when the wheels leave the runway."
    static let matchedToTakeoff = "We'll match the countdown to your real takeoff time once it's reported. Tap if you're up first."
    static let lockScreen = "The countdown is on your Lock Screen too."
    static let timelineOffline = "Connect to wifi to see the full timeline."

    /// Not armed, and the airline reported wheels-up: the countdown is the paid step.
    static let airborneTitle = "In the air"
    static func airborneBody(takeoff: Date, tz: TimeZone) -> String {
        "Took off at \(takeoff.localTime(in: tz)). Start your bump countdown to see each bumpy stretch on your "
            + "Lock Screen, with a reminder before each one. Works without wifi."
    }
    static let startCountdown = "Start the countdown"

    static let seatbeltButton = "Seatbelt sign is on"
    static func seatbeltNoted(minute: Int) -> String {
        let when = minute < 1 ? "just after takeoff" : "at \(minute.durationText) in"
        return "Noted \(when). Thanks, this helps us check your forecast."
    }
    /// The sign came on with no stretch nearby in the forecast.
    static let seatbeltEarly = "Crews often turn the sign on early, when other pilots report bumps ahead."

    static let stillAhead = "Still ahead"

    /// Diverted with the countdown on: it's timed to the original route, and the landing tap ends it.
    static let divertedTitle = "Countdown still on"
    static func divertedBody(onLockScreen: Bool) -> String {
        (onLockScreen ? "Your Lock Screen countdown and reminders" : "Your reminders before each bumpy stretch")
            + " follow the original route, so they may not match your flight now. "
            + "Tap “We've landed” once you're down to end them."
    }

    /// Nothing left ahead: "Smooth to landing", or for a global outlook "No major bumps expected to landing".
    static func clearToLanding(outlook: Bool) -> String {
        outlook ? "No major bumps expected to landing" : "Smooth to landing"
    }
}

/// Why the screens are showing what's saved, if they are. Only a connection problem gets
/// connection wording; a sync that failed for another reason (a server error) gets a neutral line.
enum ConnectionNote: Equatable {
    case none
    /// No network at all: airplane mode, or no signal.
    case offline
    /// A network that isn't reaching the internet: captive or plane wifi, or a failing connection.
    case notOnline
    /// Connected, but the last update didn't go through.
    case syncFailed

    /// `failedOnConnection`: the failed sync timed out or lost the connection, so the wording stays
    /// the same while the next try is on its way (the degraded note clears before it answers).
    init(hasPath: Bool, isDegraded: Bool, syncFailed: Bool, failedOnConnection: Bool = false) {
        self =
            !hasPath ? .offline
            : isDegraded || (syncFailed && failedOnConnection) ? .notOnline
            : syncFailed ? .syncFailed : .none
    }

    @MainActor init(store: FlightStore, connectivity: Connectivity = .shared) {
        self.init(
            hasPath: connectivity.hasPath, isDegraded: connectivity.isDegraded, syncFailed: store.isOffline,
            failedOnConnection: store.failedOnConnection)
    }

    /// No connection, or one that isn't reaching the internet.
    var isConnectionProblem: Bool { self == .offline || self == .notOnline }

    var symbol: String { self == .syncFailed ? "arrow.clockwise.circle" : "wifi.slash" }
}

/// What the app says when it's showing what's saved. "Last checked" is when it last heard from us,
/// which a forecast that arrived later can't contradict.
enum OfflineCopy {
    /// Flights list: "Offline. Showing what's saved on this phone, last checked 2:20 PM."
    static func banner(_ note: ConnectionNote, checkedAt: Date?) -> String? {
        guard let lead = lead(note, list: true) else { return nil }
        guard let checkedAt else { return "\(lead) Showing what's saved on this phone." }
        return "\(lead) Showing what's saved on this phone, last checked \(time(checkedAt))."
    }

    /// One flight: "Offline · saved forecast, last checked 2:20 PM"
    static func detail(_ note: ConnectionNote, checkedAt: Date?) -> String? {
        guard let lead = lead(note, list: false) else { return nil }
        guard let checkedAt else { return "\(lead) · showing what's saved on this phone" }
        return "\(lead) · saved forecast, last checked \(time(checkedAt))"
    }

    /// The later of the last sync and the newest forecast: a forecast on the phone was fetched after
    /// it was made, so the phone heard from us at least that recently.
    static func lastChecked(syncedAt: Date?, issued: [Date?]) -> Date? {
        ([syncedAt] + issued).compactMap { $0 }.max()
    }

    private static func lead(_ note: ConnectionNote, list: Bool) -> String? {
        switch note {
        case .none: nil
        case .offline: list ? "Offline." : "Offline"
        case .notOnline: list ? "Connected, but not reaching the internet." : "Not reaching the internet"
        case .syncFailed: list ? "Couldn't update just now." : "Couldn't update just now"
        }
    }

    /// A landing rating kept on the phone until it can be sent.
    static let reportPending = "We'll send your answer when you're back online."

    /// "2:20 PM" today, else "Thu 2:20 PM".
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

extension Forecast {
    /// Where the flight is against the forecast, for the in-flight card and the next-flight card.
    /// "Light chop now, about 4 min to go" · "Next: moderate bumps in about 6 min, for about 27 min" ·
    /// "Smooth to landing". Outlook stretches stay approximate: "Next: bumps possible in about 30 min".
    func progressLine(minute: Int, departure: Date) -> String {
        if let current = segments.first(where: { $0.startMin <= minute && minute <= $0.endMin }) {
            if isOutlook(current, departure: departure) { return "Bumps possible now" }
            return "\(current.severity.phrase.sentenceCased) now, about \((current.endMin - minute + 1).durationText) to go"
        }
        if let next = segments.first(where: { $0.startMin > minute }) {
            let wait = next.startMin - minute
            if isOutlook(next, departure: departure) { return "Next: bumps possible in about \(wait.roughMinutes.durationText)" }
            return "Next: \(next.severity.phrase) in about \(wait.durationText), for about \(next.minutes.durationText)"
        }
        return InFlightCopy.clearToLanding(outlook: isGlobalOutlook)
    }
}

extension Int {
    /// 95 -> "1 h 35 min"
    var durationText: String {
        let h = self / 60, m = self % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// A point in the flight, minutes zero-padded once there are hours: 125 -> "2 h 05 min", 70 -> "1 h 10 min".
    var clockText: String {
        let h = self / 60, m = self % 60
        return h == 0 ? "\(m) min" : "\(h) h \(String(format: "%02d", m)) min"
    }

    /// Outlook times are approximate: the nearest 10 min under an hour, the nearest 30 min above.
    var roughMinutes: Int {
        self < 60 ? Swift.max(10, (self + 5) / 10 * 10) : (self + 15) / 30 * 30
    }
}
