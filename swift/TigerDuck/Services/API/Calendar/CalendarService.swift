import Foundation

enum CalendarService {

    private static let calendarPageURL = URL(string: "https://r.xinshou.tw/ntust-calender")!

    private static let linkRegex = try! NSRegularExpression(
        pattern: "<a[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let yearRegex = try! NSRegularExpression(pattern: "(\\d{3})")

    /// URLSession with browser-like User-Agent (NTUST server returns 403 without one)
    private static let browserSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": NTUSTSessionManager.browserUserAgent
        ]
        return URLSession(configuration: config)
    }()

    /// Fetch NTUST academic calendar ICS download URLs (public, no auth)
    /// Returns mapping of ROC year → ICS URL
    static func fetchCalendarURLs() async throws -> [Int: URL] {
        let (data, response) = try await browserSession.data(from: calendarPageURL)
        guard let html = String(data: data, encoding: .utf8),
              let baseURL = (response as? HTTPURLResponse)?.url ?? Optional(calendarPageURL) else {
            return [:]
        }

        var result: [Int: URL] = [:]
        let matches = linkRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { continue }

            let href = String(html[hrefRange])
            let rawText = String(html[textRange])
            // Strip HTML tags to get plain text (e.g. <span>114學年度</span> → 114學年度)
            let text = rawText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

            guard href.lowercased().hasSuffix(".ics") else { continue }

            if let yearMatch = yearRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let yearRange = Range(yearMatch.range(at: 1), in: text),
               let year = Int(text[yearRange]) {
                if let url = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                    result[year] = url
                }
            }
        }

        return result
    }

    /// Current ROC academic year (e.g. 114 for 2025-2026)
    private static var currentROCYear: Int {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now) - 1911
        let month = cal.component(.month, from: now)
        // Academic year starts in August
        return month >= 8 ? year : year - 1
    }

    /// Fetch the current academic year's ICS file, parse it into calendar events
    static func fetchAndParseICS() async -> [SDCalendarEvent] {
        do {
            let urls = try await fetchCalendarURLs()
            guard let icsURL = urls[currentROCYear] else { return [] }

            let (data, _) = try await browserSession.data(from: icsURL)
            guard let icsString = String(data: data, encoding: .utf8) else { return [] }

            return parseICS(icsString)
        } catch {
            AppLogger.captureError(error, context: [
                "service": "calendarFetchAndParseICS",
                "rocYear": String(currentROCYear),
            ])
            return []
        }
    }

    /// Parse ICS string into SDCalendarEvent array
    private static func parseICS(_ ics: String) -> [SDCalendarEvent] {
        // Unfold ICS line continuations (lines starting with space or tab are continuations)
        let unfolded = ics
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")

        var events: [SDCalendarEvent] = []
        let lines = unfolded.components(separatedBy: .newlines)

        var inEvent = false
        var summary: String?
        var dtStart: Date?
        var dtEnd: Date?
        var uid: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed == "BEGIN:VEVENT" {
                inEvent = true
                summary = nil; dtStart = nil; dtEnd = nil; uid = nil
            } else if trimmed == "END:VEVENT" {
                if let title = summary, let start = dtStart {
                    let eventId = uid ?? "school-\(title)-\(start.timeIntervalSince1970)"

                    if let end = dtEnd, !Calendar.current.isDate(start, inSameDayAs: end.addingTimeInterval(-1)) {
                        // Multi-day event: create one event per day
                        var current = start
                        let lastDay = end.addingTimeInterval(-1) // ICS DTEND is exclusive
                        while current <= lastDay {
                            events.append(SDCalendarEvent(
                                eventId: "\(eventId)-\(current.startOfDay.timeIntervalSince1970)",
                                title: title,
                                date: current,
                                source: .school
                            ))
                            current = Calendar.current.date(byAdding: .day, value: 1, to: current)!
                        }
                    } else {
                        events.append(SDCalendarEvent(
                            eventId: eventId,
                            title: title,
                            date: start,
                            source: .school
                        ))
                    }
                }
                inEvent = false
            } else if inEvent {
                if trimmed.hasPrefix("SUMMARY:") {
                    summary = String(trimmed.dropFirst("SUMMARY:".count))
                } else if trimmed.hasPrefix("DTSTART") {
                    dtStart = parseICSDate(trimmed)
                } else if trimmed.hasPrefix("DTEND") {
                    dtEnd = parseICSDate(trimmed)
                } else if trimmed.hasPrefix("UID:") {
                    uid = String(trimmed.dropFirst("UID:".count))
                }
            }
        }

        return events
    }

    private static let icsDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        return f
    }()

    private static let icsDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        return f
    }()

    private static let icsDateTimeZ: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Parse ICS date formats: DTSTART;VALUE=DATE:20250901 or DTSTART:20250901T080000Z
    private static func parseICSDate(_ line: String) -> Date? {
        guard let colonIndex = line.lastIndex(of: ":") else { return nil }
        let value = String(line[line.index(after: colonIndex)...])
        return icsDateTimeZ.date(from: value)
            ?? icsDateTime.date(from: value)
            ?? icsDateOnly.date(from: value)
    }
}
