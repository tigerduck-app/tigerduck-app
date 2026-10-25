import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseSearchTests {
    private static func result(_ courseNo: String, _ name: String = "課程", node: String? = "M3") -> CourseSearchResult {
        CourseSearchResult(
            Semester: "1151", CourseNo: courseNo, CourseName: name, CourseTeacher: "王大明", Dimension: "",
            CreditPoint: "3", RequireOption: "R", AllYear: "H", ChooseStudent: 50, Restrict1: "0",
            Restrict2: "60", CourseTimes: "3", PracticalTimes: "0", ClassRoomNo: "TR-313", Node: node,
            Contents: ""
        )
    }

    /// Number, name, teacher and language, the fields that tell the rounds apart.
    private static func summary(_ request: CourseSearchRequest) -> String {
        "\(request.CourseNo)|\(request.CourseName)|\(request.CourseTeacher)|\(request.Language)"
    }

    private static func cache() -> DataCache {
        let root = FileManager.default.temporaryDirectory.appending(path: "CourseSearchTests-\(UUID().uuidString)")
        return DataCache(cacheDir: root.appending(path: "cache"), persistentDir: root.appending(path: "persistent"))
    }

    private static let noOptions: CourseSearchModel.FetchOptions = { @MainActor in CourseSearchOptions() }

    // MARK: Query planning

    @Test("letters and digits ask for a course-number prefix first, then name and teacher")
    func prefixThenNameAndTeacher() {
        let rounds = CourseSearch.rounds(for: "cs", semester: "1151", filters: .init())
        #expect(rounds.map { $0.map(Self.summary) } == [
            ["CS|||zh", "CS|||en"],
            ["|cs||zh", "||cs|zh", "|cs||en", "||cs|en"],
        ])
        #expect(rounds.joined().allSatisfy { $0.Semester == "1151" })
    }

    @Test("other text asks for name and teacher only, in traditional characters for zh")
    func textSkipsThePrefixRound() {
        let rounds = CourseSearch.rounds(for: "微积分", semester: "1151", filters: .init())
        #expect(rounds.map { $0.map(Self.summary) } == [
            ["|微積分||zh", "||微積分|zh", "|微积分||en", "||微积分|en"],
        ])
        #expect(CourseSearch.rounds(for: "EC 10", semester: "1151", filters: .init()).count == 1)
    }

    @Test("a department narrows the prefix, or replaces a round no course number can match")
    func departmentPrefix() {
        #expect(CourseSearch.courseNoPrefix("CS10", department: "cs") == "CS10")
        #expect(CourseSearch.courseNoPrefix("C", department: "CS") == "CS")
        #expect(CourseSearch.courseNoPrefix("EE", department: "CS") == nil)
        #expect(CourseSearch.courseNoPrefix("EE", department: nil) == "EE")

        var filters = CourseSearchFilters()
        filters.department = "CS"
        let rounds = CourseSearch.rounds(for: "EE", semester: "1151", filters: filters)
        #expect(rounds.map { $0.map(Self.summary) } == [
            ["CS|EE||zh", "CS||EE|zh", "CS|EE||en", "CS||EE|en"],
        ])
    }

    @Test("no request leaves every search field empty")
    func neverTheEmptyFilter() {
        for query in ["a", "1", "CS1001301", "王", "data structures"] {
            for request in CourseSearch.rounds(for: query, semester: "1151", filters: .init()).joined() {
                #expect(!(request.CourseNo + request.CourseName + request.CourseTeacher).isEmpty)
            }
        }
    }

    // MARK: Filters

    @Test("each server filter maps to its request field")
    func filterMapping() throws {
        func request(_ change: (inout CourseSearchFilters) -> Void) throws -> CourseSearchRequest {
            var filters = CourseSearchFilters()
            change(&filters)
            return try #require(CourseSearch.rounds(for: "CS", semester: "1151", filters: filters).first?.first)
        }
        let plain = try request { _ in }
        #expect(plain == .forCourseNo("CS", semester: "1151", language: "zh"))

        #expect(try request { $0.dimension = "A" }.Dimension == "A")
        #expect(try request { $0.generalOnly = true }.OnlyGeneral == 1)
        #expect(try request { $0.englishTaught = true }.CourseNotes == "eng")
        #expect(try request { $0.englishTaught = true }.ForeignLanguage == 0)
        #expect(try request { $0.intensiveOnly = true }.OnlyIntensive == 1)
        #expect(try request { $0.excludeAlliance = true }.OnleyNTUST == 1)
        let graduate = try request { $0.level = .graduate }
        #expect(graduate.OnlyMaster == 1 && graduate.OnlyUnderGraduate == 0)
        let undergraduate = try request { $0.level = .undergraduate }
        #expect(undergraduate.OnlyMaster == 0 && undergraduate.OnlyUnderGraduate == 1)
        #expect(try request { $0.department = "CS" }.CourseNo == "CS")
    }

    @Test("hide conflicts and periods stay on the device, and reset means every default")
    func deviceFilters() {
        var filters = CourseSearchFilters()
        #expect(filters.isDefault)
        filters.hideConflicts = false
        filters.periods = [CourseSlot(day: 1, period: "3")]
        #expect(!filters.isDefault)
        #expect(filters.requested == CourseSearchFilters())
        filters.generalOnly = true
        #expect(filters.requested != CourseSearchFilters())
    }

    @Test("a picked period range keeps only courses that meet inside it")
    func periodsFilter() {
        var filters = CourseSearchFilters()
        filters.hideConflicts = false
        filters.periods = [CourseSlot(day: 1, period: "3"), CourseSlot(day: 1, period: "4")]
        func shown(_ schedule: [Int: [String]]) -> Bool {
            CourseSearch.visibleConflicts(courseNo: "X", schedule: schedule, table: [], filters: filters) != nil
        }
        #expect(shown([1: ["3", "4"]]))
        #expect(shown([1: ["4"]]))
        #expect(!shown([1: ["4", "5"]]))
        #expect(!shown([:]))

        filters.periods = []
        #expect(shown([:]))
        #expect(shown([5: ["A"]]))
    }

    @Test("select free periods picks every grid period the timetable leaves free")
    func freePeriods() {
        let busy: Set = [CourseSlot(day: 2, period: "3"), CourseSlot(day: 7, period: "1")]
        let free = CourseSearch.freeSlots(busy: busy)
        #expect(free.count == 6 * AppConstants.Periods.chronologicalOrder.count - 1)
        #expect(!free.contains(CourseSlot(day: 2, period: "3")))
        #expect(free.contains(CourseSlot(day: 6, period: "D")))
    }

    // MARK: Conflicts

    @Test("a clash is hidden by default and named when hide conflicts is off")
    func conflicts() {
        let table = [
            CourseSearchTableCourse(courseNo: "CS2001301", name: "資料結構", slots: [CourseSlot(day: 2, period: "3")]),
            CourseSearchTableCourse(courseNo: "CS2002301", name: "計算機組織", slots: [CourseSlot(day: 2, period: "4")]),
        ]
        var filters = CourseSearchFilters()
        let clash = [2: ["3", "4"]]
        #expect(CourseSearch.visibleConflicts(courseNo: "MA1001301", schedule: clash, table: table, filters: filters) == nil)
        #expect(CourseSearch.visibleConflicts(courseNo: "MA1001301", schedule: [2: ["5"]], table: table, filters: filters) == [])

        filters.hideConflicts = false
        #expect(CourseSearch.visibleConflicts(courseNo: "MA1001301", schedule: clash, table: table, filters: filters)
            == ["資料結構", "計算機組織"])
    }

    @Test("a course already in the timetable is no conflict and stays listed")
    func addedCourseIsNoConflict() {
        let table = [
            CourseSearchTableCourse(courseNo: "CS2001301", name: "資料結構", slots: [CourseSlot(day: 2, period: "3")]),
            CourseSearchTableCourse(courseNo: "CS2002301", name: "計算機組織", slots: [CourseSlot(day: 2, period: "3")]),
        ]
        let filters = CourseSearchFilters()
        #expect(CourseSearch.visibleConflicts(courseNo: "CS2001301", schedule: [2: ["3"]], table: table, filters: filters) == [])
    }

    // MARK: Drag selection

    @Test("a drag that starts on an empty cell selects every cell it crosses")
    func dragSelects() {
        let a = CourseSlot(day: 1, period: "1"), b = CourseSlot(day: 1, period: "2"), c = CourseSlot(day: 1, period: "3")
        var picked: Set = [b]
        var drag = PeriodDrag()
        for slot in [a, b, c, b] {
            drag.touch(slot, in: &picked)
        }
        #expect(picked == [a, b, c])
    }

    @Test("a drag that starts on a selected cell clears every cell it crosses")
    func dragClears() {
        let a = CourseSlot(day: 1, period: "1"), b = CourseSlot(day: 1, period: "2"), c = CourseSlot(day: 2, period: "2")
        var picked: Set = [a, c]
        var drag = PeriodDrag()
        for slot in [a, b, c] {
            drag.touch(slot, in: &picked)
        }
        #expect(picked.isEmpty)

        var tap = PeriodDrag()
        tap.touch(b, in: &picked)
        #expect(picked == [b])
    }

    /// Cells 50 by 30 after a 28-point label column and a 24-point header.
    private static let grid = PeriodGridGeometry(origin: CGPoint(x: 28, y: 24), cell: CGSize(width: 50, height: 30))

    private static func center(column: Int, row: Int) -> CGPoint {
        CGPoint(x: 28 + 50 * CGFloat(column) + 25, y: 24 + 30 * CGFloat(row) + 15)
    }

    private static func slots(_ pairs: [(Int, String)]) -> [CourseSlot] {
        pairs.map { CourseSlot(day: $0.0, period: $0.1) }
    }

    @Test("a fast vertical drag crosses every period between two updates")
    func fastVerticalDrag() {
        let crossed = Self.grid.slots(from: Self.center(column: 0, row: 0), to: Self.center(column: 0, row: 5))
        #expect(crossed == Self.slots([(1, "1"), (1, "2"), (1, "3"), (1, "4"), (1, "5"), (1, "6")]))
        let back = Self.grid.slots(from: Self.center(column: 2, row: 13), to: Self.center(column: 2, row: 11))
        #expect(back == Self.slots([(3, "D"), (3, "C"), (3, "B")]))
    }

    @Test("a fast diagonal drag crosses the cells on its line")
    func fastDiagonalDrag() {
        let diagonal = Self.grid.slots(from: Self.center(column: 0, row: 0), to: Self.center(column: 3, row: 3))
        #expect(diagonal == Self.slots([(1, "1"), (2, "2"), (3, "3"), (4, "4")]))
        let shallow = Self.grid.slots(from: Self.center(column: 0, row: 0), to: Self.center(column: 2, row: 1))
        #expect(shallow == Self.slots([(1, "1"), (2, "1"), (2, "2"), (3, "2")]))
    }

    @Test("a drag from outside the grid crosses only the cells inside it")
    func dragFromOutside() {
        let crossed = Self.grid.slots(from: CGPoint(x: 5, y: 39), to: Self.center(column: 2, row: 0))
        #expect(crossed == Self.slots([(1, "1"), (2, "1"), (3, "1")]))
        #expect(Self.grid.slots(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 20, y: 10)).isEmpty)
    }

    @Test("a drag applies its first cell's choice to every cell between two far updates")
    func dragAppliesAlongTheLine() {
        var picked = Set(Self.slots([(1, "3")]))
        var drag = PeriodDrag()
        drag.move(to: Self.center(column: 0, row: 0), in: Self.grid, picked: &picked)
        drag.move(to: Self.center(column: 0, row: 4), in: Self.grid, picked: &picked)
        #expect(picked == Set(Self.slots([(1, "1"), (1, "2"), (1, "3"), (1, "4"), (1, "5")])))

        var clearing = PeriodDrag()
        clearing.move(to: Self.center(column: 0, row: 4), in: Self.grid, picked: &picked)
        clearing.move(to: Self.center(column: 0, row: 1), in: Self.grid, picked: &picked)
        #expect(picked == Set(Self.slots([(1, "1")])))
    }

    // MARK: Results

    @Test("the primary language's rows come first, with the other language's names beside them")
    func languagesMerge() {
        let results = [
            "zh": [Self.result("CS1001301", "計算機概論")],
            "en": [Self.result("CS1001301", "Introduction to Computers"), Self.result("CS1002301", "Data Structures")],
        ]
        let shown = CourseSearch.shown(results, primary: "zh")
        #expect(shown.rows.map(\.CourseNo) == ["CS1001301", "CS1002301"])
        #expect(shown.rows.map(\.CourseName) == ["計算機概論", "Data Structures"])
        #expect(shown.otherNames["CS1001301"] == "Introduction to Computers")
    }

    @Test("rows repeat only for another time slot of the same course")
    func mergeKeepsSlots() {
        let merged = CourseSearch.merge(
            [Self.result("CS1001301", node: "M3")],
            [Self.result("CS1001301", node: "M3"), Self.result("CS1001301", node: "W4")]
        )
        #expect(merged.map(\.Node) == ["M3", "W4"])
    }

    @Test("department search ignores case and matches codes and either name")
    func departmentSearch() {
        let colleges = [
            CourseSearchOptions.College(name: "電資學院", englishName: "EECS", departments: [
                .init(code: "CS", name: "資訊工程系", englishName: "Computer Science"),
                .init(code: "EE", name: "電機工程系", englishName: "Electrical Engineering"),
            ]),
            CourseSearchOptions.College(name: "管理學院", englishName: "Management", departments: [
                .init(code: "IM", name: "資訊管理系", englishName: "Information Management"),
            ]),
        ]
        #expect(CourseSearch.colleges(colleges, matching: "cs").flatMap(\.departments).map(\.code) == ["CS"])
        #expect(CourseSearch.colleges(colleges, matching: "資訊").flatMap(\.departments).map(\.code) == ["CS", "IM"])
        #expect(CourseSearch.colleges(colleges, matching: "ELECTRICAL").map(\.name) == ["電資學院"])
        #expect(CourseSearch.colleges(colleges, matching: " ") == colleges)
    }

    // MARK: Model

    @Test("an empty prefix round falls back to name and teacher once")
    func fallback() async {
        let sent = Box<[String]>([])
        let model = CourseSearchModel(cache: Self.cache(), search: { @MainActor request in
            sent.value.append(Self.summary(request))
            return request.CourseName.isEmpty ? [] : [Self.result("GE1001301")]
        }, fetchOptions: Self.noOptions)

        await model.search("calc", semester: "1151")

        #expect(Set(sent.value.prefix(2)) == ["CALC|||zh", "CALC|||en"])
        #expect(Set(sent.value.dropFirst(2)) == ["|calc||zh", "||calc|zh", "|calc||en", "||calc|en"])
        #expect(sent.value.count == 6)
        #expect(model.results["zh"]?.map(\.CourseNo) == ["GE1001301"])
        #expect(!model.isSearching)
        #expect(model.failure == nil)
    }

    @Test("a prefix that finds courses sends nothing more")
    func prefixHit() async {
        let sent = Box(0)
        let model = CourseSearchModel(cache: Self.cache(), search: { @MainActor _ in
            sent.value += 1
            return [Self.result("CS1001301")]
        }, fetchOptions: Self.noOptions)

        await model.search("CS", semester: "1151")
        #expect(sent.value == 2)
        #expect(model.results.keys.sorted() == ["en", "zh"])
    }

    @Test("a round that fails everywhere shows the error and stops; one answer is enough")
    func failures() async {
        let sent = Box(0)
        let failing = CourseSearchModel(cache: Self.cache(), search: { @MainActor _ in
            sent.value += 1
            throw URLError(.timedOut)
        }, fetchOptions: Self.noOptions)
        await failing.search("CS", semester: "1151")
        #expect(sent.value == 2)
        #expect((failing.failure as? URLError)?.code == .timedOut)

        let halfFailing = CourseSearchModel(cache: Self.cache(), search: { @MainActor request in
            if request.Language == "zh" { throw URLError(.timedOut) }
            return [Self.result("CS1001301")]
        }, fetchOptions: Self.noOptions)
        await halfFailing.search("CS", semester: "1151")
        #expect(halfFailing.failure == nil)
        #expect(halfFailing.results["en"]?.count == 1)
    }

    @Test("a new query drops the old rows and shows as searching before its wait ends")
    func newQueryClearsAtOnce() async {
        let model = CourseSearchModel(cache: Self.cache(), search: { @MainActor _ in
            [Self.result("CS1001301")]
        }, fetchOptions: Self.noOptions)
        await model.search("CS", semester: "1151")
        #expect(!model.results.isEmpty)

        let waiting = Task { await model.search("EE", semester: "1151", after: .seconds(60)) }
        for _ in 0..<10_000 where !model.results.isEmpty {
            await Task.yield()
        }
        #expect(model.results.isEmpty)
        #expect(model.isSearching)
        #expect(model.failure == nil)
        waiting.cancel()
        await waiting.value
    }

    @Test("a blank query sends nothing and clears the results")
    func blankQuery() async {
        let sent = Box(0)
        let model = CourseSearchModel(cache: Self.cache(), search: { @MainActor _ in
            sent.value += 1
            return [Self.result("CS1001301")]
        }, fetchOptions: Self.noOptions)
        await model.search("CS", semester: "1151")
        sent.value = 0

        await model.search(" \t ", semester: "1151")
        #expect(sent.value == 0)
        #expect(model.results.isEmpty)
        #expect(!model.isSearching)
        #expect(!model.hasSearched)
    }

    @Test("a failed request in the last round shows the error, not \"not found\"")
    func lastRoundFailure() async {
        let model = CourseSearchModel(cache: Self.cache(), search: { @MainActor request in
            guard request.Language == "zh", !request.CourseName.isEmpty else { throw URLError(.timedOut) }
            return []
        }, fetchOptions: Self.noOptions)
        await model.search("微積分", semester: "1151")
        #expect((model.failure as? URLError)?.code == .timedOut)
        #expect(!model.isSearching)
    }

    @Test("an empty answer beside a failure in the prefix round still falls back")
    func prefixRoundFailureFallsBack() async {
        let sent = Box(0)
        let model = CourseSearchModel(cache: Self.cache(), search: { @MainActor request in
            sent.value += 1
            if request.CourseNo == "CALC", request.Language == "zh" { throw URLError(.timedOut) }
            return []
        }, fetchOptions: Self.noOptions)
        await model.search("calc", semester: "1151")
        #expect(sent.value == 6)
        #expect(model.failure == nil)
        #expect(model.results.isEmpty)
    }

    @Test("each request's courses show while another request is still out")
    func showsEachAnswer() async {
        let gate = Gate()
        let model = CourseSearchModel(cache: Self.cache(), search: { @MainActor request in
            if request.Language == "zh" { await gate.wait() }
            return [Self.result("CS1001301")]
        }, fetchOptions: Self.noOptions)

        let search = Task { await model.search("CS1001301", semester: "1151") }
        for _ in 0..<10_000 where model.results["en"] == nil {
            await Task.yield()
        }
        #expect(model.results["en"]?.count == 1)
        #expect(model.results["zh"] == nil)
        #expect(model.isSearching)

        gate.open()
        await search.value
        #expect(model.results["zh"]?.count == 1)
        #expect(!model.isSearching)
    }

    @Test("a course only the other language found is added under its app-language row")
    func otherLanguageCourseIsLookedUp() async {
        let sent = Box<[String]>([])
        let model = CourseSearchModel(cache: Self.cache(), search: { @MainActor request in
            sent.value.append(Self.summary(request))
            if request.CourseNo == "MA1001301", request.Language == "zh" { return [Self.result("MA1001301", "微積分")] }
            return request.Language == "en" && !request.CourseName.isEmpty ? [Self.result("MA1001301", "Calculus")] : []
        }, fetchOptions: Self.noOptions)
        await model.search("Calculus", semester: "1151")
        sent.value = []

        let row = await model.appLanguageRow(of: "MA1001301", language: "zh", semester: "1151")
        #expect(row?.CourseName == "微積分")
        #expect(sent.value == ["MA1001301|||zh"])

        sent.value = []
        #expect(await model.appLanguageRow(of: "MA1001301", language: "en", semester: "1151")?.CourseName == "Calculus")
        #expect(sent.value.isEmpty)
    }

    @Test("a failed or empty lookup leaves the found row in place")
    func otherLanguageLookupFails() async {
        let answers = Box<[Result<[CourseSearchResult], URLError>]>([.failure(URLError(.timedOut)), .success([])])
        let model = CourseSearchModel(cache: Self.cache(), search: { @MainActor _ in
            try answers.value.removeFirst().get()
        }, fetchOptions: Self.noOptions)

        #expect(await model.appLanguageRow(of: "MA1001301", language: "zh", semester: "1151") == nil)
        #expect(await model.appLanguageRow(of: "MA1001301", language: "zh", semester: "1151") == nil)
        #expect(answers.value.isEmpty)
    }

    private static func lookupModel(gate: Gate) -> CourseSearchModel {
        CourseSearchModel(cache: Self.cache(), search: { @MainActor _ in
            await gate.wait()
            return [Self.result("MA1001301", "微積分")]
        }, fetchOptions: Self.noOptions)
    }

    @Test("an add waits for its lookup, and a second tap meanwhile does nothing")
    func addWaitsForLookup() async throws {
        let gate = Gate()
        let model = Self.lookupModel(gate: gate)
        let added = Box<[String?]>([])
        let task = try #require(model.add("MA1001301", language: "zh", semester: "1151", isCurrent: { true }) {
            added.value.append($0?.CourseName)
        })
        #expect(model.add("MA1001301", language: "zh", semester: "1151", isCurrent: { true }) { _ in } == nil)

        gate.open()
        await task.value
        #expect(added.value == ["微積分"])
    }

    @Test("an add whose lookup outlives the sign-in writes nothing")
    func addAfterSignOut() async throws {
        let gate = Gate()
        let model = Self.lookupModel(gate: gate)
        let generation = Box(1)
        let started = generation.value
        let added = Box(0)
        let task = try #require(model.add(
            "MA1001301", language: "zh", semester: "1151", isCurrent: { generation.value == started }
        ) { _ in added.value += 1 })

        generation.value += 1
        gate.open()
        await task.value
        #expect(added.value == 0)
    }

    @Test("closing the sheet drops an add still waiting for its lookup")
    func addAfterSheetCloses() async throws {
        let gate = Gate()
        let model = Self.lookupModel(gate: gate)
        let added = Box(0)
        let task = try #require(model.add("MA1001301", language: "zh", semester: "1151", isCurrent: { true }) { _ in
            added.value += 1
        })

        model.cancelPendingAdds()
        gate.open()
        await task.value
        #expect(added.value == 0)
    }

    // MARK: Option lists

    private static let stored = CourseSearchOptions(
        colleges: [.init(name: "電資學院", englishName: "EECS", departments: [
            .init(code: "CS", name: "資訊工程系", englishName: "Computer Science"),
        ])],
        dimensions: [.init(code: "A", name: "人文素養(A)", englishName: "Humanities and Thinking(A)")]
    )

    private static let fresh = CourseSearchOptions(
        colleges: [.init(name: "電資學院", englishName: "EECS", departments: [
            .init(code: "CS", name: "資訊工程系", englishName: "Computer Science"),
            .init(code: "EE", name: "電機工程系", englishName: "Electrical Engineering"),
        ])],
        dimensions: [.init(code: "B", name: "當代文明(B)", englishName: "Contemporary Civilization(B)")]
    )

    @Test("the stored lists show before the refresh, which then replaces and stores them once")
    func optionsRefresh() async {
        let cache = Self.cache()
        cache.saveCourseSearchOptions(Self.stored)
        let seenWhileFetching = Box<CourseSearchOptions?>(nil)
        let fetches = Box(0)
        let model = Box<CourseSearchModel?>(nil)
        model.value = CourseSearchModel(cache: cache, search: { _ in [] }, fetchOptions: { @MainActor in
            fetches.value += 1
            seenWhileFetching.value = model.value?.options
            return Self.fresh
        })

        await model.value?.refreshOptions()
        #expect(seenWhileFetching.value == Self.stored)
        #expect(model.value?.options == Self.fresh)
        #expect(cache.loadCourseSearchOptions() == Self.fresh)

        await model.value?.refreshOptions()
        #expect(fetches.value == 1)
    }

    @Test("a failed or empty refresh keeps the stored lists and tries again next time")
    func optionsRefreshFails() async {
        let cache = Self.cache()
        cache.saveCourseSearchOptions(Self.stored)
        let answers = Box<[CourseSearchOptions?]>([nil, CourseSearchOptions(), Self.fresh])
        let model = CourseSearchModel(cache: cache, search: { _ in [] }, fetchOptions: { @MainActor in
            guard let answer = answers.value.removeFirst() else { throw URLError(.notConnectedToInternet) }
            return answer
        })

        await model.refreshOptions()
        #expect(model.options == Self.stored)
        await model.refreshOptions()
        #expect(model.options == Self.stored)
        #expect(cache.loadCourseSearchOptions() == Self.stored)
        await model.refreshOptions()
        #expect(model.options == Self.fresh)
    }
}

@MainActor
private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
