import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ClassTableImportModelTests {
    private typealias Term = ClassTableShareCode.Term

    private final class Folder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassTableImportModelTests-\(UUID().uuidString)", isDirectory: true)
        var file: URL { url.appendingPathComponent("imported_class_tables.json") }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private final class Lookup {
        var courses: [String: [SDCourse]] = [:]
        var failing: Set<String> = []
        private(set) var calls: [String] = []

        func callAsFunction(_ semester: String, _ courseNos: [String]) async throws -> [SDCourse] {
            calls.append(semester)
            if failing.contains(semester) { throw URLError(.timedOut) }
            return courses[semester] ?? []
        }
    }

    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { continuation != nil }

        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private nonisolated static let signedIn = "B11300000"
    private static let sharedAt = Date(timeIntervalSince1970: 1_791_871_500)
    private nonisolated static let fall = Term(semester: "1151", courseNos: ["CS1010001", "MA1010001"])
    private nonisolated static let spring = Term(semester: "1142", courseNos: ["EE1010002"])

    private let folder = Folder()
    private let lookup = Lookup()
    private let store: ImportedClassTableStore

    init() {
        store = ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { Self.signedIn })
    }

    private func makeModel(
        signedIn: String? = Self.signedIn,
        isCurrent: @escaping () -> Bool = { true }
    ) -> ClassTableImportModel {
        let lookup = lookup
        return ClassTableImportModel(
            store: store,
            signedInStudentId: { signedIn },
            isCurrent: isCurrent,
            lookup: { try await lookup($0, $1) }
        )
    }

    private static func code(_ studentId: String, _ terms: [Term] = [fall]) throws -> String {
        try #require(ClassTableShareCode.encode(studentId: studentId, sharedAt: sharedAt, terms: terms))
    }

    private static func course(_ courseNo: String, _ name: String, semester: String) -> SDCourse {
        SDCourse(courseNo: courseNo, courseName: name, schedule: [2: ["3", "4"]], semester: semester)
    }

    @Test("the camera passes over another app's QR code and goes on scanning")
    func unknownCodeIsSkipped() throws {
        let model = makeModel()

        #expect(!model.scanned("https://example.com/menu"))
        #expect(!model.scanned("WIFI:S:Library;T:WPA;P:secret;;"))
        #expect(!model.scanned(
            "HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151.OMHDMNBQGQYDAMGUOGDLFDDULROWCYV6RYYFMACMBQAA.E2YUDIQ"
        ), "the old prefix is not a share code")

        #expect(model.prompt == nil)
        #expect(model.pending == nil)
        #expect(model.isIdle)
        #expect(model.scanned(try Self.code("B11300001")))
        #expect(model.pending?.code.studentId == "B11300001")
    }

    private nonisolated static let damaged = "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/HELLO"
    private nonisolated static let newer = "HTTPS://SHARE.TIGERDUCK.APP/FRIEND/1ABC"

    @Test(
        "a damaged or edited share code is refused with one message, and scanning goes on",
        arguments: [
            "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/1KNTO5SJB234O09283J89PYINHMLGU86XQH3K2WVREW0CHIZA78",
            "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/1M4Z51AJB234O09283GA15X5HB8LS",
            damaged,
            "HTTPS://SHARE.TIGERDUCK.APP",
            "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001CS10",
        ]
    )
    func damagedCodeIsRefused(text: String) throws {
        let model = makeModel()

        #expect(model.scanned(text))

        #expect(model.prompt == .invalid)
        #expect(model.prompt?.title == String(localized: "class_table_import_failed"))
        #expect(model.prompt?.message == String(localized: "class_table_import_invalid_message"))
        #expect(model.pending == nil)
        #expect(!model.scanned(try Self.code("B11300001")), "nothing is read while the alert is up")
        model.dismissPrompt()
        #expect(model.isIdle)
    }

    @Test(
        "a code of a newer version or type asks for a newer app, under the same title",
        arguments: [
            "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/2KNTO5SJB234O09283J89PYINHMLGU86XQH3K2WVREW0CHIZS78",
            newer,
            "HTTPS://NTUST-TAT.WEB.APP/S/TAT31151B11300001CS1010001",
        ]
    )
    func newerCodeNeedsUpdate(text: String) {
        let model = makeModel()

        #expect(model.scanned(text))

        #expect(model.prompt == .needsUpdate)
        #expect(model.prompt?.title == String(localized: "class_table_import_failed"))
        #expect(model.prompt?.message == String(localized: "share_code_needs_update_message"))
        #expect(model.pending == nil)
        model.dismissPrompt()
        #expect(model.isIdle)
    }

    @Test("a link opens the confirm step a scanned code does; one the decoder does not take is called damaged")
    func linkOpened() throws {
        let opened = makeModel()
        opened.linkOpened(try Self.code("B11300001").lowercased())
        #expect(opened.pending?.code.studentId == "B11300001")
        #expect(opened.prompt == nil)

        for text in [Self.damaged, "https://share.tigerduck.app", "https://share.tigerduck.app:443/CLASSTABLE/1ABC"] {
            let model = makeModel()
            model.linkOpened(text)
            #expect(model.prompt == .invalid, "\(text)")
            #expect(model.pending == nil, "\(text)")
        }
        let newer = makeModel()
        newer.linkOpened(Self.newer)
        #expect(newer.prompt == .needsUpdate)
        #expect(store.people.isEmpty)
        #expect(lookup.calls.isEmpty)
    }

    @Test("a second link replaces the code, lookup or prompt an import shows, and nothing of the first is saved")
    func secondLinkReplacesFirst() async throws {
        let gate = Gate()
        let model = gatedModel(gate)
        model.linkOpened(try Self.code("B11300001"))
        model.importPending()
        try await Self.waitUntil { gate.isWaiting }
        let firstLookup = model.lookupTask

        model.linkOpened(try Self.code("B11300002"))
        gate.open()
        await firstLookup?.value

        #expect(model.pending?.code.studentId == "B11300002")
        #expect(!model.isLookingUp)
        #expect(store.people.isEmpty)

        model.linkOpened(Self.damaged)
        #expect(model.prompt == .invalid)
        #expect(model.pending == nil)
        model.linkOpened(try Self.code("B11300003"))
        await model.linkTask?.value
        #expect(model.prompt == nil)
        #expect(model.pending?.code.studentId == "B11300003")
    }

    @Test("a link over a shown alert closes it before showing its own, so Update carries the newer code")
    func linkOverAlertClosesItFirst() async throws {
        store.add(try ClassTableShareCode.decode(try Self.code("B11300001")), nickname: "小明", courses: [:])
        store.add(try ClassTableShareCode.decode(try Self.code("B11300002")), nickname: "小華", courses: [:])
        let model = makeModel()
        model.linkOpened(try Self.code("B11300001", [Self.spring]))
        #expect(model.prompt?.title == String(format: String(localized: "class_table_import_replace_title"), "小明"))

        model.linkOpened(try Self.code("B11300002", [Self.spring]))
        #expect(model.prompt == nil, "the first alert closes before the next one shows")
        #expect(!model.isIdle)
        #expect(!model.scanned(try Self.code("B11300003")), "a camera code cannot take the gap")
        model.linkOpened(try Self.code("B11300002"))
        await model.linkTask?.value

        guard case .replace(let job) = model.prompt else {
            Issue.record("expected the replace prompt, got \(String(describing: model.prompt))")
            return
        }
        #expect(job.nickname == "小華")
        #expect(job.code.terms == [Self.fall], "the newest link wins")

        model.cancel()
        #expect(model.isIdle)
    }

    @Test("the user's own code is refused, compared with the signed-in student ID in any case")
    func ownCodeIsRefused() throws {
        for signedIn in ["B11300000", "b11300000"] {
            let model = makeModel(signedIn: signedIn)

            #expect(model.scanned(try Self.code("B11300000")))

            #expect(model.prompt == .ownCode)
            #expect(model.prompt?.title == String(localized: "class_table_import_failed"))
            #expect(model.prompt?.message == String(localized: "class_table_import_own_code_message"))
            #expect(model.pending == nil)
        }
        let signedOut = makeModel(signedIn: nil)
        #expect(signedOut.scanned(try Self.code("B11300000")))
        #expect(signedOut.pending != nil)
    }

    @Test("a student ID imported already asks to update it, naming its nickname")
    func importedStudentIdAsksToUpdate() throws {
        let existing = try ClassTableShareCode.decode(try Self.code("B11300001"))
        store.add(existing, nickname: "小明", courses: [:])
        let model = makeModel()

        #expect(model.scanned(try Self.code("B11300001", [Self.spring])))

        guard case .replace(let job) = model.prompt else {
            Issue.record("expected the replace prompt, got \(String(describing: model.prompt))")
            return
        }
        #expect(job.nickname == "小明")
        #expect(job.code.terms == [Self.spring])
        #expect(model.prompt?.title == String(format: String(localized: "class_table_import_replace_title"), "小明"))
        #expect(model.prompt?.message == String(localized: "class_table_import_replace_message"))
        #expect(model.pending == nil, "the confirm screen does not open")
        model.dismissPrompt()
        #expect(model.isIdle)
        #expect(lookup.calls.isEmpty)
    }

    @Test("a chosen photo reserves the import before loading starts, so a camera code cannot replace it")
    func photoReadWinsOverCamera() async throws {
        let image = try Self.qrImage(try Self.code("B11300001"))
        let gate = Gate()
        let model = makeModel()
        let reading = try #require(model.readImage(load: {
            await gate.wait()
            return image
        }))

        #expect(!model.isIdle)
        #expect(!model.scanned(try Self.code("B11300002")))
        try await Self.waitUntil { gate.isWaiting }
        gate.open()
        await reading.value

        #expect(model.pending?.code.studentId == "B11300001")
        #expect(model.prompt == nil)
    }

    @Test("a cancelled photo read cannot open a confirm screen when its loader answers afterwards")
    func cancelDuringPhotoRead() async throws {
        let image = try Self.qrImage(try Self.code("B11300001"))
        let gate = Gate()
        let model = makeModel()
        let reading = try #require(model.readImage(load: {
            await gate.wait()
            return image
        }))
        try await Self.waitUntil { gate.isWaiting }

        model.cancel()
        gate.open()
        await reading.value

        #expect(model.pending == nil)
        #expect(model.prompt == nil)
        #expect(model.isIdle)
        #expect(store.people.isEmpty)
    }

    @Test("an old cancelled photo cannot make a newer photo idle or replace its result")
    func cancelledPhotoDoesNotUnblockNewPhoto() async throws {
        let firstImage = try Self.qrImage(try Self.code("B11300001"))
        let secondImage = try Self.qrImage(try Self.code("B11300002"))
        let firstGate = Gate()
        let secondGate = Gate()
        let model = makeModel()
        let first = try #require(model.readImage(load: {
            await firstGate.wait()
            return firstImage
        }))
        try await Self.waitUntil { firstGate.isWaiting }
        model.cancel()
        let second = try #require(model.readImage(load: {
            await secondGate.wait()
            return secondImage
        }))
        try await Self.waitUntil { secondGate.isWaiting }

        firstGate.open()
        await first.value
        #expect(!model.isIdle)
        #expect(!model.scanned(try Self.code("B11300003")))
        secondGate.open()
        await second.value

        #expect(model.pending?.code.studentId == "B11300002")
        #expect(model.prompt == nil)
    }

    @Test("a photo read that finishes after sign-out closes without offering or saving the import")
    func signOutDuringPhotoRead() async throws {
        var current = true
        let image = try Self.qrImage(try Self.code("B11300001"))
        let gate = Gate()
        let model = makeModel(isCurrent: { current })
        let reading = try #require(model.readImage(load: {
            await gate.wait()
            return image
        }))
        try await Self.waitUntil { gate.isWaiting }

        current = false
        gate.open()
        await reading.value

        #expect(model.pending == nil)
        #expect(model.prompt == nil)
        #expect(model.isFinished)
        #expect(store.people.isEmpty)
        #expect(Self.reloadedPeople(folder).isEmpty)
    }

    @Test("the share code in an image is read through Vision")
    func imageWithShareCode() async throws {
        let text = try Self.code("B11300001")
        let image = try Self.qrImage(text)

        #expect(ClassTableImportModel.qrPayloads(in: image) == [text])
        let model = makeModel()
        await model.readImage(image)
        #expect(model.pending?.code.studentId == "B11300001")
        #expect(model.prompt == nil)
    }

    @Test("an image with no share code says so, even when it holds another QR code")
    func imageWithoutShareCode() async throws {
        let images = [try Self.qrImage("https://example.com/menu"), try Self.blankImage(), nil]
        for image in images {
            let model = makeModel()

            await model.readImage(image)

            #expect(model.prompt == .noCode)
            #expect(model.prompt?.title == String(localized: "class_table_import_failed"))
            #expect(model.prompt?.message == String(localized: "class_table_import_no_code_message"))
            #expect(model.pending == nil)
        }
    }

    @Test("an image file, as the Mac's file importer gives it, is read, and one that cannot be read has no code")
    func imageFile() async throws {
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let file = folder.url.appendingPathComponent("shared.png")
        try Self.qrImage(try Self.code("B11300001")).write(to: file)
        let model = makeModel()

        await model.readImage(fileAt: file)
        #expect(model.pending?.code.studentId == "B11300001")

        let missing = makeModel()
        await missing.readImage(fileAt: folder.url.appendingPathComponent("gone.png"))
        #expect(missing.prompt == .noCode)
    }

    @Test("an image's first readable share code wins, then a newer code's update, then a damaged code's message")
    func imageWithSeveralCodes() throws {
        let valid = makeModel()
        valid.imageRead(["https://example.com/menu", Self.newer, Self.damaged, try Self.code("B11300002")])
        #expect(valid.pending?.code.studentId == "B11300002")

        let newer = makeModel()
        newer.imageRead([Self.damaged, "https://example.com/menu", Self.newer])
        #expect(newer.prompt == .needsUpdate)

        let refused = makeModel()
        refused.imageRead(["https://example.com/menu", Self.damaged])
        #expect(refused.prompt == .invalid)
    }

    @Test("the nickname starts as the student ID, or empty for a code without one, and Import needs one")
    func nicknameRules() async throws {
        let ours = makeModel()
        ours.scanned(try Self.code("B11300001"))
        #expect(ours.nickname == "B11300001")
        #expect(ours.canImport)

        let tat = makeModel()
        tat.scanned("HTTPS://NTUST-TAT.WEB.APP/S/TAT11142         CS1010004-PE1010005")
        #expect(tat.pending?.code.studentId == nil)
        #expect(tat.nickname.isEmpty)
        #expect(!tat.canImport)
        tat.nickname = " \n "
        #expect(!tat.canImport)
        tat.importPending()
        #expect(!tat.isLookingUp)
        #expect(lookup.calls.isEmpty)

        tat.nickname = " 小華 "
        #expect(tat.canImport)
        tat.importPending()
        await tat.lookupTask?.value
        #expect(store.people.map(\.nickname) == ["小華"])
    }

    @Test("the confirm screen lists the student ID, terms, courses and share time; a TAT code has no share time")
    func confirmRows() throws {
        let ours = try ClassTableShareCode.decode(try Self.code("B11300001", [Self.fall, Self.spring]))
        let rows = ClassTableImportModel.rows(for: ours)
        #expect(rows.map(\.title) == [
            String(localized: "sign_in_student_id"),
            String(localized: "class_table_semester_picker_label"),
            String(localized: "class_table_import_course_count"),
            String(localized: "class_table_import_shared_at"),
        ])
        #expect(rows.map(\.value) == [
            "B11300001",
            ListFormatter.localizedString(byJoining: ["115-1", "114-2"]),
            3.formatted(),
            Self.sharedAt.formatted(date: .numeric, time: .shortened),
        ])

        let tat = try ClassTableShareCode.decode(
            "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001CS1010001.267-EE1010002.13.5N-MA1010003"
        )
        #expect(ClassTableImportModel.rows(for: tat).map(\.title) == [
            String(localized: "sign_in_student_id"),
            String(localized: "class_table_semester_picker_label"),
            String(localized: "class_table_import_course_count"),
        ])
        let anonymous = try ClassTableShareCode.decode("HTTPS://NTUST-TAT.WEB.APP/S/TAT11142         CS1010004")
        #expect(ClassTableImportModel.rows(for: anonymous).map(\.title) == [
            String(localized: "class_table_semester_picker_label"),
            String(localized: "class_table_import_course_count"),
        ])
    }

    @Test("a failed save keeps confirmation open and a retry succeeds once the file can be written")
    func saveFailureCanRetry() async throws {
        lookup.courses = ["1151": [Self.course("CS1010001", "Networks", semester: "1151")]]
        try Data("blocked parent".utf8).write(to: folder.url)
        let model = makeModel()
        model.scanned(try Self.code("B11300001"))
        model.importPending()
        await model.lookupTask?.value

        #expect(!model.isFinished)
        #expect(!model.isLookingUp)
        #expect(model.pending != nil)
        #expect(model.prompt?.title == String(localized: "class_table_import_failed"))
        #expect(model.prompt?.message == nil)
        #expect(store.people.isEmpty)
        #expect(store.shownPersonID == nil)

        try FileManager.default.removeItem(at: folder.url)
        model.dismissPrompt()
        model.importPending()
        await model.lookupTask?.value

        #expect(model.isFinished)
        #expect(model.prompt == nil)
        #expect(store.people.count == 1)
        #expect(Self.reloadedPeople(folder).first?.terms.first?.courses.first?.courseName == "Networks")
    }

    @Test("an unusable existing store refuses an import without closing confirmation or replacing the file")
    func unusableStoreKeepsConfirmation() async throws {
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let kept = Data("{\"people\":\"newer format\"}".utf8)
        try kept.write(to: folder.file)
        let protectedStore = ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { Self.signedIn })
        let model = ClassTableImportModel(
            store: protectedStore,
            signedInStudentId: { Self.signedIn },
            isCurrent: { true },
            lookup: { semester, _ in [Self.course("CS1010001", "Networks", semester: semester)] }
        )
        model.scanned(try Self.code("B11300001"))
        model.importPending()
        await model.lookupTask?.value

        #expect(!model.isFinished)
        #expect(model.pending != nil)
        #expect(model.prompt?.title == String(localized: "class_table_import_failed"))
        #expect(protectedStore.people.isEmpty)
        #expect(protectedStore.shownPersonID == nil)
        #expect(try Data(contentsOf: folder.file) == kept)
    }

    @Test("Import saves the person with each term's courses, shows them and closes")
    func importSaves() async throws {
        lookup.courses = [
            "1151": [Self.course("CS1010001", "資料結構", semester: "1151")],
            "1142": [Self.course("EE1010002", "電路學", semester: "1142")],
        ]
        let model = makeModel()
        model.scanned(try Self.code("B11300001", [Self.fall, Self.spring]))
        model.nickname = "小明"

        model.importPending()
        #expect(model.isLookingUp)
        #expect(!model.canImport)
        await model.lookupTask?.value

        let person = try #require(store.people.first)
        #expect(store.people.count == 1)
        #expect(person.nickname == "小明")
        #expect(person.studentId == "B11300001")
        #expect(person.terms.map(\.semester) == ["1151", "1142"])
        #expect(person.terms.map { $0.courses.map(\.courseName) } == [["資料結構"], ["電路學"]])
        #expect(store.shownPersonID == person.id)
        #expect(model.isFinished)
        #expect(!model.isLookingUp)
        #expect(lookup.calls == ["1151", "1142"])
    }

    @Test("Import tapped again while the lookup runs starts no second one")
    func importOnce() async throws {
        let model = makeModel()
        model.scanned(try Self.code("B11300001"))

        model.importPending()
        model.importPending()
        await model.lookupTask?.value
        model.importPending()

        #expect(lookup.calls == ["1151"])
        #expect(store.people.count == 1)
    }

    @Test("a failed lookup saves nothing, even after an earlier term answered, and Retry imports")
    func lookupFailureSavesNothing() async throws {
        lookup.courses = ["1151": [Self.course("CS1010001", "資料結構", semester: "1151")]]
        lookup.failing = ["1142"]
        let model = makeModel()
        model.scanned(try Self.code("B11300001", [Self.fall, Self.spring]))
        model.importPending()
        await model.lookupTask?.value

        guard case .lookupFailed(let job) = model.prompt else {
            Issue.record("expected the lookup-failed prompt, got \(String(describing: model.prompt))")
            return
        }
        #expect(model.prompt?.title == String(localized: "class_table_import_lookup_failed"))
        #expect(model.prompt?.message == nil)
        #expect(store.people.isEmpty)
        #expect(!model.isFinished)
        #expect(Self.reloadedPeople(folder).isEmpty)
        model.dismissPrompt()
        #expect(model.pending != nil, "Cancel leaves the confirm screen up")

        lookup.failing = []
        model.lookUp(job)
        await model.lookupTask?.value
        #expect(store.people.map(\.studentId) == ["B11300001"])
        #expect(model.isFinished)
    }

    @Test("an alert shows on the screen in front: the confirm screen's failed lookup there, the rest under it")
    func promptsShowOnTheScreenInFront() async throws {
        let refused = makeModel()
        refused.scanned(Self.damaged)
        #expect(refused.promptShown(onConfirmScreen: false) == .invalid)
        #expect(refused.promptShown(onConfirmScreen: true) == nil)

        lookup.failing = ["1151"]
        let failed = makeModel()
        failed.scanned(try Self.code("B11300001"))
        failed.importPending()
        await failed.lookupTask?.value
        guard case .lookupFailed = failed.promptShown(onConfirmScreen: true) else {
            Issue.record("expected the lookup-failed prompt on the confirm screen")
            return
        }
        #expect(failed.promptShown(onConfirmScreen: false) == nil)
    }

    @Test("updating keeps the nickname, skips the nickname step and takes the new terms")
    func updateKeepsNickname() async throws {
        let first = try ClassTableShareCode.decode(try Self.code("B11300001"))
        let ming = try #require(store.add(first, nickname: "小明", courses: [:]))
        store.add(try ClassTableShareCode.decode(try Self.code("B11300002")), nickname: "小華", courses: [:])
        lookup.courses = ["1142": [Self.course("EE1010002", "電路學", semester: "1142")]]
        let model = makeModel()
        model.scanned(try Self.code("B11300001", [Self.spring]))
        guard case .replace(let job) = model.prompt else {
            Issue.record("expected the replace prompt, got \(String(describing: model.prompt))")
            return
        }

        model.lookUp(job)
        #expect(model.pending == nil)
        #expect(model.isLookingUp)
        await model.lookupTask?.value

        #expect(store.people.map(\.nickname) == ["小明", "小華"])
        let updated = try #require(store.person(withStudentId: "B11300001"))
        #expect(updated.id == ming.id)
        #expect(updated.terms.map(\.semester) == ["1142"])
        #expect(updated.terms.first?.courses.map(\.courseName) == ["電路學"])
        #expect(store.shownPersonID == ming.id)
        #expect(model.isFinished)
    }

    @Test("an update, which has no confirm screen, is shown as updating until its lookup ends or fails")
    func updateShowsProgress() async throws {
        store.add(try ClassTableShareCode.decode(try Self.code("B11300001")), nickname: "小明", courses: [:])
        lookup.failing = ["1142"]
        let model = makeModel()
        model.linkOpened(try Self.code("B11300001", [Self.spring]))
        guard case .replace(let job) = model.prompt else {
            Issue.record("expected the replace prompt, got \(String(describing: model.prompt))")
            return
        }
        #expect(!model.isUpdating)

        model.lookUp(job)
        #expect(model.isUpdating)
        await model.lookupTask?.value
        #expect(!model.isUpdating)
        #expect(model.prompt == .lookupFailed(job))

        lookup.failing = []
        model.lookUp(job)
        #expect(model.isUpdating)
        await model.lookupTask?.value
        #expect(!model.isUpdating)
        #expect(model.isFinished)

        let fresh = makeModel()
        fresh.linkOpened(try Self.code("B11300002"))
        fresh.importPending()
        #expect(fresh.isLookingUp)
        #expect(!fresh.isUpdating, "a new person's lookup shows on its confirm screen")
        await fresh.lookupTask?.value
    }

    @Test("a failed update saves nothing, and Cancel goes back to scanning")
    func failedUpdateKeepsThePerson() async throws {
        store.add(try ClassTableShareCode.decode(try Self.code("B11300001")), nickname: "小明", courses: [:])
        lookup.failing = ["1142"]
        let model = makeModel()
        model.scanned(try Self.code("B11300001", [Self.spring]))
        guard case .replace(let job) = model.prompt else {
            Issue.record("expected the replace prompt, got \(String(describing: model.prompt))")
            return
        }

        model.lookUp(job)
        await model.lookupTask?.value

        #expect(model.promptShown(onConfirmScreen: false) == .lookupFailed(job), "an update has only the scanner to alert on")
        #expect(store.person(withStudentId: "B11300001")?.terms.map(\.semester) == ["1151"])
        model.dismissPrompt()
        #expect(model.isIdle)
    }

    @Test("Cancel during the lookup saves nothing, even when the lookup answers afterwards")
    func cancelDuringLookup() async throws {
        let gate = Gate()
        let model = gatedModel(gate)
        model.scanned(try Self.code("B11300001"))
        model.importPending()
        try await Self.waitUntil { gate.isWaiting }
        let lookup = model.lookupTask

        model.cancel()
        gate.open()
        await lookup?.value

        #expect(store.people.isEmpty)
        #expect(Self.reloadedPeople(folder).isEmpty)
        #expect(!model.isFinished)
        #expect(model.pending == nil)
        #expect(!model.isLookingUp)
    }

    @Test("Cancel during an update leaves the person's courses as they were")
    func cancelDuringUpdate() async throws {
        store.add(try ClassTableShareCode.decode(try Self.code("B11300001")), nickname: "小明", courses: [:])
        let gate = Gate()
        let model = gatedModel(gate)
        model.scanned(try Self.code("B11300001", [Self.spring]))
        guard case .replace(let job) = model.prompt else {
            Issue.record("expected the replace prompt, got \(String(describing: model.prompt))")
            return
        }
        model.lookUp(job)
        try await Self.waitUntil { gate.isWaiting }
        let lookup = model.lookupTask

        model.cancel()
        gate.open()
        await lookup?.value

        #expect(store.person(withStudentId: "B11300001")?.terms.map(\.semester) == ["1151"])
        #expect(!model.isFinished)
        #expect(model.isIdle)
    }

    private func gatedModel(_ gate: Gate) -> ClassTableImportModel {
        ClassTableImportModel(
            store: store,
            signedInStudentId: { Self.signedIn },
            isCurrent: { true },
            lookup: { semester, _ in
                await gate.wait()
                return [Self.course("CS1010001", "資料結構", semester: semester)]
            }
        )
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        try #require(condition())
    }

    @Test("a sign-out during the lookup saves nothing and closes the import")
    func signOutSavesNothing() async throws {
        var generation = 1
        let model = ClassTableImportModel(
            store: store,
            signedInStudentId: { Self.signedIn },
            isCurrent: { generation == 1 },
            lookup: { semester, _ in
                generation += 1
                return [Self.course("CS1010001", "資料結構", semester: semester)]
            }
        )
        model.scanned(try Self.code("B11300001"))

        model.importPending()
        await model.lookupTask?.value

        #expect(store.people.isEmpty)
        #expect(Self.reloadedPeople(folder).isEmpty)
        #expect(store.shownPersonID == nil)
        #expect(model.prompt == nil)
        #expect(model.isFinished)
    }

    private static func reloadedPeople(_ folder: Folder) -> [ImportedPerson] {
        ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { signedIn }).people
    }

    private static func qrImage(_ text: String) throws -> Data {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        let code = try #require(filter.outputImage).samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let margin: CGFloat = 64
        let page = code.transformed(by: CGAffineTransform(translationX: margin, y: margin))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(
                x: 0, y: 0, width: code.extent.width + 2 * margin, height: code.extent.height + 2 * margin
            )))
        return try png(page)
    }

    private static func blankImage() throws -> Data {
        try png(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400)))
    }

    private static func png(_ image: CIImage) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace))
    }
}
