import Foundation
import Observation

@Observable
final class CourseColorStore {
    static let shared = CourseColorStore()

    @ObservationIgnored let files: CourseColorFiles
    @ObservationIgnored let state: ColorState
    private(set) var revision = 0
    @ObservationIgnored private var movedByLateIds = SignInBound<[String: UInt32]>(empty: [:])
    @ObservationIgnored var onLateMoodleColors: () -> Void = {}

    init(files: CourseColorFiles = CourseColorFiles()) {
        self.files = files
        state = ColorState(
            load: { files.loadCourseColorMapIfReadable() },
            save: { files.saveCourseColorMap($0) },
            notePick: { files.notePickedCourseColor($0) },
            picks: { files.loadPickedCourseColors() }
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

    var map: [String: UInt32] {
        _ = revision
        return state.snapshot()
    }

    func hex(for courseNo: String, palette: [UInt32]) -> UInt32 {
        state.hex(for: courseNo, palette: palette)
    }

    func ensureAssignments(courses: [SDCourse], ids: [String: Int], palette: [UInt32], for signIn: SignIn) {
        let moodleColors = Self.moodleColors(of: courses, ids: ids)
        saving(signIn, unchanged: ()) {
            $0.ensureAssignments(courseNos: courses.map(\.courseNo), moodleColors: moodleColors, palette: palette)
        }
    }

    /// The colour Moodle gives each course whose Moodle id `ids` holds.
    static func moodleColors(of courses: [SDCourse], ids: [String: Int]) -> [String: UInt32] {
        var colors: [String: UInt32] = [:]
        for course in courses {
            guard let id = CourseLookup.moodleCourseId(idnumber: course.moodleIdNumber, in: ids) else { continue }
            colors[course.courseNo] = TigerDuckTheme.moodleCourseColor(forCourseId: id)
        }
        return colors
    }

    /// Moves the courses whose Moodle id arrived after their colour to Moodle's colour, unless
    /// the user picked one.
    func takeMoodleColors(_ colors: [String: UInt32], for signIn: SignIn) {
        let moved = saving(signIn, unchanged: [:]) { $0.takeMoodleColors(colors) }
        guard !moved.isEmpty else { return }
        movedByLateIds.set(movedByLateIds.value.merging(moved) { $1 }, for: signIn)
        onLateMoodleColors()
    }

    /// What `takeMoodleColors` moved in this sign-in, which the next full sync sends.
    /// shortcut: kept in memory, so a move not sent before the app quits is lost; store it if that shows up.
    var lateMoodleColors: [String: UInt32] { movedByLateIds.value }

    /// Colours another device picked, applied without counting as picks here.
    @discardableResult
    func applyColors(_ colors: [(courseNo: String, hex: UInt32)], palette: [UInt32], for signIn: SignIn) -> Bool {
        saving(signIn, unchanged: false) { $0.applyColors(colors, palette: palette) }
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
        saving(signIn, unchanged: [:]) { $0.setColor(hex: hex, for: courseNo, palette: palette) }
    }

    /// Fresh colours for every course the user did not pick a colour for.
    func reassignAll(courses: [SDCourse], ids: [String: Int], palette: [UInt32], for signIn: SignIn) {
        let moodleColors = Self.moodleColors(of: courses, ids: ids)
        saving(signIn, unchanged: ()) {
            $0.reassignAll(courseNos: courses.map(\.courseNo), moodleColors: moodleColors, palette: palette)
        }
    }
}
