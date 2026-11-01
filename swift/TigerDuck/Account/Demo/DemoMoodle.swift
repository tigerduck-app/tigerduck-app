import Foundation

nonisolated struct DemoMoodle: Decodable, Sendable {
    let ownMemberId: Int?
    let courses: [Course]?

    struct Course: Decodable, Sendable {
        let courseNo: String
        let moodleId: Int
        let fullname: DemoText?
        let summary: DemoText?
        let announcements: [Announcement]?
        let grades: [Grade]?
        let members: [Member]?
        let assignments: [Assignment]?
        let forums: [Forum]?
        let materials: [Section]?
    }

    struct File: Decodable, Sendable {
        let name: String
        let size: Int?
        let mime: String?
        let modified: String?
    }

    struct Announcement: Decodable, Sendable {
        let id: Int?
        let created: String
        let pinned: Bool?
        let unread: Bool?
        let author: DemoText?
        let authorId: Int?
        let title: DemoText
        let message: DemoText
        let attachments: [File]?
    }

    struct Grade: Decodable, Sendable {
        let name: DemoText?
        let type: String?
        let module: String?
        let grade: String?
        let max: Double?
        let feedback: DemoText?
    }

    struct Member: Decodable, Sendable {
        let id: Int
        let name: DemoText
        let role: String?
        let idNumber: String?
        let email: String?
        let description: DemoText?
        let interests: [String]?
    }

    struct Assignment: Decodable, Sendable {
        let id: Int
        let cmid: Int?
        let intro: DemoText?
        let attachments: [File]?
        let teamSubmission: Bool?
        let noSubmissions: Bool?
        let submission: Submission?
    }

    struct Submission: Decodable, Sendable {
        struct Group: Decodable, Sendable {
            let id: Int
            let name: DemoText
        }

        struct Comment: Decodable, Sendable {
            let author: DemoText
            let time: String
            let content: DemoText
        }

        struct Grading: Decodable, Sendable {
            let grade: String?
            let gradedAt: String?
            let feedback: DemoText?
        }

        let status: String?
        let time: String?
        let text: DemoText?
        let files: [File]?
        let group: Group?
        let comments: [Comment]?
        let grade: Grading?
    }

    struct Forum: Decodable, Sendable {
        let id: Int
        let name: DemoText
        let intro: DemoText?
        let discussions: [Discussion]?
    }

    struct Discussion: Decodable, Sendable {
        let id: Int
        let pinned: Bool?
        let title: DemoText
        let posts: [Post]?
    }

    struct Post: Decodable, Sendable {
        let id: Int
        let parent: Int?
        let created: String?
        let author: DemoText?
        let authorId: Int?
        let message: DemoText
        let attachments: [File]?
        let unread: Bool?
        let deleted: Bool?
    }

    struct Section: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let id: Int
            let type: String
            let name: DemoText
            let file: File?
            let files: [File]?
            let url: String?
        }

        let id: Int
        let name: DemoText?
        let items: [Item]?
    }
}

nonisolated struct DemoMoodleCourses: Sendable {
    struct Course: Sendable {
        let courseNo: String
        let moodleId: Int
        let summary: MoodleCourseSummary
        let announcements: [MoodleDiscussion]
        let grades: [MoodleGradeItem]
        let members: [MoodleMember]
        let assignments: [Assignment]
        let forums: [Forum]
        let materials: MoodleCourseMaterials

        var newsForumId: Int { moodleId * 10 + 1 }
    }

    struct Assignment: Sendable {
        let id: Int
        let cmid: Int
        let intro: String
        let attachments: [MoodleFile]
        let teamSubmission: Bool
        let noSubmissions: Bool
        let submission: MoodleAssignmentSubmission?
    }

    struct Forum: Sendable {
        let id: Int
        let cmid: Int
        let name: String
        let intro: String?
        let discussions: [MoodleDiscussion]
        let posts: [Int: [MoodlePost]]
    }

    let ownMemberId: Int
    let courses: [Course]

    func course(_ moodleId: Int) -> Course? { courses.first { $0.moodleId == moodleId } }

    @MainActor
    func records(listed: [SDAssignment]) -> [MoodleAssignmentRecord] {
        let rows = Dictionary(listed.map { ($0.assignmentId, $0) }, uniquingKeysWith: { first, _ in first })
        return courses.flatMap { course in
            course.assignments.compactMap { assignment -> MoodleAssignmentRecord? in
                guard let row = rows[String(assignment.id)] else { return nil }
                return MoodleAssignmentRecord(
                    assignId: assignment.id, cmId: assignment.cmid, courseId: course.moodleId, name: row.title,
                    dueDate: row.dueDate, cutoffDate: row.cutoffDate, allowSubmissionsFromDate: nil,
                    intro: assignment.intro, noSubmissions: assignment.noSubmissions,
                    introAttachments: assignment.attachments, teamSubmission: assignment.teamSubmission
                )
            }
        }
    }
}
