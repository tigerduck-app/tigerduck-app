import Foundation

enum MoodleCourseRoute: Hashable {
    case announcements
    case announcement(MoodleDiscussion)
    case materials
    case grades
    case members
    case member(MoodleMember)
    case forums
    case forum(MoodleForum)
    case discussion(MoodleDiscussion, in: MoodleForum)
    case assignments
    case assignment(MoodleCourseAssignments.Entry)
    case syllabus(CourseLookup.Syllabus)

    var refreshesOnItsOwn: Bool {
        switch self {
        case .announcements, .materials, .grades, .members, .forums, .forum, .discussion, .assignments: true
        // Its chrome takes the Mac's refresh shortcut and has nothing to fetch again.
        case .syllabus: true
        case .announcement, .member, .assignment: false
        }
    }
}

struct MoodleSectionRow: Identifiable, Equatable {
    enum Kind: Hashable {
        case announcements
        case materials
        case assignments
        case grades
        case members
        case forums
    }

    let kind: Kind
    let count: Int
    let hasUnread: Bool

    var id: Kind { kind }
}
