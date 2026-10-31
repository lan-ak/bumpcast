import CryptoKit
import Foundation

/// One email, as the phone reads it. Only ever held in memory while it's parsed.
struct MailMessage: Sendable {
    let id: String
    let subject: String
    let html: String?
    let text: String?
    let received: Date
}

/// A flight found in a booking: what the shared seam hands to flight search (BOOKING_IMPORT.md).
/// `day` is the local departure date, the way flight search wants it; airports are hints.
struct BookingCandidate: Codable, Hashable, Sendable {
    var number: String  // "B6 23"
    var day: String  // "2026-10-22"
    /// Local departure time ("07:15") when the booking gave one: used for a flight saved before
    /// its schedule is published.
    var time: String? = nil
    var origin: String? = nil  // IATA
    var destination: String? = nil  // IATA
    var cancelled = false
    /// Salted SHA-256 of the booking reference, to link later emails. Never the reference itself.
    var bookingHash: String? = nil

    /// Number and local day: how imports are matched against saved and dismissed flights.
    var key: String { "\(number)|\(day)" }
}

/// Finds flights in a booking email, on the phone: schema.org FlightReservation (JSON-LD, then
/// microdata), else a text heuristic. Loose on purpose: flight search validates every candidate.
enum BookingParser {
    /// Schedules are rarely out further than this, and older bookings are history.
    static let maxDaysAhead = 330

    /// `isAirport` checks an IATA code; the text fallback only takes airports it knows.
    static func candidates(
        in message: MailMessage, now: Date = .now, timeZone: TimeZone = .current, salt: String = "",
        isAirport: (String) -> Bool = { AirportStore.shared.airport($0)?.iata == $0 }
    ) -> [BookingCandidate] {
        var found: [BookingCandidate] = []
        if let html = message.html {
            found = jsonLD(in: html).compactMap { reservation($0, salt: salt) }
            if found.isEmpty { found = microdata(in: html).compactMap { reservation($0, salt: salt) } }
        }
        if found.isEmpty {
            let plain = message.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let text = plain ?? message.html.map(stripTags) ?? ""
            found = fromText(text, subject: message.subject, salt: salt, isAirport: isAirport)
        }
        return dedupe(found.filter { inWindow($0.day, now: now, timeZone: timeZone) })
    }

    // MARK: schema.org

    /// Every object in the page's JSON-LD blocks, flattened through arrays and @graph.
    static func jsonLD(in html: String) -> [[String: Any]] {
        let pattern = /(?is)<script[^>]*type\s*=\s*["']?application\/ld\+json["']?[^>]*>(.*?)<\/script>/
        var objects: [[String: Any]] = []
        func walk(_ value: Any) {
            if let array = value as? [Any] {
                array.forEach(walk)
            } else if let object = value as? [String: Any] {
                if let graph = object["@graph"] { walk(graph) }
                objects.append(object)
            }
        }
        for match in html.matches(of: pattern) {
            let body = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            walk(json)
        }
        return objects
    }

    /// One FlightReservation, from JSON-LD or microdata (same shape).
    private static func reservation(_ object: [String: Any], salt: String) -> BookingCandidate? {
        guard isType(object["@type"], "FlightReservation") else { return nil }
        let flight = first(object["reservationFor"]) ?? [:]
        let airline = first(flight["airline"]) ?? first(flight["provider"])
        guard let raw = string(flight["flightNumber"]) else { return nil }
        // "23" with the airline's code, or a number that already carries it ("B6 23").
        let carried = raw.contains(where: \.isLetter) ? FlightNumber.normalize(raw) : nil
        guard let number = carried ?? string(airline?["iataCode"]).flatMap({ FlightNumber.normalize($0 + raw) }),
            let departure = string(flight["departureTime"]) ?? string(object["departureTime"]),
            let local = localDate(departure)
        else { return nil }
        let status = string(object["reservationStatus"]) ?? ""
        return BookingCandidate(
            number: number, day: local.day, time: local.time,
            origin: string(first(flight["departureAirport"])?["iataCode"])?.uppercased(),
            destination: string(first(flight["arrivalAirport"])?["iataCode"])?.uppercased(),
            cancelled: status.localizedCaseInsensitiveContains("cancel"),
            bookingHash: string(object["reservationNumber"]).map { hash($0, salt: salt) })
    }

    /// Microdata FlightReservation scopes, read into the same shape as JSON-LD: nested itemscopes
    /// become objects, and `itemprop` values come from `content` (meta) or `href` (link).
    static func microdata(in html: String) -> [[String: Any]] {
        guard html.range(of: "FlightReservation", options: .caseInsensitive) != nil else { return [] }
        let voids: Set<String> = ["meta", "link", "br", "img", "input", "hr", "col", "source", "wbr", "area", "base"]
        var stack: [(tag: String, scope: MicrodataScope?)] = []
        var roots: [MicrodataScope] = []
        func current() -> MicrodataScope? { stack.last(where: { $0.scope != nil })?.scope }
        for match in html.matches(of: /<(\/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>/) {
            let tag = match.2.lowercased()
            if !match.1.isEmpty {
                if let index = stack.lastIndex(where: { $0.tag == tag }) { stack.removeSubrange(index...) }
                continue
            }
            let attributes = attributes(String(match.3))
            let property = attributes["itemprop"]
            var scope: MicrodataScope?
            if attributes.keys.contains("itemscope") {
                let new = MicrodataScope()
                if let type = attributes["itemtype"] { new.properties["@type"] = type }
                if let property, let parent = current() {
                    parent.properties[property] = new
                } else if (attributes["itemtype"] ?? "").hasSuffix("FlightReservation") {
                    roots.append(new)
                }
                scope = new
            } else if let property, let value = attributes["content"] ?? attributes["href"] ?? attributes["datetime"] {
                current()?.properties[property] = value
            }
            if !voids.contains(tag) && !match.3.hasSuffix("/") { stack.append((tag, scope)) }
        }
        return roots.map(\.object)
    }

    private final class MicrodataScope {
        var properties: [String: Any] = [:]
        var object: [String: Any] { properties.mapValues { ($0 as? MicrodataScope)?.object ?? $0 } }
    }

    private static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in text.matches(of: /([a-zA-Z_:\-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>\/]+)))?/) {
            result[match.1.lowercased()] = decodeEntities(String(match.2 ?? match.3 ?? match.4 ?? ""))
        }
        return result
    }

    // MARK: Text fallback

    /// Flight numbers with a reason to believe them: a context word (Flight, Flt, Vol) just
    /// before, or a time nearby. Gate, seat and terminal numbers and booking codes are skipped.
    /// Each takes the nearest date before it (else one just after), and airports from its route.
    static func fromText(
        _ raw: String, subject: String, salt: String, isAirport: (String) -> Bool
    ) -> [BookingCandidate] {
        // Airline emails indent every line by a hundred spaces (Air Canada does): collapse
        // the padding so "nearby" means nearby in the reading.
        let text = raw.replacing(/[ \t\u{00A0}]+/, with: " ").replacing(/\s*\n\s*/, with: "\n")
        let dates = detectedDates(in: text)
        // Only the subject says cancelled: bodies often carry a cancellation policy.
        let cancelled = subject.range(of: #"cancel(l)?(ed|ation)"#, options: [.regularExpression, .caseInsensitive]) != nil
        let reference = bookingReference(in: subject + "\n" + text).map { hash($0, salt: salt) }
        let tokens = text.matches(of: /\b([A-Z]{3}|[A-Z]{2}|[A-Z][0-9]|[0-9][A-Z])[ \-]?([0-9]{1,4})\b/)
        var found: [BookingCandidate] = []
        for (index, token) in tokens.enumerated() {
            let code = String(token.1)
            guard !stopCodes.contains(code) else { continue }
            // Part of a time or a decimal ("JFK 7:15").
            let after = text[token.range.upperBound...].prefix(2)
            if let next = after.first, ":.,/".contains(next), after.dropFirst().first?.isNumber == true { continue }
            let before = text[..<token.range.lowerBound].suffix(24).lowercased()
            if rejectWords.contains(where: { before.range(of: "\\b\($0)\\b[^a-z0-9]*$", options: .regularExpression) != nil }) {
                continue
            }
            // "AC 410 • Operated by Air Canada": the label comes after the number.
            let following = text[token.range.upperBound...].prefix(24).lowercased()
            let hasContext =
                contextWords.contains { before.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
                || following.range(of: #"^\W*operated by\b"#, options: .regularExpression) != nil
            // Itineraries list the times above the number: look well back, a little ahead.
            let nearStart = text.index(token.range.lowerBound, offsetBy: -160, limitedBy: text.startIndex) ?? text.startIndex
            let nearEnd = text.index(token.range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
            let hasTime = text[nearStart..<nearEnd].contains(/\b\d{1,2}[:h]\d{2}\b/)
            guard hasContext || hasTime, let number = FlightNumber.normalize(code + String(token.2)) else { continue }
            let offset = text.distance(from: text.startIndex, to: token.range.lowerBound)
            guard
                let date = dates.last(where: { $0.offset <= offset })
                    ?? dates.first(where: { $0.offset > offset && $0.offset - offset < 160 })
            else { continue }
            // This leg's stretch of text: from its date (when it heads the leg, as in "Flight 1 ·
            // Thu 19 Nov") or just before the number, up to the next flight number.
            let end = index + 1 < tokens.count ? tokens[index + 1].range.lowerBound : text.endIndex
            let previous = index > 0 ? tokens[index - 1].range.upperBound : text.startIndex
            let near = text.index(token.range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
            let dateStart = text.index(text.startIndex, offsetBy: date.offset)
            let start = date.offset <= offset && offset - date.offset < 600 ? max(dateStart, previous) : max(near, previous)
            let airports = route(in: String(text[start..<max(start, end)]), isAirport: isAirport)
            found.append(
                BookingCandidate(
                    number: number, day: date.day, time: date.time, origin: airports.origin,
                    destination: airports.destination, cancelled: cancelled, bookingHash: reference))
        }
        return found
    }

    private static let contextWords = ["flight", "flights", "flt", "vol", "vuelo", "flug", "volo", "voo"]
    private static let rejectWords = [
        "gate", "seat", "seats", "terminal", "term", "confirmation", "confirmation code", "confirmation number",
        "booking", "booking reference", "booking code", "reference", "ref", "record locator", "locator", "pnr",
        "code", "row", "zone", "group", "bag", "bags", "baggage", "carousel", "belt", "door", "class", "order",
        "ticket", "ticket number", "member", "account", "aircraft", "aircraft type", "type", "equipment",
        "airbus", "boeing", "embraer", "bombardier", "model",
    ]
    /// Uppercase words that look like an airline code next to a number.
    private static let stopCodes: Set<String> = [
        "AM", "PM", "TO", "AT", "ON", "IN", "OF", "NO", "BY", "OR", "UP", "ID", "OK", "MR", "MS", "DR", "TV", "GMT",
        "UTC", "EST", "EDT", "PST", "PDT", "CST", "CDT", "MST", "MDT", "BST", "CET", "USD", "CAD", "EUR", "GBP",
        "AUD", "JPY", "CHF", "MXN", "THE", "AND", "FOR", "ROW", "APT", "STE", "BOX", "ZIP",
    ]

    /// "JFK → LAX", "JFK to LAX", "(JFK) … (LAX)": the first two known airports, in order.
    private static func route(in text: String, isAirport: (String) -> Bool) -> (origin: String?, destination: String?) {
        for pair in text.matches(of: /\b([A-Z]{3})\s*(?:→|->|–|—|-|to|›|>)\s*([A-Z]{3})\b/)
        where isAirport(String(pair.1)) && isAirport(String(pair.2)) {
            return (String(pair.1), String(pair.2))
        }
        var codes: [String] = []
        for match in text.matches(of: /\(([A-Z]{3})\)/) where isAirport(String(match.1)) && !codes.contains(String(match.1)) {
            codes.append(String(match.1))
        }
        if codes.count >= 2 { return (codes[0], codes[1]) }
        // "Toronto YYZ … Montréal YUL": codes standing alone after the city name.
        codes = []
        for match in text.matches(of: /\b([A-Z]{3})\b/)
        where !stopCodes.contains(String(match.1)) && isAirport(String(match.1)) && !codes.contains(String(match.1)) {
            codes.append(String(match.1))
        }
        return (codes.first, codes.dropFirst().first)
    }

    private static func bookingReference(in text: String) -> String? {
        let pattern =
            /(?i)(?:confirmation|booking|reservation|record locator|pnr|reference)(?:\s+(?:code|number|no\.?|#|ref(?:erence)?))?\s*[:#]?\s*([A-Z0-9]{6})\b/
        return text.firstMatch(of: pattern).map { String($0.1).uppercased() }
    }

    /// Dates as written, with where they sit in the text. The detector reads them in the phone's
    /// time zone, so the calendar day and clock time come back out as written.
    private static func detectedDates(in text: String) -> [(offset: Int, day: String, time: String?)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let ns = text as NSString
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let date = match.date, let range = Range(match.range, in: text) else { return nil }
            // A time alone ("7:15 AM") reads as today: only written dates count.
            let hasDay = text[range].contains(/(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\d{1,4}[\/\-.]\d{1,2}/)
            guard hasDay else { return nil }
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let hasTime = text[range].contains(/\d{1,2}[:h.]\d{2}|\d\s?(?i:am|pm)\b/)
            return (
                text.distance(from: text.startIndex, to: range.lowerBound),
                String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
                hasTime ? String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) : nil
            )
        }
    }

    // MARK: Helpers

    /// The local date and time straight from an ISO string ("2026-11-12T07:15:00-05:00"), never
    /// converted to UTC: that's the airport's own day.
    static func localDate(_ iso: String) -> (day: String, time: String?)? {
        guard let match = iso.firstMatch(of: /^\s*(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/) else { return nil }
        let time = match.4.flatMap { hour in match.5.map { "\(hour):\($0)" } }
        return ("\(match.1)-\(match.2)-\(match.3)", time)
    }

    /// From today to `maxDaysAhead` days on.
    private static func inWindow(_ day: String, now: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let last = calendar.date(byAdding: .day, value: maxDaysAhead, to: now) ?? now
        return day >= now.searchDay(in: timeZone) && day <= last.searchDay(in: timeZone)
    }

    /// One per number and day: the first, with gaps filled in from repeats.
    private static func dedupe(_ candidates: [BookingCandidate]) -> [BookingCandidate] {
        var result: [BookingCandidate] = []
        for candidate in candidates {
            if let index = result.firstIndex(where: { $0.key == candidate.key }) {
                result[index].origin = result[index].origin ?? candidate.origin
                result[index].destination = result[index].destination ?? candidate.destination
                result[index].time = result[index].time ?? candidate.time
                result[index].cancelled = result[index].cancelled || candidate.cancelled
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    static func hash(_ reference: String, salt: String) -> String {
        let normalized = reference.uppercased().trimmingCharacters(in: .whitespaces)
        return SHA256.hash(data: Data((salt + normalized).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isType(_ value: Any?, _ type: String) -> Bool {
        if let list = value as? [Any] { return list.contains { isType($0, type) } }
        return (value as? String)?.hasSuffix(type) ?? false
    }

    private static func first(_ value: Any?) -> [String: Any]? {
        (value as? [String: Any]) ?? (value as? [Any])?.first as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        let text: String? =
            switch value {
            case let s as String: s
            case let n as NSNumber: n.stringValue
            default: nil
            }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The readable text of an HTML body: no styles or scripts, block ends as line breaks.
    static func stripTags(_ html: String) -> String {
        var text = html.replacing(/(?is)<style[^>]*>.*?<\/style>|<script[^>]*>.*?<\/script>|<head[^>]*>.*?<\/head>/, with: " ")
        text = text.replacing(/(?i)<br\s*\/?>|<\/(?:p|div|tr|li|h[1-6]|table)>/, with: "\n")
        text = text.replacing(/(?i)<\/(?:td|th)>/, with: " ")
        text = text.replacing(/<[^>]+>/, with: "")
        text = decodeEntities(text)
        text = text.replacing(/[ \t\u{00A0}]+/, with: " ")
        return text.replacing(/\n\s*\n+/, with: "\n")
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = [
            "&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&rarr;": "→",
            "&ndash;": "–", "&mdash;": "—",
        ]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value, options: .caseInsensitive) }
        result = result.replacing(/&#(x?)([0-9a-fA-F]+);/) { match in
            let value = UInt32(match.2, radix: match.1.isEmpty ? 10 : 16)
            return value.flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? ""
        }
        // Last, so "&amp;lt;" stays "&lt;".
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
