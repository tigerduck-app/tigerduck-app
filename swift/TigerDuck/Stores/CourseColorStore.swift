import Foundation
import Observation

/// A user's choice of course colours.
enum CourseColorEdit {
    /// The colour picked for a course; a course that held it gets another.
    case pick(UInt32, courseNo: String)
    /// Fresh colours for every course, forgetting the picks.
    case reassignAll(courseNos: [String])
}

/// The colour of each course, kept by `ColorState` in `CourseColorFiles`. `revision` moves each
/// time the map is saved, which `DeviceSurfaceSyncer` and the course views observe.
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

    private func saving<Result>(_ body: (ColorState) -> Result) -> Result {
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

    func ensureAssignments(courseNos: [String], palette: [UInt32]) {
        saving { $0.ensureAssignments(courseNos: courseNos, palette: palette) }
    }

    /// Colours another device picked, applied without counting as picks here.
    @discardableResult
    func applyColors(_ colors: [(courseNo: String, hex: UInt32)], palette: [UInt32]) -> Bool {
        saving { $0.applyColors(colors, palette: palette) }
    }

    /// Reads the map again, as after a sign-out cleared its file.
    func reload() {
        let before = state.snapshot()
        state.reload()
        if state.snapshot() != before { revision &+= 1 }
    }

    /// The courses whose colour changed, the picked one among them.
    @discardableResult
    func apply(_ edit: CourseColorEdit, palette: [UInt32]) -> [String: UInt32] {
        switch edit {
        case let .pick(hex, courseNo):
            return saving { $0.setColor(hex: hex, for: courseNo, palette: palette) }
        case let .reassignAll(courseNos):
            saving { $0.reassignAll(courseNos: courseNos, palette: palette) }
            return [:]
        }
    }
}
