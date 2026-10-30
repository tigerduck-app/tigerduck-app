import Foundation

nonisolated struct MoodleCourseAPI: Sendable {
    var functions: @Sendable () async throws -> Set<String>
    var forums: @Sendable (_ courseIds: [Int]) async throws -> [MoodleForum]
    var discussions: @Sendable (_ forumId: Int, _ page: Int) async throws -> [MoodleDiscussion]
    var posts: @Sendable (_ discussionId: Int) async throws -> [MoodlePost] = { _ in [] }
    var markViewed: @Sendable (_ discussionId: Int, _ isCurrent: @escaping @MainActor @Sendable () -> Bool) async throws -> Void
    var materials: @Sendable (_ courseId: Int) async throws -> MoodleCourseMaterials = { _ in
        MoodleCourseMaterials(sections: [])
    }
    var markMaterialViewed: @Sendable (_ material: MoodleMaterial, _ isCurrent: @escaping @MainActor @Sendable () -> Bool) async throws -> Void = { _, _ in }
    var download: @Sendable (_ file: MoodleFile, _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL = { _, _ in
        throw CancellationError()
    }
    var members: @Sendable (_ courseId: Int) async throws -> MoodleMemberList = { _ in
        MoodleMemberList(ownId: nil, members: [])
    }
    var picture: @Sendable (_ url: URL) async throws -> Data = { _ in Data() }
    var updatePicture: @Sendable (_ jpeg: Data, _ isCurrent: @escaping @MainActor @Sendable () -> Bool) async throws -> Void = { _, _ in
        throw CancellationError()
    }
    var gradeItems: @Sendable (_ courseId: Int) async throws -> [MoodleGradeItem] = { _ in [] }
    var summary: @Sendable (_ courseId: Int) async throws -> MoodleCourseSummary = { _ in .empty }
    var submission: @Sendable (_ assignId: Int) async throws -> MoodleAssignmentSubmission = { _ in
        throw CancellationError()
    }
    var comments: @Sendable (_ cmid: Int, _ submissionId: Int) async throws -> [MoodleSubmissionComment] = { _, _ in [] }
    var groups: @Sendable (_ courseId: Int) async throws -> [Int: String] = { _ in [:] }
    var submissionFetched: @MainActor @Sendable (
        _ status: MoodleSubmissionStatus, _ askedAt: ContinuousClock.Instant, _ context: MoodleCacheContext
    ) -> Void = { _, _, _ in }

    static let live = MoodleCourseAPI(
        functions: {
            try await MoodleWebserviceClient.withToken { try await MoodleSiteInfoService.shared.functions(token: $0) }
        },
        forums: { courseIds in
            try await MoodleWebserviceClient.withToken { try await MoodleForumService.forums(courseIds: courseIds, token: $0) }
        },
        discussions: { forumId, page in
            try await MoodleWebserviceClient.withToken {
                try await MoodleForumService.discussions(forumId: forumId, page: page, token: $0)
            }
        },
        posts: { discussionId in
            try await MoodleWebserviceClient.withToken {
                try await MoodleForumService.posts(discussionId: discussionId, token: $0)
            }
        },
        markViewed: { discussionId, isCurrent in
            try await markDiscussionViewed(discussionId, isCurrent: isCurrent)
        },
        materials: { courseId in
            try await MoodleWebserviceClient.withToken {
                try await MoodleCourseContentsService.materials(courseId: courseId, token: $0)
            }
        },
        markMaterialViewed: { material, isCurrent in
            try await logMaterialView(material, isCurrent: isCurrent)
        },
        download: { file, progress in
            try await MoodleWebserviceClient.withToken { token in
                let key = try await MoodleSiteInfoService.shared.privateAccessKey(token: token)
                guard let source = URL(string: file.url),
                      let request = MoodleFileTransfer.downloadRequest(for: source, accessKey: key, token: token) else {
                    throw MoodleWebserviceError.malformedResponse(detail: "file URL")
                }
                return try await MoodleFileTransfer.fetch(request, mimeType: file.mimeType, expectedSize: file.size, progress: progress)
            }
        },
        members: { courseId in
            try await MoodleWebserviceClient.withToken { token in
                MoodleMemberList(
                    ownId: try await MoodleSiteInfoService.shared.userId(token: token),
                    members: try await MoodleCourseMembersService.members(courseId: courseId, token: token)
                )
            }
        },
        picture: { url in
            try await MoodleWebserviceClient.withToken { token in
                let key = try await MoodleSiteInfoService.shared.privateAccessKey(token: token)
                return try await MoodleCourseMembersService.picture(url, accessKey: key, token: token)
            }
        },
        updatePicture: { jpeg, isCurrent in
            try await updatePicture(jpeg, isCurrent: isCurrent)
        },
        gradeItems: { courseId in
            try await MoodleWebserviceClient.withToken { token in
                let userId = try await MoodleSiteInfoService.shared.userId(token: token)
                return try await MoodleGradeService.gradeItems(courseId: courseId, userId: userId, token: token)
            }
        },
        summary: { courseId in
            try await MoodleWebserviceClient.withToken {
                try await MoodleCourseSummaryService.summary(courseId: courseId, token: $0)
            }
        },
        submission: { assignId in
            try await MoodleAssignmentService.submission(assignId: assignId)
        },
        comments: { cmid, submissionId in
            try await MoodleWebserviceClient.withToken {
                try await MoodleAssignmentService.comments(cmid: cmid, submissionId: submissionId, token: $0)
            }
        },
        groups: { courseId in
            try await MoodleWebserviceClient.withToken { token in
                let userId = try await MoodleSiteInfoService.shared.userId(token: token)
                return try await MoodleAssignmentService.groups(courseId: courseId, userId: userId, token: token)
            }
        },
        submissionFetched: { status, askedAt, context in
            Task {
                await AppServiceBridge.takeSubmissionStatus(
                    status, askedAt: askedAt, cache: context.cache, isCurrent: context.isCurrent
                )
            }
        }
    )

    static func markDiscussionViewed(
        _ discussionId: Int,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        tokens: MoodleWebserviceClient.TokenSource = .keychain,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws {
        try await MoodleWebserviceClient.withToken(tokens) { token in
            guard await isCurrent(), !Task.isCancelled else { throw CancellationError() }
            try await MoodleForumService.markViewed(
                discussionId: discussionId, token: token, session: session, siteURL: siteURL
            )
        }
    }

    static func updatePicture(
        _ jpeg: Data,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        tokens: MoodleWebserviceClient.TokenSource = .keychain,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws {
        try await MoodleWebserviceClient.withToken(tokens) { token in
            try await MoodleProfilePictureService.update(
                jpeg: jpeg, token: token, isCurrent: isCurrent, session: session, siteURL: siteURL
            )
        }
    }

    static func logMaterialView(
        _ material: MoodleMaterial,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        tokens: MoodleWebserviceClient.TokenSource = .keychain,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws {
        try await MoodleWebserviceClient.withToken(tokens) { token in
            guard await isCurrent(), !Task.isCancelled else { throw CancellationError() }
            try await MoodleCourseContentsService.markViewed(material, token: token, session: session, siteURL: siteURL)
        }
    }
}
