import Foundation
import Observation

@Observable
final class CourseColorStore {
    static let shared = CourseColorStore()

    @ObservationIgnored let files: CourseColorFiles
    @ObservationIgnored let state: ColorState
    private(set) var revision = 0

    init(files: CourseColorFiles = CourseColorFiles()) {
        self.files = files
        files.dropColorsFromBeforeHashV2()
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

    var map: [String: UInt32] {
        _ = revision
        return state.snapshot()
    }

    func hex(for courseNo: String, palette: [UInt32]) -> UInt32 {
        state.hex(for: courseNo, palette: palette)
    }

    func ensureAssignments(courseNos: [String], palette: [UInt32], for signIn: SignIn) {
        saving(signIn, unchanged: ()) { $0.ensureAssignments(courseNos: courseNos, palette: palette) }
    }

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

    /// Fresh colours for every course, forgetting the picks.
    func reassignAll(courseNos: [String], palette: [UInt32], for signIn: SignIn) {
        saving(signIn, unchanged: ()) { $0.reassignAll(courseNos: courseNos, palette: palette) }
    }
}
