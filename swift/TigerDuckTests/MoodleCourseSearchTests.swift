import Foundation
import Testing
@testable import TigerDuck

struct MoodleCourseSearchTests {
    static func announcement(_ id: Int, title: String, html: String = "", author: String? = nil) -> MoodleDiscussion {
        MoodleDiscussion(
            id: id, postId: id + 1000, title: title, message: html, preview: MoodleHTMLText.plainText(fromHTML: html),
            created: Date(timeIntervalSince1970: 1_790_000_000 + TimeInterval(id)),
            modified: Date(timeIntervalSince1970: 1_790_000_000 + TimeInterval(id)),
            isPinned: false, unreadCount: 0, replyCount: 0, authorName: author, attachments: []
        )
    }

    static func file(_ name: String) -> MoodleFile {
        MoodleFile(
            name: name, size: 1024, url: "https://moodle-stub.invalid/pluginfile.php/1/\(name)",
            mimeType: nil, modified: nil, path: "/"
        )
    }

    static func material(_ id: Int, _ name: String, _ content: MoodleMaterial.Content) -> MoodleMaterial {
        MoodleMaterial(id: id, instance: id, module: "resource", name: name, content: content)
    }

    static let materials = MoodleCourseMaterials(sections: [
        MoodleMaterialSection(id: 1, name: "General", materials: [
            material(11, "Syllabus", .file(file("syllabus.pdf"))),
        ], number: 0),
        MoodleMaterialSection(id: 2, name: "Week 1 Introduction", materials: [
            material(21, "Slides 1", .file(file("intro.pdf"))),
            material(22, "Course website", .link(URL(string: "https://example.invalid/course")!)),
        ], number: 1),
        MoodleMaterialSection(id: 3, name: "Week 2", materials: [
            material(31, "Lab files", .folder([file("lab1.zip"), file("lab1-solution.pdf"), file("readme.txt")])),
            material(32, "Reading list", .link(URL(string: "https://example.invalid/reading")!)),
        ], number: 2),
        MoodleMaterialSection(id: 4, name: "Semana 3: Introducción", materials: [
            material(41, "Café de lectura", .file(file("lectura.pdf"))),
        ], number: 3),
    ])

    private static let announcements = [
        announcement(1, title: "Midterm exam room", html: "<p>Room TR-313</p>", author: "Tiger Teacher"),
        announcement(2, title: "Week 5", html: "<p>No class</p>", author: "B11399001 @ 王小明"),
        announcement(3, title: "Lab", html: "<p>Bring your <b>calculator</b> &amp; laptop</p>", author: nil),
    ]

    private static func ids(_ query: String) -> [Int] {
        MoodleDiscussion.matching(query, in: announcements).map(\.id)
    }

    private static func sections(_ query: String) -> [MoodleMaterialSection] {
        materials.sections(matching: query)
    }

    @Test("an announcement matches by its subject, its author's name or its text")
    func announcementFields() {
        #expect(Self.ids("midterm") == [1])
        #expect(Self.ids("王小明") == [2])
        #expect(Self.ids("teacher") == [1])
        #expect(Self.ids("no class") == [2])
    }

    @Test("the text matches as the page shows it, without its HTML")
    func announcementHTMLStripped() {
        #expect(Self.ids("calculator & laptop") == [3])
        #expect(Self.ids("<b>").isEmpty)
        #expect(Self.ids("amp").isEmpty)
        #expect(Self.ids("p>").isEmpty)
    }

    @Test("an announcement matches whatever the case and accents")
    func announcementCaseAndDiacritics() {
        let list = [Self.announcement(9, title: "Résumé Café")]
        #expect(MoodleDiscussion.matching("RESUME cafe", in: list).map(\.id) == [9])
        #expect(MoodleDiscussion.matching("résumé", in: list).map(\.id) == [9])
    }

    @Test("an empty or blank query keeps every announcement in order", arguments: ["", "  ", "\n"])
    func announcementEmptyQuery(query: String) {
        #expect(Self.ids(query) == [1, 2, 3])
    }

    @Test("a query nothing holds matches no announcement")
    func announcementNoMatch() {
        #expect(Self.ids("final exam").isEmpty)
    }

    @Test("a section whose name matches keeps every item")
    func sectionNameMatch() {
        #expect(Self.sections("introduction ") == [Self.materials.sections[1]])
    }

    @Test("an item's name keeps that item alone in its section")
    func itemNameMatch() {
        let found = Self.sections("website")
        #expect(found.map(\.id) == [2])
        #expect(found.first?.name == "Week 1 Introduction")
        #expect(found.first?.materials.map(\.id) == [22])
    }

    @Test("a file's name keeps its item, and a folder keeps only its matching files")
    func fileNameMatch() {
        #expect(Self.sections("intro.pdf").flatMap(\.materials).map(\.id) == [21])
        let folder = Self.sections("solution").first?.materials.first
        #expect(folder?.id == 31)
        #expect(folder?.content == .folder([Self.file("lab1-solution.pdf")]))
        #expect(Self.sections("lab files").first?.materials == [Self.materials.sections[2].materials[0]])
    }

    @Test("a section and an item match whatever the case and accents")
    func materialsCaseAndDiacritics() {
        #expect(Self.sections("INTRODUCCION") == [Self.materials.sections[3]])
        #expect(Self.sections("CAFE").flatMap(\.materials).map(\.id) == [41])
    }

    @Test("an empty or blank query keeps every section whole", arguments: ["", "  ", "\n"])
    func materialsEmptyQuery(query: String) {
        #expect(Self.sections(query) == Self.materials.sections)
    }

    @Test("a query nothing holds matches no section")
    func materialsNoMatch() {
        #expect(Self.sections("final exam").isEmpty)
    }
}
