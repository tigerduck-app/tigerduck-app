import Foundation
import Observation

nonisolated struct EditToken: Hashable, Comparable, Sendable {
    private var count = 0

    mutating func move() {
        count &+= 1
    }

    static func < (lhs: EditToken, rhs: EditToken) -> Bool { lhs.count < rhs.count }
}

enum CourseEdit {
    case add(SDCourse, semester: String)
    case remove(courseNo: String, semester: String)
    /// Hides the course, or removes it when it was added by hand here.
    case delete(courseNo: String, semester: String)
    case unhide(courseNo: String, semester: String)
    case rename(courseNo: String, name: String?, locale: String)
    /// Forgets the term's fetched courses and the hidden, added and renamed ones.
    case resetTerm(String)
}

@Observable
final class CourseStore {
    static let shared = CourseStore()

    typealias Display = CourseDetails.CourseDisplayPreferences
    typealias Course = SDCourse
    typealias Tombstone = CourseTombstone

    @ObservationIgnored let files: CourseFiles
    @ObservationIgnored let display: () -> Display
    private(set) var revision = 0
    private(set) var editToken = EditToken()
    @ObservationIgnored private var lastReset: [String: EditToken] = [:]

    init(files: CourseFiles = CourseFiles(), display: @escaping () -> Display = { .current() }) {
        self.files = files
        self.display = display
    }

    convenience init(folders: CacheFolders, display: @escaping () -> Display = { .current() }) {
        self.init(files: CourseFiles(folders: folders), display: display)
    }

    func noteChange() {
        revision &+= 1
    }

    private func observe() {
        _ = revision
    }

    @discardableResult
    private func write(_ signIn: SignIn, _ body: (CourseFiles) -> Void) -> Bool {
        guard signIn.isCurrent else { return false }
        body(files)
        revision &+= 1
        return true
    }

    func loadCourses(semester: String) -> [SDCourse] {
        observe()
        return files.loadCourses(semester: semester)
    }

    func loadUserAddedCourses() -> [SDCourse] {
        observe()
        return files.loadUserAddedCourses()
    }

    func loadUserAddedCourses(semester: String) -> [SDCourse] {
        observe()
        return files.loadUserAddedCourses(semester: semester)
    }

    static func userAddedCourse(_ course: SDCourse, belongsTo semester: String) -> Bool {
        CourseFiles.userAddedCourse(course, belongsTo: semester)
    }

    func loadDeletedCourseNos() -> [String] {
        observe()
        return files.loadDeletedCourseNos()
    }

    func loadCourseCustomNames() -> [String: [String: String]] {
        observe()
        return files.loadCourseCustomNames()
    }

    func loadCourseCustomNamesFlat() -> [String: String] {
        observe()
        return files.loadCourseCustomNamesFlat()
    }

    func loadSelectionDroppedNos() -> [String: [String]] {
        observe()
        return files.loadSelectionDroppedNos()
    }

    func loadServerDroppedNos(semester: String) -> Set<String> {
        observe()
        return files.loadServerDroppedNos(semester: semester)
    }

    func loadSemesterResetAt() -> [String: Date] {
        files.loadSemesterResetAt()
    }

    @discardableResult
    func saveCourses(_ courses: [SDCourse], semester: String, for signIn: SignIn) -> Bool {
        write(signIn) { $0.saveCourses(courses, semester: semester) }
    }

    func clearCourses(semester: String, for signIn: SignIn) { write(signIn) { $0.clearCourses(semester: semester) } }

    func removeCourses(_ courseNos: Set<String>, semester: String, for signIn: SignIn) {
        write(signIn) { $0.removeCourses(courseNos, semester: semester) }
    }

    func clearCourseCaches(for signIn: SignIn) { write(signIn) { $0.clearCourseCaches() } }
    func saveUserAddedCourses(_ courses: [SDCourse], for signIn: SignIn) { write(signIn) { $0.saveUserAddedCourses(courses) } }
    func saveDeletedCourseNos(_ courseNos: [String], for signIn: SignIn) { write(signIn) { $0.saveDeletedCourseNos(courseNos) } }

    func saveCourseCustomNames(_ names: [String: [String: String]], for signIn: SignIn) {
        write(signIn) { $0.saveCourseCustomNames(names) }
    }

    func saveSelectionDroppedNos(_ dropped: [String: [String]], for signIn: SignIn) {
        write(signIn) { $0.saveSelectionDroppedNos(dropped) }
    }

    func saveServerDroppedNos(_ courseNos: Set<String>, semester: String, for signIn: SignIn) {
        write(signIn) { $0.saveServerDroppedNos(courseNos, semester: semester) }
    }

    func recordSelectionRoster(
        semester: String, roster: [String], alsoListed: [String] = [], isFinal: Bool = false, for signIn: SignIn
    ) {
        write(signIn) { $0.recordSelectionRoster(semester: semester, roster: roster, alsoListed: alsoListed, isFinal: isFinal) }
    }

    func recordSemesterReset(_ semester: String, at date: Date = Date(), for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        files.recordSemesterReset(semester, at: date)
    }

    func clearSemesterResets(outlivedBy fetchedAt: Date, keeping owned: Set<String> = [], for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        files.clearSemesterResets(outlivedBy: fetchedAt, keeping: owned)
    }

    /// Saves a term fetched with `display` from the start of the fetch at `token`. Dropped, and
    /// false, when the language or the labels changed meanwhile, as its names would be in the old
    /// ones, or when the user reset the term since.
    @discardableResult
    func saveFetchedCourses(
        _ courses: [SDCourse], semester: String, display: Display, since token: EditToken, for signIn: SignIn
    ) -> Bool {
        guard display == self.display(), !termWasReset(semester, since: token) else { return false }
        return saveCourses(courses, semester: semester, for: signIn)
    }

    func termWasReset(_ semester: String, since token: EditToken) -> Bool {
        lastReset[semester].map { $0 > token } ?? false
    }

    /// Applies details looked up during a fetch to the term's courses as they are now, so a course
    /// added, removed or hidden meanwhile stays so. False when the details were dropped: none
    /// matched, or the language or labels changed since the lookups started with `display`.
    @discardableResult
    func applyLookedUp(
        _ found: [String: CourseData], semester: String, enrolled: Bool, display: Display, for signIn: SignIn
    ) -> Bool {
        guard !found.isEmpty, display == self.display(), signIn.isCurrent else { return false }
        var applied = false
        let current = files.loadCourses(semester: semester)
        if enrolled, current.contains(where: { found[$0.courseNo] != nil }) {
            saveCourses(current.map { course in found[course.courseNo].map(course.updated) ?? course }, semester: semester, for: signIn)
            applied = true
        }
        let userAdded = files.loadUserAddedCourses()
        let isHere = { (course: SDCourse) in Self.userAddedCourse(course, belongsTo: semester) && found[course.courseNo] != nil }
        if userAdded.contains(where: isHere) {
            saveUserAddedCourses(userAdded.map { course in
                guard isHere(course), let data = found[course.courseNo] else { return course }
                return course.updated(with: data)
            }, for: signIn)
            applied = true
        }
        return applied
    }
}

extension CourseStore {
    /// Applies a user's edit to the files as they are now. True when it changed something.
    @discardableResult
    func apply(_ edit: CourseEdit, for signIn: SignIn) -> Bool {
        guard signIn.isCurrent else { return false }
        editToken.move()
        switch edit {
        case let .add(course, semester):
            if course.semester.isEmpty { course.semester = semester }
            var userAdded = files.loadUserAddedCourses()
            userAdded.removeAll { $0.courseNo == course.courseNo && Self.userAddedCourse($0, belongsTo: semester) }
            saveUserAddedCourses(userAdded + [course], for: signIn)
            return true
        case let .remove(courseNo, semester):
            let userAdded = files.loadUserAddedCourses()
            let kept = userAdded.filter { !($0.courseNo == courseNo && Self.userAddedCourse($0, belongsTo: semester)) }
            guard kept.count != userAdded.count else { return false }
            saveUserAddedCourses(kept, for: signIn)
            return true
        case let .delete(courseNo, semester):
            write(signIn) { $0.deleteCourse(courseNo, semester: semester) }
            return true
        case let .unhide(courseNo, semester):
            return unhide(courseNo, semester: semester, for: signIn)
        case let .rename(courseNo, name, locale):
            var names = files.loadCourseCustomNames()
            names[courseNo, default: [:]][locale] = name
            if names[courseNo]?.isEmpty == true { names.removeValue(forKey: courseNo) }
            saveCourseCustomNames(names, for: signIn)
            return true
        case let .resetTerm(semester):
            resetTerm(semester, for: signIn)
            return true
        }
    }

    private func unhide(_ courseNo: String, semester: String, for signIn: SignIn) -> Bool {
        var deleted = Set(files.loadDeletedCourseNos())
        guard CourseTombstone.unhide(courseNo, semester: semester, from: &deleted) else { return false }
        saveDeletedCourseNos(Array(deleted), for: signIn)
        return true
    }

    private func resetTerm(_ semester: String, for signIn: SignIn) {
        lastReset[semester] = editToken
        let deleted = Set(files.loadDeletedCourseNos())
        saveDeletedCourseNos(Array(deleted.subtracting(CourseTombstone.entries(resetting: semester, in: deleted))), for: signIn)
        saveUserAddedCourses(files.loadUserAddedCourses().filter { !Self.userAddedCourse($0, belongsTo: semester) }, for: signIn)
        var names = files.loadCourseCustomNames()
        for courseNo in files.loadCourses(semester: semester).map(\.courseNo) {
            names.removeValue(forKey: courseNo)
        }
        saveCourseCustomNames(names, for: signIn)
        clearCourses(semester: semester, for: signIn)
    }
}

extension SDCourse {
    func updated(with data: CourseData) -> SDCourse {
        SDCourse(
            courseNo: courseNo,
            courseName: data.courseName,
            instructor: data.instructor,
            credits: data.credits,
            classroom: data.classroom,
            enrolledCount: data.enrolledCount,
            maxCount: data.maxCount,
            schedule: data.schedule,
            moodleIdNumber: moodleIdNumber,
            semester: semester,
            classroomMap: data.classroomMap,
            dimension: data.dimension,
            allYear: data.allYear,
            requireOption: data.requireOption
        )
    }
}
