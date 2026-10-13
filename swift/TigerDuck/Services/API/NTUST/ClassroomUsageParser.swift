import Foundation
import SwiftSoup

/// What a room is doing in one period.
nonisolated enum RoomSlotUse: Equatable, Sendable {
    case free
    /// Lent through the booking system. The booker is a person, so the name is never kept.
    case booked
    case course(name: String, teacher: String)
}

/// One room's day: the use of each period, 1-10 then A-D.
nonisolated struct RoomUsage: Equatable, Sendable, Identifiable {
    let room: String
    let slots: [RoomSlotUse]

    var id: String { room }

    func isFree(at period: Int) -> Bool {
        slots.indices.contains(period) && slots[period] == .free
    }

    /// The last period of the free run that starts at `period`, or nil when the room is in use
    /// then.
    func freeUntil(from period: Int) -> Int? {
        guard isFree(at: period) else { return nil }
        var last = period
        while isFree(at: last + 1) { last += 1 }
        return last
    }
}

/// The main campus's rooms on one date, with the building names the site gives each code.
nonisolated struct CampusUsage: Equatable, Sendable {
    let rooms: [RoomUsage]
    let buildingNames: [String: String]
}

/// Reads cour01's room-use page, an ASP.NET WebForms page: the form state each postback sends
/// back, the date calendar's links, the room grid and its pager.
nonisolated enum ClassroomUsageParser {
    static let periodCount = 14
    static let campusField = "DropdownCampusListID"
    static let calendarTarget = "date_cal"

    struct Postback: Equatable, Sendable {
        let target: String
        let argument: String
    }

    struct Grid: Equatable, Sendable {
        let rooms: [RoomUsage]
        /// The page shown, which the pager writes without a link.
        let page: Int
        let pageLinks: [Int: Postback]
    }

    struct Page: Sendable {
        let fields: [FormField]
        /// Day numbers the calendar links, and the day numbers of the months it steps to.
        let calendarDays: Set<Int>
        let monthSteps: [Int]
        /// Nil when the page has no grid: a sign-in page, the bridge to one or an error page.
        let grid: Grid?
        let buildingNames: [String: String]

        /// The campus the page's list has chosen.
        var campus: String? {
            fields.first { $0.name == ClassroomUsageParser.campusField }?.value
        }
    }

    struct FormField: Equatable, Sendable {
        let name: String
        let value: String
    }

    static func isQueryPage(_ html: String) -> Bool {
        html.contains(campusField)
    }

    static func page(_ html: String) -> Page {
        guard let doc = try? SwiftSoup.parse(html) else {
            return Page(fields: [], calendarDays: [], monthSteps: [], grid: nil, buildingNames: [:])
        }
        let calendar = calendarLinks(in: doc)
        return Page(
            fields: formFields(in: doc),
            calendarDays: calendar.days,
            monthSteps: calendar.months,
            grid: grid(in: doc),
            buildingNames: buildingNames(in: doc)
        )
    }

    /// The calendar's argument for a date: days since 2000-01-01, counted in UTC so a time-zone
    /// offset cannot move it by a day.
    static func dayNumber(of date: Date, in calendar: Calendar = AppConstants.taipeiCalendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let day = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)),
              let epoch = utc.date(from: DateComponents(year: 2000, month: 1, day: 1)) else { return 0 }
        return utc.dateComponents([.day], from: epoch, to: day).day ?? 0
    }

    /// The postback that brings `day` closer: the day itself once the calendar links it, else
    /// the month step toward it. The site answers a day it does not link with an error page.
    static func calendarStep(toward day: Int, days: Set<Int>, monthSteps: [Int]) -> Postback? {
        if days.contains(day) {
            return Postback(target: calendarTarget, argument: String(day))
        }
        let step: Int?
        if let first = days.min(), let last = days.max() {
            step = day > last ? monthSteps.max() : day < first ? monthSteps.min() : nil
        } else {
            step = monthSteps.min { abs($0 - day) < abs($1 - day) }
        }
        return step.map { Postback(target: calendarTarget, argument: "V\($0)") }
    }

    // MARK: - Grid

    private static func grid(in doc: Document) -> Grid? {
        guard let table = try? doc.getElementById("showinfo_grd") else { return nil }
        let rows = directRows(of: table)
        // The first row heads the columns; the pager row has one cell, so the count skips it.
        let rooms = rows.dropFirst().compactMap { row -> RoomUsage? in
            let cells = row.children().array().filter { $0.tagName() == "td" }
            guard cells.count == periodCount + 1,
                  let name = try? cells[0].text(), !name.isEmpty else { return nil }
            return RoomUsage(room: name, slots: cells.dropFirst().map(slotUse))
        }
        let pager = pager(in: rows.last)
        return Grid(rooms: rooms, page: pager.page, pageLinks: pager.links)
    }

    /// Rows of the grid itself, not of the small table inside every cell.
    private static func directRows(of table: Element) -> [Element] {
        table.children().array().flatMap { child -> [Element] in
            switch child.tagName() {
            case "tr": return [child]
            case "tbody", "thead", "tfoot": return child.children().array().filter { $0.tagName() == "tr" }
            default: return []
            }
        }
    }

    /// A cell's own text, split where the site writes `</br>`, which the parser reads as `<br>`.
    /// A booking is told by its marker line, not by the cell colour, which the site puts on the
    /// wrong cells of a second page.
    private static func slotUse(_ cell: Element) -> RoomSlotUse {
        var parts = [""]
        for node in cell.getChildNodes() {
            if let text = node as? TextNode {
                parts[parts.count - 1] += text.getWholeText()
            } else if let element = node as? Element, element.tagName() == "br" {
                parts.append("")
            }
        }
        let lines = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return .free }
        if lines.contains(where: { line in bookingMarks.contains { line.contains($0) } }) {
            return .booked
        }
        return .course(name: first, teacher: lines.dropFirst().joined(separator: " "))
    }

    /// Parts of the words the site writes for a confirmed booking and a pending one.
    private static let bookingMarks = ["借用", "預約"]

    private static func pager(in row: Element?) -> (page: Int, links: [Int: Postback]) {
        guard let row else { return (1, [:]) }
        let cells = row.children().array()
        guard cells.count == 1, let cell = cells.first else { return (1, [:]) }
        var page = 1
        var links: [Int: Postback] = [:]
        for element in cell.children().array() {
            guard let number = Int((try? element.text()) ?? "") else { continue }
            if element.tagName() == "a", let postback = postback(in: element) {
                links[number] = postback
            } else if element.tagName() == "span" {
                page = number
            }
        }
        return (page, links)
    }

    // MARK: - Form

    private static func postback(in link: Element) -> Postback? {
        guard let href = try? link.attr("href"),
              let match = href.firstMatch(of: /__doPostBack\('([^']*)','([^']*)'\)/) else { return nil }
        return Postback(target: String(match.1), argument: String(match.2))
    }

    private static func calendarLinks(in doc: Document) -> (days: Set<Int>, months: [Int]) {
        let links = (try? doc.select("#\(calendarTarget) a[href]").array()) ?? []
        var days = Set<Int>()
        var months: [Int] = []
        for postback in links.compactMap(postback) where postback.target == calendarTarget {
            if postback.argument.hasPrefix("V"), let month = Int(postback.argument.dropFirst()) {
                months.append(month)
            } else if let day = Int(postback.argument) {
                days.insert(day)
            }
        }
        return (days, months)
    }

    /// What a browser would submit: every named input except buttons and unticked boxes, and
    /// each list's chosen option.
    private static func formFields(in doc: Document) -> [FormField] {
        guard let form = try? doc.select("form").first() else { return [] }
        var fields: [FormField] = []
        for input in (try? form.select("input").array()) ?? [] {
            guard let name = try? input.attr("name"), !name.isEmpty else { continue }
            let type = ((try? input.attr("type")) ?? "").lowercased()
            if ["submit", "button", "image", "reset"].contains(type) { continue }
            if ["checkbox", "radio"].contains(type), !input.hasAttr("checked") { continue }
            fields.append(FormField(name: name, value: (try? input.attr("value")) ?? ""))
        }
        for select in (try? form.select("select").array()) ?? [] {
            guard let name = try? select.attr("name"), !name.isEmpty else { continue }
            let options = (try? select.select("option").array()) ?? []
            let chosen = options.first { $0.hasAttr("selected") } ?? options.first
            fields.append(FormField(name: name, value: chosen.flatMap { try? $0.attr("value") } ?? ""))
        }
        return fields
    }

    private static func buildingNames(in doc: Document) -> [String: String] {
        let options = (try? doc.select("select[name=DropDownBuildingListID] option").array()) ?? []
        var names: [String: String] = [:]
        for option in options {
            guard let code = try? option.attr("value"), !code.isEmpty,
                  let name = try? option.text(), !name.isEmpty else { continue }
            names[code] = name
        }
        return names
    }
}
