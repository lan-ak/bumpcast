import Foundation

/// Finds the messages that look like flight bookings, never the whole mailbox, and fetches them
/// one at a time so the first scan can say how far it's got. Nothing from a message leaves the
/// phone: the caller parses it here and keeps only the candidates and the message id.
struct MailScanner: Sendable {
    /// Booking words for the subject, and airline and travel-agency sender domains.
    static let subjectTerms = ["itinerary", "confirmation", "e-ticket", "\"boarding pass\"", "booking", "reservation", "trip"]
    static let senderDomains = [
        "aa.com", "united.com", "delta.com", "jetblue.com", "southwest.com", "alaskaair.com", "aircanada.ca",
        "aircanada.com", "westjet.com", "porterairlines.com", "flyfrontier.com", "spirit.com", "hawaiianairlines.com",
        "britishairways.com", "ba.com", "lufthansa.com", "airfrance.fr", "klm.com", "emirates.com", "qatarairways.com",
        "easyjet.com", "ryanair.com", "aeromexico.com", "flyporter.com", "expedia.com", "booking.com", "kayak.com",
        "priceline.com", "orbitz.com", "travelocity.com", "hopper.com", "flighthub.com", "trip.com",
    ]
    /// Ids listed per scan at most (ids only; each message is fetched on its own).
    static let listLimit = 500

    /// The booking messages not read yet, newest first. Graph returns bodies with the list, so
    /// those are kept here and not fetched again.
    struct Inbox: Sendable {
        let ids: [String]
        var prefetched: [String: MailMessage] = [:]
    }

    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func unread(provider: MailProvider, token: String, processed: Set<String>, now: Date = .now) async throws -> Inbox {
        switch provider {
        case .google: try await gmailIDs(token: token, processed: processed)
        case .microsoft: try await graph(token: token, processed: processed, now: now)
        }
    }

    func message(_ id: String, in inbox: Inbox, provider: MailProvider, token: String) async throws -> MailMessage {
        if let message = inbox.prefetched[id] { return message }
        let message: GmailMessage = try await get(
            URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!, token: token)
        return message.mail
    }

    // MARK: Gmail

    static var gmailQuery: String {
        let subjects = subjectTerms.joined(separator: " OR ")
        let senders = senderDomains.joined(separator: " OR ")
        return "newer_than:365d -in:spam -in:trash -category:promotions (subject:(\(subjects)) OR from:(\(senders)))"
    }

    private func gmailIDs(token: String, processed: Set<String>) async throws -> Inbox {
        struct List: Decodable {
            struct Item: Decodable { let id: String }
            let messages: [Item]?
            let nextPageToken: String?
        }
        var ids: [String] = []
        var page: String?
        repeat {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            components.queryItems = [.init(name: "q", value: Self.gmailQuery), .init(name: "maxResults", value: "500")]
            if let page { components.queryItems?.append(.init(name: "pageToken", value: page)) }
            let list: List = try await get(components.url!, token: token)
            ids += (list.messages ?? []).map(\.id).filter { !processed.contains($0) }
            page = list.nextPageToken
        } while page != nil && ids.count < Self.listLimit
        return Inbox(ids: Array(ids.prefix(Self.listLimit)))
    }

    private struct GmailMessage: Decodable {
        struct Part: Decodable {
            struct Header: Decodable { let name: String; let value: String }
            struct Body: Decodable { let data: String? }
            let mimeType: String?
            let headers: [Header]?
            let body: Body?
            let parts: [Part]?
        }
        let id: String
        let internalDate: String?
        let payload: Part?

        var mail: MailMessage {
            var html: String?
            var text: String?
            func walk(_ part: Part) {
                if let data = part.body?.data, let decoded = Data(base64URLEncoded: data) {
                    let string = String(data: decoded, encoding: .utf8) ?? String(data: decoded, encoding: .isoLatin1)
                    if part.mimeType == "text/html", html == nil { html = string }
                    if part.mimeType == "text/plain", text == nil { text = string }
                }
                part.parts?.forEach(walk)
            }
            payload.map(walk)
            let subject = payload?.headers?.first { $0.name.lowercased() == "subject" }?.value ?? ""
            let received = internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
            return MailMessage(id: id, subject: subject, html: html, text: text, received: received)
        }
    }

    // MARK: Microsoft Graph

    private func graph(token: String, processed: Set<String>, now: Date) async throws -> Inbox {
        // Junk and Deleted Items are skipped, like spam and trash on Gmail.
        struct Folder: Decodable { let id: String }
        var skipped: Set<String> = []
        for name in ["junkemail", "deleteditems"] {
            if let folder: Folder = try? await get(URL(string: "https://graph.microsoft.com/v1.0/me/mailFolders/\(name)")!, token: token) {
                skipped.insert(folder.id)
            }
        }
        let since = (Calendar(identifier: .gregorian).date(byAdding: .day, value: -365, to: now) ?? now)
            .formatted(.iso8601.year().month().day())
        let subjects = Self.subjectTerms.map { "subject:\($0.replacingOccurrences(of: "\"", with: "").split(separator: " ").first ?? "")" }
        let senders = Self.senderDomains.map { "from:\($0)" }
        let search = "\"(\((subjects + senders).joined(separator: " OR "))) AND received>=\(since)\""
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
        components.queryItems = [
            .init(name: "$search", value: search),
            .init(name: "$select", value: "id,subject,receivedDateTime,body,parentFolderId"),
            .init(name: "$top", value: "250"),
        ]
        struct List: Decodable {
            struct Item: Decodable {
                struct Body: Decodable { let contentType: String?; let content: String? }
                let id: String
                let subject: String?
                let receivedDateTime: Date?
                let body: Body?
                let parentFolderId: String?
            }
            let value: [Item]
        }
        let list: List = try await get(components.url!, token: token)
        var inbox = Inbox(ids: [])
        var ids: [String] = []
        for item in list.value where !processed.contains(item.id) && !skipped.contains(item.parentFolderId ?? "") {
            let isHTML = item.body?.contentType?.lowercased() == "html"
            ids.append(item.id)
            inbox.prefetched[item.id] = MailMessage(
                id: item.id, subject: item.subject ?? "", html: isHTML ? item.body?.content : nil,
                text: isHTML ? nil : item.body?.content, received: item.receivedDateTime ?? now)
        }
        return Inbox(ids: ids, prefetched: inbox.prefetched)
    }

    // MARK: Requests

    private func get<T: Decodable>(_ url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Access removed or expired for good; a 403 is usually a rate limit, tried on the next scan.
        if status == 401 { throw MailError.signedOut }
        guard (200..<300).contains(status) else { throw MailError.failed }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
