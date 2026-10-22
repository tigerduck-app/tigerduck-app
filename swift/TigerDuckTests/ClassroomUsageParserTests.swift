import Foundation
import Testing
@testable import TigerDuck

enum ClassroomPageFixtures {
    static let header = "<tr align=\"center\"><td>教室</td>"
        + (1...14).map { "<td style=\"width:2.2cm;\">第\($0)節</td>" }.joined()
        + "</tr>"

    static func cell(_ text: String, row: Int = 3, column: Int = 2) -> String {
        """
        <td nowrap="nowrap" style="font-size:10pt;">
            <table id="showinfo_grd__ctl\(row)_Table\(column)" border="0" style="height:16px;width:80px;">
                <tr><td></td></tr>
            </table>
            \(text)
        </td>
        """
    }

    static let free = "</br>"
    static let booking = "林小美</br> 已借用"
    static let namelessBooking = "</br></br> 已借用"
    static func course(_ name: String, _ teacher: String) -> String { "\(name)</br>\(teacher)" }

    static func row(_ room: String, _ marks: String) -> String {
        let cells = marks.enumerated().map { index, mark -> String in
            switch mark {
            case "b": cell(booking, column: index + 2)
            case "c": cell(course("程式設計", "王大明"), column: index + 2)
            default: cell(free, column: index + 2)
            }
        }
        return "<tr nowrap=\"nowrap\"><td nowrap=\"nowrap\">\(room)                    </td>\(cells.joined())</tr>"
    }

    static func postback(_ target: String, _ argument: String) -> String {
        "javascript:__doPostBack(&#39;\(target)&#39;,&#39;\(argument)&#39;)"
    }

    static let firstOfTwoPages = "<tr align=\"left\"><td colspan=\"15\"><span>1</span>&nbsp;"
        + "<a href=\"\(postback("showinfo_grd$_ctl54$_ctl1", ""))\">2</a></td></tr>"
    static let secondOfTwoPages = "<tr align=\"left\"><td colspan=\"15\">"
        + "<a href=\"\(postback("showinfo_grd$_ctl42$_ctl0", ""))\">1</a>&nbsp;<span>2</span></td></tr>"
    static let onlyPage = "<tr align=\"left\"><td colspan=\"15\"><span>1</span></td></tr>"

    static let october = calendar(days: 9783...9807, months: [9740, 9801])
    static let november = calendar(days: 9794...9835, months: [9770, 9831])

    static func calendar(days: ClosedRange<Int>, months: [Int]) -> String {
        let steps = months.map { "<td><a href=\"javascript:__doPostBack('date_cal','V\($0)')\">&lt;</a></td>" }
        let links = days.map { "<td><a href=\"javascript:__doPostBack('date_cal','\($0)')\">\($0)</a></td>" }
        return "<table id=\"date_cal\" title=\"月曆\"><tr>\(steps.joined())</tr><tr>\(links.joined())</tr></table>"
    }

    static func page(
        rows: [String] = [],
        pager: String = onlyPage,
        calendar: String = october,
        campus: String = "HQ",
        viewState: String = "dGVzdA+/==",
        buildings: [(code: String, name: String)] = [("TR", "研揚大樓"), ("IB", "國際大樓")]
    ) -> String {
        func selected(_ code: String) -> String { code == campus ? " selected=\"selected\"" : "" }
        let buildingOptions = buildings.map { "<option value=\"\($0.code)\">\($0.name)</option>" }.joined()
        return """
        <html><head><title>教室使用狀況</title></head><body>
        <form name="Form2" method="post" action="./classroom_usecondition.aspx" id="Form2">
        <input type="hidden" name="__EVENTTARGET" id="__EVENTTARGET" value="" />
        <input type="hidden" name="__EVENTARGUMENT" id="__EVENTARGUMENT" value="" />
        <input type="hidden" name="__LASTFOCUS" id="__LASTFOCUS" value="" />
        <input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="\(viewState)" />
        <input type="hidden" name="__VIEWSTATEGENERATOR" id="__VIEWSTATEGENERATOR" value="A1B2C3D4" />
        <input type="hidden" name="__EVENTVALIDATION" id="__EVENTVALIDATION" value="ZXZlbnQ=" />
        <input type="submit" name="query_btn" value="查詢" />
        <select name="DropdownCampusListID" id="DropdownCampusListID">
          <option value="">請選擇校區</option><option\(selected("HHC")) value="HHC">華夏校區</option>
          <option\(selected("HQ")) value="HQ">校本部</option>
        </select>
        <select name="DropDownBuildingListID" id="DropDownBuildingListID">
          <option selected="selected" value="">請選擇大樓</option>
          \(buildingOptions)
        </select>
        \(calendar)
        <table cellspacing="0" rules="all" border="1" id="showinfo_grd">
        \(header)
        \(rows.joined(separator: "\n"))
        \(pager)
        </table>
        </form></body></html>
        """
    }

    static let signInPage = """
    <html><body><form id="loginForm" action="/account/login" method="post">
    <input name="Username" /><input name="Password" type="password" /></form></body></html>
    """

    static let errorPage = """
    <html><head><title>執行階段錯誤</title></head><body><h1>Server Error in '/' Application.</h1></body></html>
    """
}

struct ClassroomUsageParserTests {
    private typealias Pages = ClassroomPageFixtures

    @Test("a cell is free, a class with its teacher, or booked, and a booking keeps no name")
    func slotKinds() throws {
        let row = "<tr nowrap=\"nowrap\"><td nowrap=\"nowrap\">TR-214   </td>"
            + Pages.cell(Pages.course("線性代數（一）", "王大明"))
            + Pages.cell(Pages.booking)
            + Pages.cell(Pages.namelessBooking)
            + Pages.cell("工程數學</br>多位教師")
            + Pages.cell("林小美</br> 已預約")
            + Pages.cell("林小美</br> 確定借用")
            + String(repeating: Pages.cell(Pages.free), count: 8)
            + "</tr>"
        let grid = try #require(ClassroomUsageParser.page(Pages.page(rows: [row])).grid)

        let room = try #require(grid.rooms.first)
        #expect(room.room == "TR-214")
        #expect(Array(room.slots.prefix(7)) == [
            .course(name: "線性代數（一）", teacher: "王大明"),
            .booked,
            .booked,
            .course(name: "工程數學", teacher: "多位教師"),
            .booked,
            .booked,
            .free,
        ])
        #expect(room.slots.count == 14)
        #expect(!String(describing: grid).contains("林小美"))
    }

    @Test("a booking whose status is wrapped or worded otherwise still keeps no name")
    func otherBookings() throws {
        let row = "<tr nowrap=\"nowrap\"><td nowrap=\"nowrap\">TR-214   </td>"
            + Pages.cell("林小美</br><font color=\"red\">已借用</font>")
            + Pages.cell("<span>林小美</span></br><span>審核中</span>")
            + Pages.cell("林小美</br> 申請中")
            + Pages.cell("<font>微積分</font></br>王大明")
            + String(repeating: Pages.cell(Pages.free), count: 10)
            + "</tr>"
        let grid = try #require(ClassroomUsageParser.page(Pages.page(rows: [row])).grid)

        let room = try #require(grid.rooms.first)
        #expect(Array(room.slots.prefix(5)) == [
            .booked,
            .booked,
            .booked,
            .course(name: "微積分", teacher: "王大明"),
            .free,
        ])
        #expect(!String(describing: grid).contains("林小美"))
    }

    @Test("a grid whose rows changed shape is unreadable, not a day without rooms")
    func changedRows() throws {
        let wider = "<tr nowrap=\"nowrap\"><td nowrap=\"nowrap\">TR-214   </td><td>60</td>"
            + String(repeating: Pages.cell(Pages.free), count: 14)
            + "</tr>"
        #expect(ClassroomUsageParser.page(Pages.page(rows: [wider])).grid == nil)

        let message = "<tr><td colspan=\"15\">查無資料</td></tr>"
        let empty = try #require(ClassroomUsageParser.page(Pages.page(rows: [message])).grid)
        #expect(empty.rooms.isEmpty)
    }

    @Test("the rows between the header and the pager are rooms, in the page's order")
    func rooms() throws {
        let html = Pages.page(rows: [
            Pages.row("E1-306", "cc..b........."),
            Pages.row("TR-310-1", ".............."),
        ])
        let grid = try #require(ClassroomUsageParser.page(html).grid)

        #expect(grid.rooms.map(\.room) == ["E1-306", "TR-310-1"])
        #expect(grid.rooms[0].slots[4] == .booked)
        #expect(grid.rooms[0].freeUntil(from: 2) == 3)
        #expect(grid.rooms[0].freeUntil(from: 1) == nil)
        #expect(grid.rooms[1].freeUntil(from: 0) == 13)
    }

    @Test("the pager's targets are read from the page, and its unlinked number is the page shown")
    func pagerTargets() throws {
        let first = try #require(ClassroomUsageParser.page(Pages.page(
            rows: [Pages.row("E1-306", "..............")], pager: Pages.firstOfTwoPages
        )).grid)
        #expect(first.page == 1)
        #expect(first.pageLinks == [2: .init(target: "showinfo_grd$_ctl54$_ctl1", argument: "")])

        let second = try #require(ClassroomUsageParser.page(Pages.page(
            rows: [Pages.row("TR-617", "..............")], pager: Pages.secondOfTwoPages
        )).grid)
        #expect(second.page == 2)
        #expect(second.pageLinks == [1: .init(target: "showinfo_grd$_ctl42$_ctl0", argument: "")])
        #expect(second.rooms.map(\.room) == ["TR-617"])
    }

    @Test("a page without the grid is a failure, not an empty answer")
    func noGrid() {
        #expect(ClassroomUsageParser.page(Pages.signInPage).grid == nil)
        #expect(ClassroomUsageParser.page(Pages.errorPage).grid == nil)
        #expect(!ClassroomUsageParser.isQueryPage(Pages.errorPage))
    }

    @Test("a grid with no rows, as on a weekend, has no rooms")
    func emptyGrid() throws {
        let page = ClassroomUsageParser.page(Pages.page())
        let grid = try #require(page.grid)
        #expect(grid.rooms.isEmpty)
        #expect(grid.pageLinks.isEmpty)
        #expect(ClassroomUsageParser.isQueryPage(Pages.page()))
    }

    @Test("the form sends back its state and chosen options, but no button")
    func formFields() {
        let fields = ClassroomUsageParser.page(Pages.page()).fields
        let values = Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })

        #expect(values["__VIEWSTATE"] == "dGVzdA+/==")
        #expect(values["__EVENTVALIDATION"] == "ZXZlbnQ=")
        #expect(values["__EVENTTARGET"] == "")
        #expect(values["DropdownCampusListID"] == "HQ")
        #expect(values["DropDownBuildingListID"] == "")
        #expect(values["query_btn"] == nil)
        #expect(fields.count == 8)
        #expect(ClassroomUsageParser.page(Pages.page()).campus == "HQ")
        #expect(ClassroomUsageParser.page(Pages.page(campus: "HHC")).campus == "HHC")
    }

    @Test("buildings are named as the site names them")
    func buildingNames() {
        #expect(ClassroomUsageParser.page(Pages.page()).buildingNames == ["TR": "研揚大樓", "IB": "國際大樓"])
    }

    @Test("the calendar's day and month links are read apart")
    func calendarLinks() {
        let page = ClassroomUsageParser.page(Pages.page())
        #expect(page.calendarDays == Set(9783...9807))
        #expect(page.monthSteps.sorted() == [9740, 9801])
    }

    @Test("a date's number counts days from 2000-01-01 by its Taipei calendar date")
    func dayNumber() {
        func number(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Int {
            let date = AppConstants.taipeiCalendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour)
            )
            return ClassroomUsageParser.dayNumber(of: date ?? .distantPast)
        }
        #expect(number(2000, 1, 1) == 0)
        #expect(number(2000, 1, 2) == 1)
        #expect(number(2026, 10, 14) == 9783)
        #expect(number(2026, 10, 14, hour: 0) == 9783)
        #expect(number(2026, 10, 14, hour: 23) == 9783)
        #expect(number(2026, 11, 1) == 9801)
    }

    @Test("a linked day is posted at once, and a later or earlier one first steps the month toward it")
    func calendarStep() {
        func step(_ day: Int, days: Set<Int> = Set(9783...9807), months: [Int] = [9740, 9801]) -> String? {
            ClassroomUsageParser.calendarStep(toward: day, days: days, monthSteps: months)?.argument
        }
        #expect(step(9790) == "9790")
        #expect(step(9807) == "9807")
        #expect(step(9812) == "V9801")
        #expect(step(9812, days: Set(9794...9835), months: [9770, 9831]) == "9812")
        #expect(step(9789, days: Set(9794...9835), months: [9770, 9831]) == "V9770")
        #expect(step(9800, days: [], months: [9770, 9831]) == "V9770")
        #expect(step(9784, days: [9783, 9785]) == nil)
        #expect(ClassroomUsageParser.calendarStep(toward: 9790, days: Set(9783...9807), monthSteps: [9740, 9801])
            == .init(target: "date_cal", argument: "9790"))
    }
}
