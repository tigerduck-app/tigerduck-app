import CoreImage
import Foundation
import Observation
import Testing
@testable import TigerDuck

@MainActor
struct ClassTableShareModelTests {
    private typealias Term = ClassTableShareModel.Term

    private static let now = Date(timeIntervalSince1970: 1_791_871_500)

    private static func label(_ semester: String) -> String {
        String(semester.dropLast()) + "-" + String(semester.suffix(1))
    }

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

@MainActor
struct ClassTableShareTermsTests {
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
            studentId: "B11300000", shownTerm: .init(semester: "1151", courses: []), semesters: semesters, cache: store.cache
        ))
        #expect(!ClassTableShareModel.canShare(
            studentId: "B11300000", shownTerm: .init(semester: "1151", courses: [SDCourse(courseNo: "1151CS101", courseName: "From Moodle only")]),
            semesters: semesters, cache: store.cache
        ), "a course on screen whose code a share code cannot carry is not enough")

        store.cache.saveCourses([SDCourse(courseNo: "MA1010003", courseName: "Calculus")], semester: "1142")
        #expect(ClassTableShareModel.canShare(
            studentId: "B11300000", shownTerm: .init(semester: "1151", courses: []), semesters: semesters, cache: store.cache
        ), "a course in an older term than the one on screen is enough")
        #expect(!ClassTableShareModel.canShare(
            studentId: nil, shownTerm: .init(semester: "1151", courses: []), semesters: semesters, cache: store.cache
        ))
        #expect(!ClassTableShareModel.canShare(
            studentId: "B113-0000", shownTerm: .init(semester: "1151", courses: []), semesters: semesters, cache: store.cache
        ), "a student ID a code cannot hold")

        let empty = Cache()
        #expect(ClassTableShareModel.canShare(
            studentId: "B11300000", shownTerm: .init(semester: "1151", courses: [SDCourse(courseNo: "CS1010001", courseName: "Programming")]),
            semesters: semesters, cache: empty.cache
        ), "the term on screen answers without the caches")
    }

    @Test("the menu item's answer is worked out again only once the term on screen or the caches change")
    func menuItemKeepsItsAnswer() throws {
        let store = Cache()
        let memo = ClassTableShareModel.AvailabilityMemo()
        let empty = ClassTableShareModel.Term(semester: "1151", courses: [])
        let canShare = { (shown: ClassTableShareModel.Term) in
            ClassTableShareModel.canShare(
                studentId: "B11300000", shownTerm: shown, semesters: ["1151", "1142"], cache: store.cache, memo: memo
            )
        }
        store.cache.saveCourses([SDCourse(courseNo: "MA1010003", courseName: "Calculus")], semester: "1142")
        #expect(canShare(empty))

        try FileManager.default.removeItem(at: store.root.appendingPathComponent("cache", isDirectory: true))
        #expect(canShare(empty))

        store.cache.saveDeletedCourseNos([])
        #expect(!canShare(empty))
        #expect(canShare(.init(semester: "1151", courses: [SDCourse(courseNo: "CS1010001", courseName: "Programming")])))
    }

    @Test("an empty displayed term does not resurrect cached courses or enable sharing")
    func emptyDisplayedTerm() {
        let store = Cache()
        store.cache.saveCourses([SDCourse(courseNo: "CS1010001", courseName: "Dropped")], semester: "1151")
        let shown = ClassTableShareModel.Term(semester: "1151", courses: [])

        #expect(ClassTableShareModel.terms(in: ["1151"], cache: store.cache, shownTerm: shown).isEmpty)
        #expect(!ClassTableShareModel.canShare(
            studentId: "B11300000", shownTerm: shown, semesters: ["1151"], cache: store.cache
        ))
    }

    @Test("the displayed term uses its current snapshot instead of stale enrolled and added courses")
    func displayedSnapshot() {
        let store = Cache()
        store.cache.saveCourses([SDCourse(courseNo: "CS1010001", courseName: "Dropped")], semester: "1151")
        store.cache.saveUserAddedCourses([SDCourse(courseNo: "GE1010004", courseName: "Removed", semester: "1151")])
        let shown = ClassTableShareModel.Term(semester: "1151", courses: [
            SDCourse(courseNo: "EE1010002", courseName: "Current"),
            SDCourse(courseNo: "MA1010003", courseName: "Added"),
        ])

        #expect(Self.courseNos(ClassTableShareModel.terms(
            in: ["1151"], cache: store.cache, shownTerm: shown
        )) == ["1151": ["EE1010002", "MA1010003"]])
    }

    @Test("older terms still share from cache without reviving an empty displayed term in the QR code")
    func olderTermsWithEmptyDisplayedTerm() throws {
        let store = Cache()
        store.cache.saveCourses([SDCourse(courseNo: "CS1010001", courseName: "Dropped")], semester: "1151")
        store.cache.saveCourses([SDCourse(courseNo: "MA1010003", courseName: "Past")], semester: "1142")
        let shown = ClassTableShareModel.Term(semester: "1151", courses: [])
        let terms = ClassTableShareModel.terms(in: ["1151", "1142"], cache: store.cache, shownTerm: shown)
        let model = ClassTableShareModel(studentId: "B11300000", terms: terms, semesterLabel: { $0 })
        model.selection = .allSemesters

        #expect(ClassTableShareModel.canShare(
            studentId: "B11300000", shownTerm: shown, semesters: ["1151", "1142"], cache: store.cache
        ))
        #expect(try ClassTableShareCode.decode(try #require(model.code)).terms == [
            .init(semester: "1142", courseNos: ["MA1010003"]),
        ])
    }

    @Test("the displayed snapshot still excludes hidden and unsupported course codes")
    func displayedSnapshotFilters() {
        let store = Cache()
        store.cache.saveDeletedCourseNos(["1151:CS1010001"])
        let shown = ClassTableShareModel.Term(semester: "1151", courses: [
            SDCourse(courseNo: "CS1010001", courseName: "Hidden"),
            SDCourse(courseNo: "1151EE101", courseName: "Moodle only"),
        ])

        #expect(ClassTableShareModel.terms(in: ["1151"], cache: store.cache, shownTerm: shown).isEmpty)
        #expect(!ClassTableShareModel.canShare(
            studentId: "B11300000", shownTerm: shown, semesters: ["1151"], cache: store.cache
        ))
    }

    @Test("sharing availability and payload snapshots never change the displayed course's custom name", arguments: [true, false])
    func displayedSnapshotPreservesNames(checkAvailability: Bool) throws {
        let store = Cache()
        let course = SDCourse(courseNo: "CS1010001", courseName: "Programming")
        course.customName = "My course alias"
        let shown = ClassTableShareModel.Term(semester: "1151", courses: [course])
        if checkAvailability {
            #expect(ClassTableShareModel.canShare(
                studentId: "B11300000", shownTerm: shown, semesters: ["1151"], cache: store.cache
            ))
        } else {
            let terms = ClassTableShareModel.terms(in: ["1151"], cache: store.cache, shownTerm: shown)
            #expect(terms.first?.courses.first === course)
            let model = ClassTableShareModel(studentId: "B11300000", terms: terms, semesterLabel: { $0 })
            #expect(try ClassTableShareCode.decode(try #require(model.code)).terms == [
                .init(semester: "1151", courseNos: ["CS1010001"]),
            ])
        }
        #expect(course.customName == "My course alias")
        #expect(course.displayName == "My course alias")
        #expect(course.courseName == "Programming")
    }
}

@MainActor
struct ClassTableShareQRCodeTests {
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
        #expect(symbol.errorCorrectedPayload.first.map { $0 >> 4 } == 0b0010)
        if sample == .eightTerms {
            #expect(symbol.symbolVersion <= 18, "\(text.count) characters")
        }
    }
}

#if os(iOS)
import SwiftUI
import UIKit
import Vision

@MainActor
@Suite(.serialized)
struct ClassTableShareSheetTests {
    @Observable
    final class Session {
        var generation = 0
    }

    private struct PresentedSheet: View {
        let model: ClassTableShareModel
        let session: Session
        @State private var presented: ClassTableShareModel?

        var body: some View {
            Color.clear
                .classTableShareSheet(model: $presented, loginGeneration: session.generation)
                .onAppear { presented = model }
        }
    }

    private func host(_ model: ClassTableShareModel) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: ClassTableShareSheet(model: model))
        window.makeKeyAndVisible()
        return window
    }

    private func halvedScreenshot(_ window: UIWindow) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.cgImage
    }

    private struct RecognizedLine: Sendable {
        let text: String
        let boundingBox: CGRect
    }

    private nonisolated static func lines(in image: CGImage, words: [String]) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                let chinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
                request.recognitionLanguages = chinese ? ["zh-Hant", "en-US"] : ["en-US", "zh-Hant"]
                request.usesLanguageCorrection = false
                request.customWords = words
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    continuation.resume(returning: (request.results ?? []).compactMap { observation in
                        observation.topCandidates(1).first.map {
                            RecognizedLine(text: $0.string, boundingBox: observation.boundingBox)
                        }
                    })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func lines(
        in window: UIWindow,
        words: [String],
        showing text: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> [RecognizedLine] {
        let deadline = ContinuousClock.now + .seconds(60)
        var read: [RecognizedLine] = []
        repeat {
            if let screenshot = halvedScreenshot(window) {
                read = (try? await Self.lines(in: screenshot, words: words)) ?? []
                if read.contains(where: { $0.text.contains(text) }) { return read }
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        Issue.record("no line showed \(text) within 60 seconds: \(read.map(\.text))", sourceLocation: sourceLocation)
        return read
    }

    private static func crowdedModel() -> ClassTableShareModel {
        var seed: UInt64 = 382
        func random(_ count: UInt64) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % count)
        }
        let departments = ["CS", "EE", "EC", "MA", "PE", "GE", "FE", "CH", "ME", "TX", "DT", "MI"]
        let semesters = ["1151"] + (107...114).reversed().flatMap { ["\($0)H", "\($0)2", "\($0)1"] }
        return ClassTableShareModel(
            studentId: "B10700000",
            terms: semesters.prefix(24).map { semester in
                .init(semester: semester, courses: (0..<20).map { _ in
                    let code = departments[random(12)] + (0..<7).map { _ in String(random(10)) }.joined()
                    return SDCourse(courseNo: code, courseName: code)
                })
            },
            semesterLabel: { $0 },
            now: { Date(timeIntervalSince1970: 1_791_871_500) }
        )
    }

    @MainActor
    private final class Ticks {
        var count = 0
    }

    @Test("text recognition runs off the main actor, which the tests running beside it wait on")
    func recognitionLeavesTheMainActorFree() async throws {
        let size = CGSize(width: 320, height: 80)
        let image = try #require(UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("B11300000" as NSString).draw(at: CGPoint(x: 16, y: 16), withAttributes: [.font: UIFont.systemFont(ofSize: 32)])
        }.cgImage)
        let ticks = Ticks()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks.count += 1
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { ticker.cancel() }

        let read = try await Self.lines(in: image, words: ["B11300000"])

        #expect(ticks.count > 0, "the main actor ran nothing while Vision read the image")
        #expect(read.contains { $0.text.contains("B11300000") })
    }

    @Test("a payload too large for a QR shows a visible failure and a different term restores the code")
    func qrCapacityFailure() async throws {
        let model = Self.crowdedModel()
        #expect(model.qrCode != nil)
        model.selection = .allSemesters
        let decoded = try ClassTableShareCode.decode(try #require(model.code))
        #expect(decoded.terms.count == 24)
        #expect(decoded.terms.reduce(0) { $0 + $1.courseNos.count } == 480)
        #expect(model.qrCode == nil, "the fixture must exceed real QR capacity without truncating courses")
        let window = try host(model)
        defer { window.isHidden = true }
        let failure = String(localized: "library_qr_generate_failed")
        let words = [model.studentId, failure]
        let showsFailure = { (line: String) in line.filter { !$0.isWhitespace }.contains(failure.filter { !$0.isWhitespace }) }
        let onScreen = try await lines(in: window, words: words, showing: model.studentId).map(\.text)
        #expect(onScreen.contains(where: showsFailure), "a missing QR must explain its failure on screen: \(onScreen)")
        #expect(halvedScreenshot(window).flatMap { ClassTableShareQRCodeTests.scan($0, enlargedBy: 1) } == nil)

        model.selection = .semester("1151")
        try await waitUntil {
            halvedScreenshot(window).flatMap { ClassTableShareQRCodeTests.scan($0, enlargedBy: 1) }?.messageString == model.code
        }
        #expect(try ClassTableShareCode.decode(try #require(model.code)).terms.map(\.semester) == ["1151"])
        let restored = try await Self.lines(in: try #require(halvedScreenshot(window)), words: words).map(\.text)
        #expect(!restored.contains(where: showsFailure))
    }

    private static func switches(in view: UIView) -> [UISwitch] {
        view.subviews.flatMap { [$0 as? UISwitch].compactMap { $0 } + switches(in: $0) }
    }

    @Test("the complete QR code and caption are visible at the opening detent on a small phone")
    func smallPhoneOpeningDetent() async throws {
        #expect(ClassTableShareSheet.openingDetent == .height(440))
        let model = ClassTableShareModel(
            studentId: "B11300000",
            terms: [.init(semester: "1151", courses: [SDCourse(courseNo: "CS1010001", courseName: "Programming")])],
            semesterLabel: { _ in "115-1" }
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        let session = Session()
        let host = UIHostingController(rootView: PresentedSheet(model: model, session: session))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
        }

        try await waitUntil { host.presentedViewController?.view.bounds.height ?? 0 > 0 }
        let presented = try #require(host.presentedViewController)
        try await waitUntil { !presented.isBeingPresented }
        var read: CIQRCodeFeature?
        var screenshot: CGImage?
        try await waitUntil {
            screenshot = halvedScreenshot(window)
            read = screenshot.flatMap { ClassTableShareQRCodeTests.scan($0, enlargedBy: 1) }
            return read != nil
        }
        let feature = try #require(read)
        let visible = presented.view.convert(presented.view.bounds, to: window).intersection(window.bounds)
        let sheet = presented.view.bounds
        let captured = try #require(screenshot)
        let recognized = try await Self.lines(in: captured, words: [model.studentId, "115-1"])
        let caption = try #require(recognized.first { $0.text.contains("B11300000") && $0.text.contains("115-1") })
        #expect(window.bounds.size == CGSize(width: 375, height: 667))
        #expect(abs(sheet.height - 440) < 1, "the sheet must remain at its opening height: \(sheet)")
        #expect(visible.width >= 350 && visible.width <= 375)
        let captionFrame = CGRect(
            x: caption.boundingBox.minX * window.bounds.width,
            y: (1 - caption.boundingBox.maxY) * window.bounds.height,
            width: caption.boundingBox.width * window.bounds.width,
            height: caption.boundingBox.height * window.bounds.height
        )
        #expect(!captionFrame.isEmpty)
        #expect(visible.contains(captionFrame), "the whole caption must fit before scrolling: \(captionFrame)")
        #expect(feature.messageString == model.code)
        let version = try #require(feature.symbolDescriptor?.symbolVersion)
        let module = feature.bounds.width / CGFloat(17 + 4 * version) / 1.5
        let symbol = CGRect(
            x: feature.bounds.minX / 1.5,
            y: window.bounds.height - feature.bounds.maxY / 1.5,
            width: feature.bounds.width / 1.5,
            height: feature.bounds.height / 1.5
        )
        #expect(visible.contains(symbol.insetBy(dx: -4 * module, dy: -4 * module)), "the QR code's quiet zone must fit")

        session.generation += 1
        try await waitUntil { host.presentedViewController == nil }
    }

    @Test("8 terms of 10 courses scan from a phone screenshot a chat app has halved, at about four pixels a module")
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
