import Foundation

enum CalendarService {

    private static let calendarPageURL = URL(string: "https://api.tigerduck.app/links/ntust-calendar")!

    private static let linkRegex = try! NSRegularExpression(
        pattern: "<a[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let yearRegex = try! NSRegularExpression(pattern: "(\\d{3})")

    /// URLSession with browser-like User-Agent (NTUST server returns 403 without one).
    /// Pinned because the backend's redirect and the ICS links on the page lead to
    /// *.ntust.edu.tw hosts the pin set covers; api.tigerduck.app itself has no pin set
    /// and gets system trust, so one session serves every host.
    private static let browserSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": NTUSTSessionManager.browserUserAgent
        ]
        return URLSession(
            configuration: config,
            delegate: TLSPinningDelegate.shared,
            delegateQueue: nil,
        )
    }()

    static func fetchCalendarURLs(session: URLSession, pageURL: URL) async throws -> [Int: URL] {
        let (data, response) = try await session.data(from: pageURL)
        guard let html = String(data: data, encoding: .utf8),
              let baseURL = (response as? HTTPURLResponse)?.url ?? Optional(pageURL) else {
            return [:]
        }

        var result: [Int: URL] = [:]
        let matches = linkRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { continue }

            let href = String(html[hrefRange])
            let rawText = String(html[textRange])
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

    nonisolated static func rocAcademicYear(at date: Date) -> Int {
        let calendar = AppConstants.taipeiCalendar
        let year = calendar.component(.year, from: date) - 1911
        return calendar.component(.month, from: date) >= 8 ? year : year - 1
    }

    static func fetchAndParseICS() async -> [SDCalendarEvent]? {
        await fetchAndParseICS(session: browserSession, pageURL: calendarPageURL, now: AppClock.now())
    }

    static func fetchAndParseICS(session: URLSession, pageURL: URL, now: Date) async -> [SDCalendarEvent]? {
        let rocYear = rocAcademicYear(at: now)
        do {
            let urls = try await fetchCalendarURLs(session: session, pageURL: pageURL)
            guard let icsURL = urls[rocYear] else { return nil }

            let (data, response) = try await session.data(from: icsURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let icsString = String(data: data, encoding: .utf8) else { return nil }

            let events = parseICS(icsString)
            return events.isEmpty ? nil : events
        } catch {
            AppLogger.captureError(error, context: [
                "service": "calendarFetchAndParseICS",
                "rocYear": String(rocYear),
            ])
            return nil
        }
    }

    static func parseICS(_ ics: String) -> [SDCalendarEvent] {
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
                if let title = summary.map(Self.unescapeICSText), let start = dtStart {
                    let eventId = (uid.map(Self.unescapeICSText))
                        ?? "school-\(title)-\(start.timeIntervalSince1970)"

                    if let end = dtEnd, !Self.icsCalendar.isDate(start, inSameDayAs: end.addingTimeInterval(-1)) {
                        var current = start
                        let lastDay = end.addingTimeInterval(-1) // ICS DTEND is exclusive
                        while current <= lastDay {
                            events.append(SDCalendarEvent(
                                eventId: "\(eventId)-\(Self.icsCalendar.startOfDay(for: current).timeIntervalSince1970)",
                                title: title,
                                date: current,
                                source: .school
                            ))
                            guard let next = Self.icsCalendar.date(byAdding: .day, value: 1, to: current) else {
                                break
                            }
                            current = next
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

    static let icsDateOnly = icsFormatter("yyyyMMdd", timeZone: TimeZone(identifier: "Asia/Taipei"))
    static let icsDateTime = icsFormatter("yyyyMMdd'T'HHmmss", timeZone: TimeZone(identifier: "Asia/Taipei"))
    static let icsDateTimeZ = icsFormatter("yyyyMMdd'T'HHmmss'Z'", timeZone: TimeZone(identifier: "UTC"))

    private static func icsFormatter(_ format: String, timeZone: TimeZone?) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        f.timeZone = timeZone
        return f
    }

    private static let icsCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        return cal
    }()

    /// Unescape ICS TEXT-typed values per RFC 5545:
    /// `\,` → `,`, `\;` → `;`, `\n` / `\N` → newline, `\\` → `\`.
    /// Without this, raw escape sequences leak into the UI as
    /// `Final Exam\, MA1`.
    nonisolated static func unescapeICSText(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var iter = raw.makeIterator()
        while let ch = iter.next() {
            if ch == "\\" {
                guard let next = iter.next() else {
                    out.append(ch)
                    break
                }
                switch next {
                case "n", "N": out.append("\n")
                case ",": out.append(",")
                case ";": out.append(";")
                case "\\": out.append("\\")
                default:
                    out.append("\\")
                    out.append(next)
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func parseICSDate(_ line: String) -> Date? {
        guard let colonIndex = line.lastIndex(of: ":") else { return nil }
        let value = String(line[line.index(after: colonIndex)...])
        let prefix = line[..<colonIndex]
        var localFormatter = icsDateTime
        if let tzidRange = prefix.range(of: "TZID=") {
            let tzidValue = prefix[tzidRange.upperBound...]
                .split(separator: ";")
                .first
                .map(String.init) ?? ""
            if !tzidValue.isEmpty, let tz = TimeZone(identifier: tzidValue) {
                localFormatter = icsFormatter("yyyyMMdd'T'HHmmss", timeZone: tz)
            }
        }
        if value.hasSuffix("Z") { return icsDateTimeZ.date(from: value) }
        return localFormatter.date(from: value) ?? icsDateOnly.date(from: value)
    }
}
