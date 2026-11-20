import Foundation
import Observation

@Observable
final class CourseColorStore {
    static let shared = CourseColorStore()

    @ObservationIgnored let files: CourseColorFiles
    @ObservationIgnored let state: ColorState
    private(set) var revision = 0
    @ObservationIgnored var onLateMoodleColors: () -> Void = {}

    init(files: CourseColorFiles = CourseColorFiles()) {
        self.files = files
        state = ColorState(
            load: { files.loadCourseColorMapIfReadable() },
            save: { files.saveCourseColorMap($0) },
            notePick: { files.notePickedCourseColor($0) },
            forgetPicks: { files.savePickedCourseColors([]) }
        )
    }

    init(files: CourseColorFiles, state: ColorState) {
        self.files = files
        self.state = state
    }

    private func saving<Result>(_ signIn: SignIn, unchanged: Result, _ body: (ColorState) -> Result) -> Result {
        guard signIn.isCurrent else { return unchanged }
        let saves = state.saves
        let result = body(state)
        if state.saves != saves { revision &+= 1 }
        return result
    }

    private func changingWaits(_ signIn: SignIn, _ change: (inout MoodleColorWaits) -> Void) {
        guard signIn.isCurrent else { return }
        let waits = files.loadMoodleColorWaits()
        var changed = waits
        change(&changed)
        if changed != waits { files.saveMoodleColorWaits(changed) }
    }

    var map: [String: UInt32] {
        _ = revision
        return state.snapshot()
    }

    func hex(for courseNo: String, palette: [UInt32]) -> UInt32 {
        state.hex(for: courseNo, palette: palette)
    }

    /// Gives each new course a colour and moves each course awaiting its Moodle colour whose id
    /// `ids` now holds. `ids` is read only when a course needs it.
    func ensureAssignments(courses: [SDCourse], ids: () -> [String: Int], palette: [UInt32], for signIn: SignIn) {
        let before = state.snapshot()
        let awaiting = files.loadMoodleColorWaits().awaiting
        let looksUp = courses.contains { before[$0.courseNo] == nil || awaiting.contains($0.courseNo) }
        let moodleColors = looksUp ? Self.moodleColors(of: courses, ids: ids()) : [:]
        let arrived = moodleColors.filter { awaiting.contains($0.key) }
        saving(signIn, unchanged: ()) {
            $0.ensureAssignments(courseNos: courses.map(\.courseNo), moodleColors: moodleColors, palette: palette)
            $0.takeMoodleColors(arrived)
        }
        let after = state.snapshot()
        let given = courses.filter { before[$0.courseNo] == nil && after[$0.courseNo] != nil }
        changingWaits(signIn) {
            $0.awaiting.subtract(arrived.keys)
            $0.awaiting.formUnion(Self.awaitingMoodleColors(given, moodleColors))
            $0.unsent.formUnion(arrived.keys)
        }
        if !arrived.isEmpty, signIn.isCurrent { onLateMoodleColors() }
    }

    static func moodleColors(of courses: [SDCourse], ids: [String: Int]) -> [String: UInt32] {
        var colors: [String: UInt32] = [:]
        for course in courses {
            guard let id = CourseLookup.moodleCourseId(idnumber: course.moodleIdNumber, in: ids) else { continue }
            colors[course.courseNo] = TigerDuckTheme.moodleCourseColor(forCourseId: id)
        }
        return colors
    }

    private static func awaitingMoodleColors(_ courses: [SDCourse], _ moodleColors: [String: UInt32]) -> [String] {
        courses.filter { moodleColors[$0.courseNo] == nil }.map(\.courseNo)
    }

    /// The courses a late Moodle id moved, with their colour, until the backend is seen holding it.
    var lateMoodleColors: [String: UInt32] {
        let map = self.map
        return files.loadMoodleColorWaits().unsent.reduce(into: [:]) { $0[$1] = map[$1] }
    }

    func endMoodleWaits(_ courseNos: Set<String>, for signIn: SignIn) {
        guard !courseNos.isEmpty else { return }
        changingWaits(signIn) { $0.forget(Array(courseNos)) }
    }

    /// Colours another device picked, applied without counting as picks here.
    @discardableResult
    func applyColors(_ colors: [(courseNo: String, hex: UInt32)], palette: [UInt32], for signIn: SignIn) -> Bool {
        let before = state.snapshot()
        let changed = saving(signIn, unchanged: false) { $0.applyColors(colors, palette: palette) }
        if changed {
            let after = state.snapshot()
            changingWaits(signIn) { $0.forget(colors.map(\.courseNo).filter { before[$0] != after[$0] }) }
        }
        return changed
    }

    func forgetColors(for signIn: SignIn) {
        saving(signIn, unchanged: ()) { _ in files.saveCourseColorMap([:]) }
        reload()
    }

    func reload() {
        let before = state.snapshot()
        state.reload()
        if state.snapshot() != before { revision &+= 1 }
    }

    /// Gives the course the picked colour and a course that held it another. Returns every
    /// course whose colour changed.
    @discardableResult
    func pick(_ hex: UInt32, courseNo: String, palette: [UInt32], for signIn: SignIn) -> [String: UInt32] {
        let changed = saving(signIn, unchanged: [:]) { $0.setColor(hex: hex, for: courseNo, palette: palette) }
        changingWaits(signIn) { $0.forget([courseNo]) }
        return changed
    }

    /// Fresh colours for every course, final like a pick: the picks and the Moodle waits go.
    func reassignAll(courses: [SDCourse], ids: [String: Int], palette: [UInt32], for signIn: SignIn) {
        let moodleColors = Self.moodleColors(of: courses, ids: ids)
        let reset = saving(signIn, unchanged: false) {
            $0.reassignAll(courseNos: courses.map(\.courseNo), moodleColors: moodleColors, palette: palette)
        }
        guard reset else { return }
        changingWaits(signIn) { $0 = MoodleColorWaits() }
    }
}
