import Foundation

nonisolated extension DemoMoodle {
    func courses(in language: DemoLanguage) -> DemoMoodleCourses {
        DemoMoodleCourses(
            ownMemberId: ownMemberId ?? 0,
            courses: (courses ?? []).map { DemoMoodleReader(language: language).course($0) }
        )
    }
}

private nonisolated struct DemoMoodleReader {
    let language: DemoLanguage

    private func text(_ field: DemoText?) -> String { field?.text(in: language) ?? "" }

    private func optionalText(_ field: DemoText?) -> String? {
        let value = text(field)
        return value.isEmpty ? nil : value
    }

    func course(_ course: DemoMoodle.Course) -> DemoMoodleCourses.Course {
        let id = course.moodleId
        let fullname = text(course.fullname)
        let summary = text(course.summary)
        return DemoMoodleCourses.Course(
            courseNo: course.courseNo,
            moodleId: id,
            summary: MoodleCourseSummary(
                html: summary, text: MoodleHTMLText.plainText(fromHTML: summary), names: fullname.isEmpty ? [] : [fullname]
            ),
            announcements: (course.announcements ?? []).enumerated().compactMap { announcement($1, moodleId: id, index: $0) },
            grades: (course.grades ?? []).enumerated().map { grade($1, moodleId: id, index: $0) },
            members: (course.members ?? []).map(member),
            assignments: (course.assignments ?? []).map(assignment),
            forums: (course.forums ?? []).enumerated().map { forum($1, moodleId: id, index: $0) },
            materials: MoodleCourseMaterials(sections: (course.materials ?? []).compactMap(section))
        )
    }

    private func file(_ file: DemoMoodle.File, area: String, created: Date? = nil) -> MoodleFile {
        MoodleFile(
            name: file.name, size: file.size ?? 0,
            url: "\(AppConstants.moodleBaseURL.absoluteString)/webservice/pluginfile.php/0/\(area)/\(file.name)",
            mimeType: file.mime, modified: DemoTime.date(file.modified) ?? created, path: "/"
        )
    }

    private func announcement(_ entry: DemoMoodle.Announcement, moodleId: Int, index: Int) -> MoodleDiscussion? {
        guard let created = DemoTime.date(entry.created) else { return nil }
        let id = entry.id ?? moodleId * 100 + index + 1
        let message = text(entry.message)
        return MoodleDiscussion(
            id: id, postId: id * 10, title: text(entry.title), message: message,
            preview: MoodleHTMLText.plainText(fromHTML: message), created: created, modified: created,
            isPinned: entry.pinned ?? false, unreadCount: entry.unread == true ? 1 : 0, replyCount: 0,
            authorName: optionalText(entry.author),
            attachments: (entry.attachments ?? []).map { file($0, area: "mod_forum/attachment/\(id * 10)", created: created) },
            authorId: entry.authorId
        )
    }

    private func grade(_ entry: DemoMoodle.Grade, moodleId: Int, index: Int) -> MoodleGradeItem {
        let type = entry.type ?? "mod"
        let id = moodleId * 100 + index + 1
        return MoodleGradeItem(
            id: id, name: text(entry.name), type: type, module: entry.module, cmid: type == "mod" ? id : nil,
            grade: entry.grade, maxGrade: entry.max, isHidden: false,
            feedback: BulletinBodyRenderer.normalize(MoodleHTMLText.markdown(fromHTML: text(entry.feedback)))
        )
    }

    private func member(_ entry: DemoMoodle.Member) -> MoodleMember {
        MoodleMember(
            id: entry.id, fullName: text(entry.name), idNumber: entry.idNumber, email: entry.email, groups: [],
            roles: [MoodleMember.Role(shortName: entry.role ?? "student", name: "", sortOrder: 0)],
            pictureURL: nil, description: text(entry.description), interests: entry.interests ?? [], fields: []
        )
    }

    private func assignment(_ entry: DemoMoodle.Assignment) -> DemoMoodleCourses.Assignment {
        let cmid = entry.cmid ?? entry.id * 10
        return DemoMoodleCourses.Assignment(
            id: entry.id, cmid: cmid, intro: text(entry.intro),
            attachments: (entry.attachments ?? []).map { file($0, area: "mod_assign/introattachment/\(cmid)") },
            teamSubmission: entry.teamSubmission ?? false, noSubmissions: entry.noSubmissions ?? false,
            submission: entry.submission.map { submission($0, assignId: entry.id) }
        )
    }

    /// As `mod_assign_get_submission_status` answers it.
    private func submission(_ entry: DemoMoodle.Submission, assignId: Int) -> MoodleAssignmentSubmission {
        let id = assignId * 10 + 1
        let comments = (entry.comments ?? []).enumerated().compactMap { index, comment -> MoodleSubmissionComment? in
            guard let created = DemoTime.date(comment.time) else { return nil }
            return MoodleSubmissionComment(
                id: id * 10 + index + 1, authorName: text(comment.author), created: created, content: text(comment.content)
            )
        }
        let grading = entry.grade.map {
            MoodleAssignmentGrade(grade: $0.grade, gradedAt: DemoTime.date($0.gradedAt), feedback: optionalText($0.feedback))
        }
        return MoodleAssignmentSubmission(
            status: entry.status ?? "new", modified: DemoTime.date(entry.time),
            files: (entry.files ?? []).map { file($0, area: "assignsubmission_file/submission_files/\(id)") },
            onlineText: optionalText(entry.text), id: id, takesComments: true, groupId: entry.group?.id,
            groupName: optionalText(entry.group?.name), comments: comments,
            grade: grading.flatMap { $0.grade != nil || $0.feedback != nil ? $0 : nil }
        )
    }

    private func forum(_ entry: DemoMoodle.Forum, moodleId: Int, index: Int) -> DemoMoodleCourses.Forum {
        let threads = (entry.discussions ?? []).compactMap(thread)
        return DemoMoodleCourses.Forum(
            id: entry.id, cmid: moodleId * 10 + 3 + index, name: text(entry.name), intro: optionalText(entry.intro),
            discussions: threads.map(\.discussion),
            posts: Dictionary(threads.map { ($0.discussion.id, $0.posts) }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// Titled as Moodle titles a thread: the first post by the discussion, each reply "Re:" it.
    private func thread(_ entry: DemoMoodle.Discussion) -> (discussion: MoodleDiscussion, posts: [MoodlePost])? {
        let title = text(entry.title)
        let posts = (entry.posts ?? []).enumerated().map { index, post in
            self.post(post, subject: index == 0 ? title : "Re: \(title)")
        }
        guard let first = posts.first else { return nil }
        let created = first.created ?? .distantPast
        let discussion = MoodleDiscussion(
            id: entry.id, postId: first.id, title: title, message: first.message,
            preview: MoodleHTMLText.plainText(fromHTML: first.message), created: created,
            modified: posts.compactMap(\.created).max() ?? created, isPinned: entry.pinned ?? false,
            unreadCount: posts.filter(\.isUnread).count, replyCount: posts.count - 1, authorName: first.authorName,
            attachments: first.attachments, authorId: entry.posts?.first?.authorId
        )
        return (discussion, posts)
    }

    private func post(_ entry: DemoMoodle.Post, subject: String) -> MoodlePost {
        let created = DemoTime.date(entry.created)
        return MoodlePost(
            id: entry.id, parentId: entry.parent, subject: subject, message: text(entry.message), created: created,
            authorName: optionalText(entry.author),
            attachments: (entry.attachments ?? []).map { file($0, area: "mod_forum/attachment/\(entry.id)", created: created) },
            isUnread: entry.unread ?? false, isDeleted: entry.deleted ?? false
        )
    }

    private func section(_ entry: DemoMoodle.Section) -> MoodleMaterialSection? {
        let materials = (entry.items ?? []).compactMap(material)
        guard !materials.isEmpty else { return nil }
        return MoodleMaterialSection(id: entry.id, name: text(entry.name), materials: materials)
    }

    private func material(_ item: DemoMoodle.Section.Item) -> MoodleMaterial? {
        let area = "mod_\(item.type)/content/\(item.id)"
        let content: (module: String, content: MoodleMaterial.Content)?
        switch item.type {
        case "file":
            content = item.file.map { ("resource", MoodleMaterial.Content.file(file($0, area: area))) }
        case "folder":
            let files = (item.files ?? []).map { file($0, area: area) }
            content = files.isEmpty ? nil : ("folder", MoodleMaterial.Content.folder(files))
        case "link":
            content = item.url.flatMap(URL.init(string:)).map { ("url", MoodleMaterial.Content.link($0)) }
        default:
            content = nil
        }
        guard let content else { return nil }
        return MoodleMaterial(id: item.id, instance: item.id, module: content.module, name: text(item.name), content: content.content)
    }
}
