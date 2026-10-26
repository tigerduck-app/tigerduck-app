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

    // MARK: Catalog

    private struct Row {
        let courseNo: String
        var name: String
        var teacher = ""
        var node = "M3"
        var dimension = ""
        var intensive = false
        var alliance = false
        var englishTaught = false

        var json: [String: Any] {
            [
                "Semester": "1151", "CourseNo": courseNo, "CourseName": name, "CourseTeacher": teacher,
                "Dimension": dimension, "CreditPoint": "3", "RequireOption": "R", "AllYear": "H",
                "ChooseStudent": 50, "Restrict1": "0", "Restrict2": "60", "CourseTimes": "3",
                "PracticalTimes": "0", "ClassRoomNo": "TR-313", "Node": node, "Contents": "",
                "IsIntensive": intensive, "IsAlliance": alliance, "IsEnglishTaught": englishTaught,
            ]
        }
    }

    /// A term in course-number order, as the backend sorts it. Courses differ in what one
    /// filter or one search looks at.
    private static let zhRows = [
        Row(courseNo: "3N1346703", name: "國文文法", teacher: "郭維茹", intensive: true, alliance: true),
        Row(courseNo: "CS1001301", name: "計算機概論", teacher: "王大明"),
        Row(courseNo: "CS1002301", name: "資料結構", teacher: "李小華"),
        Row(courseNo: "CS5101701", name: "深度學習", teacher: "陳明", englishTaught: true),
        Row(courseNo: "EE1001301", name: "微積分(上)", teacher: "黃意婷"),
        Row(courseNo: "GE1408301", name: "台灣文學", teacher: "林文", dimension: "A"),
        Row(courseNo: "MA160A001", name: "微積分", teacher: "周志隆", node: "R6"),
        Row(courseNo: "MA160A001", name: "微積分", teacher: "周志隆", node: "F2,F3"),
        Row(courseNo: "TCG051301", name: "藝術欣賞", teacher: "張美", dimension: "C"),
    ]

    private static let enNames = [
        "3N1346703": ("Chinese Grammar", "Wei-Ju Kuo"),
        "CS1001301": ("Introduction to Computers", "Da-Ming Wang"),
        "CS1002301": ("Data Structures", "Hsiao-Hua Li"),
        "CS5101701": ("Deep Learning", "Ming Chen"),
        "EE1001301": ("Calculus (I)", "Yi-Ting Huang"),
        "GE1408301": ("Taiwanese Literature", "Wen Lin"),
        "MA160A001": ("Calculus", "Chih-Lung Chou"),
        "TCG051301": ("Art Appreciation", "Mei Chang"),
    ]

    private static func rows(_ language: String) -> [Row] {
        guard language == "en" else { return zhRows }
        return zhRows.map { row in
            var row = row
            (row.name, row.teacher) = enNames[row.courseNo] ?? (row.name, row.teacher)
            return row
        }
    }

    /// The document `GET /v3/course-catalog/1151` sends.
    private static func body(_ language: String, rows: [Row]? = nil) throws -> Data {
        let english = language == "en"
        let document: [String: Any] = [
            "fetched_at": "2026-10-26T05:29:37Z", "semester": "1151", "language": language,
            "courses": (rows ?? Self.rows(language)).map(\.json),
            "colleges": [[
                "no": "2", "name": english ? "College of EECS" : "電資學院",
                "departments": [
                    ["no": "CS", "name": english ? "Computer Science" : "資訊工程系"],
                    ["no": "EE", "name": english ? "Electrical Engineering" : "電機工程系"],
                ],
            ]],
            "dimensions": [["no": "A", "name": english ? "Humanities and Thinking(A)" : "人文素養(A)"]],
        ]
        return try JSONSerialization.data(withJSONObject: document)
    }

    private static func catalog(_ language: String) throws -> CourseCatalog {
        try JSONDecoder().decode(CourseCatalog.self, from: body(language))
    }

    private static func search(
        _ query: String,
        _ change: (inout CourseSearchFilters) -> Void = { _ in }
    ) throws -> [String: [String]] {
        var filters = CourseSearchFilters()
        change(&filters)
        let catalogs = try ["zh": catalog("zh").courses, "en": catalog("en").courses]
        return CourseSearch.search(query, in: catalogs, filters: filters).mapValues { $0.map(\.CourseNo) }
    }

    // MARK: Local search

    @Test("letters and digits match a course-number prefix first, ignoring case")
    func prefixFirst() throws {
        #expect(try Self.search("cs10") == ["zh": ["CS1001301", "CS1002301"], "en": ["CS1001301", "CS1002301"]])
        // "Deep Learning" holds "ee" too, but a course number starts with it.
        #expect(try Self.search("ee") == ["zh": ["EE1001301"], "en": ["EE1001301"]])
        #expect(try Self.search("MA160A001") == ["zh": ["MA160A001", "MA160A001"], "en": ["MA160A001", "MA160A001"]])
    }

    @Test("letters and digits no course number starts with match the name and teacher")
    func alphanumericFallsBack() throws {
        #expect(try Self.search("data") == ["en": ["CS1002301"]])
        #expect(try Self.search("HUANG") == ["en": ["EE1001301"]])
    }

    @Test("other text matches the name and teacher, simplified characters as traditional in zh")
    func textMatchesNameAndTeacher() throws {
        #expect(try Self.search("微积分") == ["zh": ["EE1001301", "MA160A001", "MA160A001"]])
        #expect(try Self.search("黃意婷") == ["zh": ["EE1001301"]])
        #expect(try Self.search("deep learn") == ["en": ["CS5101701"]])
        #expect(try Self.search("calculus (") == ["en": ["EE1001301"]])
    }

    @Test("a department narrows the prefix, and a prefix outside it is matched as a name")
    func departmentAndPrefix() throws {
        let inCS = ["CS1001301", "CS1002301", "CS5101701"]
        #expect(try Self.search("c") { $0.department = "CS" } == ["zh": inCS, "en": inCS])
        #expect(try Self.search("ee") { $0.department = "CS" } == ["en": ["CS5101701"]])
        #expect(try Self.search("ma") { $0.department = "CS" }.isEmpty)
    }

    private static func admitted(_ change: (inout CourseSearchFilters) -> Void) throws -> [String] {
        var filters = CourseSearchFilters()
        change(&filters)
        return try catalog("zh").courses.filter { CourseSearch.admits($0, filters) }.map(\.row.CourseNo)
    }

    @Test("each filter keeps the courses the school's filter of that name returned")
    func filters() throws {
        let all = Self.zhRows.map(\.courseNo)
        #expect(try Self.admitted { _ in } == all)
        #expect(try Self.admitted { $0.department = "CS" } == ["CS1001301", "CS1002301", "CS5101701"])
        #expect(try Self.admitted { $0.level = .graduate } == ["CS5101701"])
        #expect(try Self.admitted { $0.level = .undergraduate } == all.filter { $0 != "CS5101701" })
        #expect(try Self.admitted { $0.dimension = "A" } == ["GE1408301"])
        #expect(try Self.admitted { $0.generalOnly = true } == ["GE1408301", "TCG051301"])
        #expect(try Self.admitted { $0.englishTaught = true } == ["CS5101701"])
        #expect(try Self.admitted { $0.intensiveOnly = true } == ["3N1346703"])
        #expect(try Self.admitted { $0.excludeAlliance = true } == all.filter { $0 != "3N1346703" })
        #expect(try Self.admitted {
            $0.department = "CS"
            $0.level = .undergraduate
        } == ["CS1001301", "CS1002301"])
    }

    @Test("the filter lists come from the catalog, with each name in both languages")
    func optionsFromCatalog() throws {
        let options = CourseSearch.options(try ["zh": Self.catalog("zh"), "en": Self.catalog("en")])
        #expect(options == CourseSearchOptions(
            colleges: [.init(name: "電資學院", englishName: "College of EECS", departments: [
                .init(code: "CS", name: "資訊工程系", englishName: "Computer Science"),
                .init(code: "EE", name: "電機工程系", englishName: "Electrical Engineering"),
            ])],
            dimensions: [.init(code: "A", name: "人文素養(A)", englishName: "Humanities and Thinking(A)")]
        ))
        #expect(CourseSearch.options([:]) == CourseSearchOptions())
    }

    // MARK: Filters

    @Test("hide conflicts and periods stay on the device, and reset means every default")
    func deviceFilters() {
        var filters = CourseSearchFilters()
        #expect(filters.isDefault)
        filters.hideConflicts = false
        filters.periods = [CourseSlot(day: 1, period: "3")]
        #expect(!filters.isDefault)
        #expect(filters.searched == CourseSearchFilters())
        filters.generalOnly = true
        #expect(filters.searched != CourseSearchFilters())
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

    private static func cache() -> DataCache {
        let root = FileManager.default.temporaryDirectory.appending(path: "CourseSearchTests-\(UUID().uuidString)")
        return DataCache(cacheDir: root.appending(path: "cache"), persistentDir: root.appending(path: "persistent"))
    }

    private static func stored(_ language: String, etag: String, rows: [Row]? = nil) throws -> StoredCourseCatalog {
        StoredCourseCatalog(body: try body(language, rows: rows), etag: etag)
    }

    /// A backend that logs each language and ETag it is asked with, waits for `gate`, then answers.
    private static func backend(
        _ sent: Box<[String]>,
        gate: Gate? = nil,
        answer: @escaping @MainActor (_ language: String) throws -> CourseCatalogClient.Answer
    ) -> CourseSearchModel.FetchCatalog {
        { @MainActor semester, language, etag in
            #expect(semester == "1151")
            sent.value.append("\(language) \(etag ?? "-")")
            await gate?.wait()
            return try answer(language)
        }
    }

    @Test("the stored catalog is searched before the backend answers; a 304 keeps it, a 200 replaces it")
    func storedCatalogFirst() async throws {
        let cache = Self.cache()
        let storedZh = try Self.stored("zh", etag: #"W/"zh1""#)
        cache.saveCourseCatalog(storedZh, semester: "1151", language: "zh")
        cache.saveCourseCatalog(try Self.stored("en", etag: #"W/"en1""#), semester: "1151", language: "en")
        let renamed = Self.rows("en").map { row in
            var row = row
            if row.courseNo == "CS1001301" { row.name = "Computing 101" }
            return row
        }
        let freshEn = try Self.stored("en", etag: #"W/"en2""#, rows: renamed)
        let sent = Box<[String]>([])
        let gate = Gate()
        let fetch = Self.backend(sent, gate: gate) { $0 == "zh" ? .notModified : .changed(freshEn) }
        let model = CourseSearchModel(cache: cache)

        await model.search("CS10", semester: "1151", fetch: fetch)
        #expect(model.results["zh"]?.map(\.CourseNo) == ["CS1001301", "CS1002301"])
        #expect(model.results["en"]?.first?.CourseName == "Introduction to Computers")
        #expect(model.options.dimensions.map(\.code) == ["A"])
        #expect(!model.isSearching)

        let revision = model.revision
        for _ in 0..<10_000 where sent.value.count < 2 {
            await Task.yield()
        }
        #expect(Set(sent.value) == [#"zh W/"zh1""#, #"en W/"en1""#])
        gate.open()
        for _ in 0..<10_000 where model.revision == revision {
            await Task.yield()
        }
        #expect(model.revision != revision)
        #expect(cache.loadCourseCatalog(semester: "1151", language: "zh") == storedZh)
        #expect(cache.loadCourseCatalog(semester: "1151", language: "en") == freshEn)

        await model.search("computing", semester: "1151", fetch: fetch)
        #expect(model.results.mapValues { $0.map(\.CourseNo) } == ["en": ["CS1001301"]])
        #expect(sent.value.count == 2)

        let nextSheet = CourseSearchModel(cache: cache)
        let nextSent = Box<[String]>([])
        await nextSheet.search("CS", semester: "1151", fetch: Self.backend(nextSent) { _ in .notModified })
        for _ in 0..<10_000 where nextSent.value.count < 2 {
            await Task.yield()
        }
        #expect(Set(nextSent.value) == [#"zh W/"zh1""#, #"en W/"en2""#])
    }

    @Test("with nothing stored, a search waits for the catalog, stores it and adds in the app language")
    func nothingStored() async throws {
        let cache = Self.cache()
        let sent = Box<[String]>([])
        let gate = Gate()
        let model = CourseSearchModel(cache: cache)
        let fetch = Self.backend(sent, gate: gate) { .changed(try Self.stored($0, etag: #"W/"\#($0)""#)) }

        let search = Task { await model.search("data", semester: "1151", fetch: fetch) }
        for _ in 0..<10_000 where sent.value.count < 2 {
            await Task.yield()
        }
        #expect(model.isSearching)
        #expect(model.failure == nil)
        model.submit()
        #expect(model.revision == 0)

        gate.open()
        await search.value
        #expect(!model.isSearching)
        #expect(model.results.mapValues { $0.map(\.CourseNo) } == ["en": ["CS1002301"]])
        #expect(model.revision == 0)
        #expect(cache.loadCourseCatalog(semester: "1151", language: "zh")?.etag == #"W/"zh""#)
        #expect(cache.loadCourseCatalog(semester: "1151", language: "en")?.etag == #"W/"en""#)

        #expect(model.appLanguageRow(of: "CS1002301", language: "zh")?.CourseName == "資料結構")
        #expect(model.appLanguageRow(of: "CS9999301", language: "zh") == nil)
        #expect(sent.value.count == 2)
    }

    @Test("with no catalog to be had, a search shows the error instead of not found", arguments: [
        CourseCatalogError.unavailable as any Error,
        URLError(.notConnectedToInternet),
        PushAPIError.notSignedIn,
    ])
    func noCatalog(error: any Error) async {
        let model = CourseSearchModel(cache: Self.cache())
        let fetch = Self.backend(Box<[String]>([])) { _ in throw error }

        await model.search("CS", semester: "1151", fetch: fetch)
        #expect(model.failure?.localizedDescription == error.localizedDescription)
        #expect(model.results.isEmpty)
        #expect(!model.isSearching)

        await model.search(" ", semester: "1151", fetch: fetch)
        #expect(model.failure == nil)
        #expect(!model.hasSearched)
    }

    @Test("Enter searches again only to retry a failed search")
    func enterRetriesOnlyAFailure() async throws {
        let sent = Box<[String]>([])
        let online = Box(false)
        let model = CourseSearchModel(cache: Self.cache())
        let fetch = Self.backend(sent) { language in
            guard online.value else { throw URLError(.notConnectedToInternet) }
            return .changed(try Self.stored(language, etag: #"W/"1""#))
        }

        await model.search("CS", semester: "1151", fetch: fetch)
        #expect(model.failure != nil)
        await model.search("CS1", semester: "1151", fetch: fetch)
        #expect(sent.value.count == 2)

        online.value = true
        model.submit()
        #expect(model.revision == 1)
        await model.search("CS1", semester: "1151", fetch: fetch)
        #expect(model.failure == nil)
        #expect(model.results["zh"]?.map(\.CourseNo) == ["CS1001301", "CS1002301"])
        #expect(sent.value.count == 4)

        model.submit()
        #expect(model.revision == 1)
        #expect(sent.value.count == 4)
    }

    @Test("each row mark looks and reads differently, and only a course already in the table is dimmed")
    func rowMarks() {
        let marks: [AddCourseRowMark] = [.inTable, .addedHere, .notAdded]
        #expect(marks.map(\.symbol) == ["checkmark", "checkmark.circle.fill", "plus.circle"])
        let heard = marks.map { [$0.accessibilityValue, $0.accessibilityHint, "\($0 == .inTable)"] }
        #expect(Set(heard).count == marks.count)
        #expect(AddCourseRowMark.notAdded.accessibilityValue.isEmpty)
        #expect(AddCourseRowMark.addedHere.accessibilityValue == String(localized: "add_course_added"))
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
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
