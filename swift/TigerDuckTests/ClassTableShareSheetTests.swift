import CoreImage
import Foundation
import Testing
@testable import TigerDuck

/// The share sheet's model: the terms it offers, the code it builds for the pick, in our format or
/// TAT's, and the caption naming what the code holds.
@MainActor
struct ClassTableShareModelTests {
    private typealias Term = ClassTableShareModel.Term

    /// 2026-10-13 14:05, Taipei time.
    private static let now = Date(timeIntervalSince1970: 1_791_871_500)

    private static func label(_ semester: String) -> String {
        String(semester.dropLast()) + "-" + String(semester.suffix(1))
    }

    /// Two terms, the newest first: 115-1 with two courses, 114-2 with one.
    private static func model(_ terms: [Term]? = nil) -> ClassTableShareModel {
        ClassTableShareModel(
            studentId: "b11300000",
            terms: terms ?? [
                Term(semester: "1151", courses: [
                    SDCourse(courseNo: "CS1010001", courseName: "Programming", schedule: [1: ["3", "4"]]),
                    SDCourse(courseNo: "EE1010002", courseName: "Circuits", schedule: [2: ["6", "7"]]),
                ]),
                Term(semester: "1142", courses: [
                    SDCourse(courseNo: "MA1010003", courseName: "Calculus", schedule: [3: ["1"]]),
                ]),
            ],
            semesterLabel: label,
            now: { now }
        )
    }

    private static func decoded(_ model: ClassTableShareModel) throws -> ClassTableShareCode {
        try ClassTableShareCode.decode(try #require(model.code))
    }

    @Test("the options are all semesters, then each term with courses, newest first")
    func options() {
        #expect(Self.model().options == [.allSemesters, .semester("1151"), .semester("1142")])
    }

    @Test("the sheet opens on the latest term, its code holding that term's courses only")
    func defaultTerm() throws {
        let model = Self.model()

        #expect(model.selection == .semester("1151"))
        #expect(try Self.decoded(model).terms == [
            ClassTableShareCode.Term(semester: "1151", courseNos: ["CS1010001", "EE1010002"]),
        ])
    }

    @Test("all semesters turns the TAT switch off and disables it, and shares every term in our code")
    func allSemestersDisablesTAT() throws {
        let model = Self.model()
        model.isTATCompatible = true
        #expect(model.offersTAT)

        model.selection = .allSemesters

        #expect(!model.isTATCompatible)
        #expect(!model.offersTAT)
        #expect(try Self.decoded(model) == ClassTableShareCode(
            format: .tigerDuck, studentId: "B11300000", sharedAt: Self.now,
            terms: [
                ClassTableShareCode.Term(semester: "1151", courseNos: ["CS1010001", "EE1010002"]),
                ClassTableShareCode.Term(semester: "1142", courseNos: ["MA1010003"]),
            ]
        ))

        model.selection = .semester("1142")
        #expect(model.offersTAT)
        #expect(!model.isTATCompatible, "the switch stays off after all semesters turned it off")
    }

    @Test("the switch moves the code between ours, stamped when the sheet built it, and TAT's with class times")
    func tatSwitch() throws {
        let model = Self.model()
        #expect(try Self.decoded(model).format == .tigerDuck)
        #expect(try Self.decoded(model).sharedAt == Self.now)

        model.isTATCompatible = true
        #expect(model.code == "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300000CS1010001.134-EE1010002.256")

        model.selection = .semester("1142")
        #expect(model.code == "HTTPS://NTUST-TAT.WEB.APP/S/TAT21142B11300000MA1010003.31")

        model.isTATCompatible = false
        #expect(try Self.decoded(model).terms == [ClassTableShareCode.Term(semester: "1142", courseNos: ["MA1010003"])])
    }

    @Test("a term whose course codes TAT cannot carry keeps the switch off")
    func termTATCannotCarry() {
        let model = Self.model([
            Term(semester: "1151", courses: [SDCourse(courseNo: "CS1010001", courseName: "Programming")]),
            Term(semester: "1142", courses: [SDCourse(courseNo: "3CS1010002", courseName: "Seminar")]),
        ])
        model.isTATCompatible = true

        model.selection = .semester("1142")

        #expect(!model.offersTAT)
        #expect(!model.isTATCompatible)
        #expect(model.code?.hasPrefix(ClassTableShareCode.prefix) == true)

        model.isTATCompatible = true
        #expect(!model.isTATCompatible, "the switch cannot be turned on for a term TAT cannot carry")
        #expect(model.code?.hasPrefix(ClassTableShareCode.prefix) == true)
    }

    @Test("the caption names the student ID and the term, or all semesters")
    func caption() {
        let model = Self.model()
        #expect(model.caption == "B11300000 · 115-1")

        model.selection = .allSemesters
        #expect(model.caption == "B11300000 · " + String(localized: "class_table_share_all_semesters"))
    }
}

/// The terms the sheet offers and the ⋯ menu item's state, read from the course caches.
@MainActor
struct ClassTableShareTermsTests {
    /// A cache in folders of its own, removed when the test ends.
    @MainActor
    private final class Cache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassTableShareTermsTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static func courseNos(_ terms: [ClassTableShareModel.Term]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: terms.map { ($0.semester, $0.courses.map(\.courseNo)) })
    }

    @Test("a term without courses is left out, and courses added by hand go in")
    func termsWithCourses() {
        let store = Cache()
        store.cache.saveCourses([SDCourse(courseNo: "CS1010001", courseName: "Programming")], semester: "1151")
        store.cache.saveUserAddedCourses([
            SDCourse(courseNo: "GE1010004", courseName: "Film", semester: "1151"),
            SDCourse(courseNo: "MA1010003", courseName: "Calculus", semester: "1142"),
        ])

        let terms = ClassTableShareModel.terms(in: ["1152", "1151", "1142"], cache: store.cache)

        #expect(terms.map(\.semester) == ["1151", "1142"])
        #expect(Self.courseNos(terms) == ["1151": ["CS1010001", "GE1010004"], "1142": ["MA1010003"]])
    }

    @Test("a course whose code a share code cannot carry stays out, and a term left without one with it")
    func coursesACodeCannotCarry() {
        let store = Cache()
        store.cache.saveCourses([
            SDCourse(courseNo: "CS1010001", courseName: "Programming"),
            SDCourse(courseNo: "1151CS101", courseName: "From Moodle only"),
        ], semester: "1151")
        store.cache.saveCourses([SDCourse(courseNo: "1142EE102", courseName: "From Moodle only")], semester: "1142")

        let terms = ClassTableShareModel.terms(in: ["1151", "1142"], cache: store.cache)

        #expect(Self.courseNos(terms) == ["1151": ["CS1010001"]])
    }

    @Test("a term whose code a share code cannot hold stays out")
    func termsACodeCannotHold() {
        let store = Cache()
        store.cache.saveCourses([SDCourse(courseNo: "CS1000001", courseName: "Old term")], semester: "99 1")

        #expect(ClassTableShareModel.terms(in: ["99 1"], cache: store.cache).isEmpty)
    }

    @Test("a course hidden from the class table stays out, and a term left without one with it")
    func hiddenCourses() {
        let store = Cache()
        store.cache.saveCourses([
            SDCourse(courseNo: "CS1010001", courseName: "Programming"),
            SDCourse(courseNo: "EE1010002", courseName: "Circuits"),
        ], semester: "1151")
        store.cache.saveCourses([SDCourse(courseNo: "MA1010003", courseName: "Calculus")], semester: "1142")
        store.cache.saveDeletedCourseNos(["1151:EE1010002", "1142:MA1010003"])

        let terms = ClassTableShareModel.terms(in: ["1151", "1142"], cache: store.cache)

        #expect(Self.courseNos(terms) == ["1151": ["CS1010001"]])
    }

    @Test("the menu item is disabled with no course in any term, and with no one signed in")
    func menuItem() {
        let store = Cache()
        let semesters = ["1151", "1142"]
        #expect(!ClassTableShareModel.canShare(
            studentId: "B11300000", shownCourses: [], semesters: semesters, cache: store.cache
        ))
        #expect(!ClassTableShareModel.canShare(
            studentId: "B11300000", shownCourses: [SDCourse(courseNo: "1151CS101", courseName: "From Moodle only")],
            semesters: semesters, cache: store.cache
        ), "a course on screen whose code a share code cannot carry is not enough")

        store.cache.saveCourses([SDCourse(courseNo: "MA1010003", courseName: "Calculus")], semester: "1142")
        #expect(ClassTableShareModel.canShare(
            studentId: "B11300000", shownCourses: [], semesters: semesters, cache: store.cache
        ), "a course in an older term than the one on screen is enough")
        #expect(!ClassTableShareModel.canShare(
            studentId: nil, shownCourses: [], semesters: semesters, cache: store.cache
        ))
        #expect(!ClassTableShareModel.canShare(
            studentId: "B113-0000", shownCourses: [], semesters: semesters, cache: store.cache
        ), "a student ID a code cannot hold")

        let empty = Cache()
        #expect(ClassTableShareModel.canShare(
            studentId: "B11300000", shownCourses: [SDCourse(courseNo: "CS1010001", courseName: "Programming")],
            semesters: semesters, cache: empty.cache
        ), "the term on screen answers without the caches")
    }
}

/// The QR code Core Image draws for a share code: a detector reads the code back, and it stays in
/// alphanumeric mode at error correction level M, as docs/decisions/0023-class-table-share-code.md
/// counts its size.
@MainActor
struct ClassTableShareQRCodeTests {
    /// 8 terms of 10 courses of random departments and digits, from a fixed seed: the code the
    /// decision record sizes, a version 18 symbol.
    static func eightTermsCode() throws -> String {
        var seed: UInt64 = 382
        func random(_ count: UInt64) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % count)
        }
        let departments = ["CS", "EE", "EC", "MA", "PE", "GE", "FE", "CH", "ME", "TX", "DT", "MI"]
        let semesters = ["1151", "114H", "1142", "1141", "113H", "1132", "1131", "1122"]
        let terms = semesters.map { semester in
            ClassTableShareCode.Term(semester: semester, courseNos: (0..<10).map { _ in
                departments[random(12)] + (0..<7).map { _ in String(random(10)) }.joined()
            })
        }
        return try #require(ClassTableShareCode.encode(studentId: "B11300000", sharedAt: Date(), terms: terms))
    }

    /// What a QR detector reads from `image`, drawn eight pixels a module so it sees whole modules.
    static func scan(_ image: CGImage, enlargedBy factor: CGFloat = 8) -> CIQRCodeFeature? {
        let enlarged = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .samplingNearest()
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        return detector?.features(in: enlarged).compactMap { $0 as? CIQRCodeFeature }.first
    }

    enum Sample: CaseIterable {
        case ours, tat, eightTerms
    }

    @Test("the QR code reads back as the code, in alphanumeric mode at level M", arguments: Sample.allCases)
    func readsBack(sample: Sample) throws {
        let text = switch sample {
        case .ours: "HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151.OMHDMNBQGQYDAMGUOGDLFDDULROWCYV6RYYFMACMBQAA.E2YUDIQ"
        case .tat: "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300000CS1010001.134-EE1010002.256"
        case .eightTerms: try Self.eightTermsCode()
        }
        let image = try #require(ClassTableShareQRCode.image(for: text))

        let feature = try #require(Self.scan(image))
        #expect(feature.messageString == text)
        let symbol = try #require(feature.symbolDescriptor)
        #expect(symbol.errorCorrectionLevel == .levelM)
        // The first four bits of the first data codeword are the mode indicator; 0010 is alphanumeric.
        #expect(symbol.errorCorrectedPayload.first.map { $0 >> 4 } == 0b0010)
        if sample == .eightTerms {
            #expect(symbol.symbolVersion <= 18, "\(text.count) characters")
        }
    }
}

#if os(iOS)
import SwiftUI
import UIKit

/// The sheet laid out in a window: its QR code scans from a screenshot, and the TAT switch follows
/// the pick.
@MainActor
@Suite(.serialized)
struct ClassTableShareSheetTests {
    private func host(_ model: ClassTableShareModel) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: ClassTableShareSheet(model: model))
        window.makeKeyAndVisible()
        return window
    }

    /// A phone's screenshot, three pixels a point, after a chat app has halved it.
    private func halvedScreenshot(_ window: UIWindow) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.cgImage
    }

    private static func switches(in view: UIView) -> [UISwitch] {
        view.subviews.flatMap { [$0 as? UISwitch].compactMap { $0 } + switches(in: $0) }
    }

    @Test("the longest code scans from a screenshot a chat app has halved, at about four pixels a module")
    func scansFromAHalvedScreenshot() async throws {
        let code = try ClassTableShareQRCodeTests.eightTermsCode()
        let decoded = try ClassTableShareCode.decode(code)
        let model = ClassTableShareModel(
            studentId: "B11300000",
            terms: decoded.terms.map { term in
                ClassTableShareModel.Term(
                    semester: term.semester,
                    courses: term.courseNos.map { SDCourse(courseNo: $0, courseName: $0) }
                )
            },
            semesterLabel: { $0 }
        )
        model.selection = .allSemesters
        let window = try host(model)
        defer { window.isHidden = true }

        var read: CIQRCodeFeature?
        try await waitUntil {
            read = halvedScreenshot(window).flatMap { ClassTableShareQRCodeTests.scan($0, enlargedBy: 1) }
            return read != nil
        }
        let feature = try #require(read)
        #expect(feature.messageString == model.code)
        let version = try #require(feature.symbolDescriptor?.symbolVersion)
        let pixelsPerModule = feature.bounds.width / CGFloat(17 + 4 * version)
        #expect(pixelsPerModule >= 3.5, "\(pixelsPerModule) pixels a module")
    }

    @Test("the TAT switch turns off and disables for all semesters")
    func tatSwitchFollowsThePick() async throws {
        let model = ClassTableShareModel(
            studentId: "B11300000",
            terms: [ClassTableShareModel.Term(
                semester: "1151",
                courses: [SDCourse(courseNo: "CS1010001", courseName: "Programming", schedule: [1: ["3"]])]
            )],
            semesterLabel: { $0 }
        )
        let window = try host(model)
        defer { window.isHidden = true }
        try await waitUntil { Self.switches(in: window).count == 1 }
        let toggle = try #require(Self.switches(in: window).first)
        #expect(toggle.isEnabled)
        #expect(!toggle.isOn)

        model.isTATCompatible = true
        try await waitUntil { toggle.isOn }

        model.selection = .allSemesters
        try await waitUntil { !toggle.isEnabled && !toggle.isOn }
    }
}
#endif
