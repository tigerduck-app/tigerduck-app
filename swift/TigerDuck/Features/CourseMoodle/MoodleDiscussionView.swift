import MarkdownUI
import SwiftUI

/// A forum's discussion: its first post, then each reply under the post it answers, and a capsule
/// to reply in Moodle, since the app only reads forums. Until the posts load, the first post shows
/// as the list brought it. Opening the discussion tells Moodle once that it was read.
struct MoodleDiscussionView: View {
    let store: MoodleCourseStore
    let discussion: MoodleDiscussion
    let forum: MoodleForum

    @Environment(AppState.self) private var appState
    /// Coming back from a screen pushed over this one is not another opening.
    @State private var didOpen = false
    /// The posts unread when this opening began, which keep their dot while it lasts.
    @State private var unreadAtOpening: Set<Int>?
    @State private var files = MoodleFileOpener()

    var body: some View {
        let thread = store.thread(of: discussion)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(MoodleDiscussionThread.entries(of: discussion, in: thread.value)) { entry in
                    MoodlePostCard(
                        entry: entry,
                        isUnread: unreadAtOpening?.contains(entry.post.id) ?? entry.post.isUnread,
                        policy: appState.visualStylePolicy,
                        store: store,
                        discussion: discussion,
                        files: files
                    )
                }
                if thread.value == nil {
                    repliesPlaceholder(thread)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.lg)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.backgroundPrimary)
        .overlay(alignment: .bottomTrailing) {
            MoodleOpenCapsule(page: .discussion(discussion.id)) { files.forgetPendingOpen() }
                .padding(.trailing, TigerDuckTheme.Spacing.lg)
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
        }
        .refreshable { await store.refreshThread(of: discussion) }
        .moodleArticleChrome()
        .moodleRefreshShortcut { await store.refreshThread(of: discussion) }
        .moodleAutoRefresh(every: thread.ttl, fetchedAt: { thread.fetchedAt }) {
            await store.refreshThread(of: discussion)
        }
        .task {
            guard !didOpen else { return }
            didOpen = true
            unreadAtOpening = await store.openThread(of: discussion, in: forum)
        }
        .moodleFilePresentation(files)
    }

    /// Under the first post while the replies have not loaded: a spinner, or the error and a retry.
    @ViewBuilder
    private func repliesPlaceholder(_ thread: MoodleFeed<MoodleDiscussionThread>) -> some View {
        if let failure = thread.failure, !thread.isRefreshing {
            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                Text(MoodleFirstLoadView.message(for: failure))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "action_retry")) {
                    Task { await store.refreshThread(of: discussion) }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
        } else if discussion.replyCount > 0 {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, TigerDuckTheme.Spacing.md)
        }
    }
}

/// A post where its discussion shows it.
nonisolated struct MoodleThreadEntry: Equatable, Identifiable {
    let post: MoodlePost
    /// 0 for the first post, one more for each level of reply, never past
    /// ``MoodleDiscussionThread/maxDepth``.
    let depth: Int
    /// Whom a reply nested deeper than the levels shown answers.
    let replyingTo: String?

    var id: Int { post.id }
}

nonisolated extension MoodleDiscussionThread {
    static let maxDepth = 3

    /// The posts of `discussion` in reading order: each followed by its replies, oldest first. A
    /// reply to a post not among them joins the first level. With no posts fetched, or none the
    /// site lets the app fetch, the first post shows as the discussion's list brought it.
    static func entries(of discussion: MoodleDiscussion, in thread: MoodleDiscussionThread?) -> [MoodleThreadEntry] {
        let posts = thread?.posts ?? []
        guard !posts.isEmpty else {
            return [MoodleThreadEntry(post: MoodlePost(firstPostOf: discussion), depth: 0, replyingTo: nil)]
        }
        let ids = Set(posts.map(\.id))
        var replies: [Int: [MoodlePost]] = [:]
        var roots: [MoodlePost] = []
        for post in posts {
            if let parent = post.parentId, parent != post.id, ids.contains(parent) {
                replies[parent, default: []].append(post)
            } else {
                roots.append(post)
            }
        }
        var entries: [MoodleThreadEntry] = []
        var shown: Set<Int> = []
        func add(_ post: MoodlePost, level: Int, answering parent: MoodlePost?) {
            guard shown.insert(post.id).inserted else { return }
            let name = parent?.authorName.map(MoodlePersonName.displayName).flatMap { $0.isEmpty ? nil : $0 }
            entries.append(MoodleThreadEntry(
                post: post, depth: min(level, maxDepth), replyingTo: level > maxDepth ? name : nil
            ))
            for reply in replies[post.id] ?? [] {
                add(reply, level: level + 1, answering: post)
            }
        }
        for (index, root) in roots.enumerated() {
            add(root, level: index == 0 ? 0 : 1, answering: nil)
        }
        // Posts whose parents answer each other in a loop reach no root; they still show.
        for post in posts where !shown.contains(post.id) {
            add(post, level: 1, answering: nil)
        }
        return entries
    }
}

extension MoodlePost {
    /// The first post as a discussion list gives it, which does not say what is unread in it.
    nonisolated init(firstPostOf discussion: MoodleDiscussion) {
        self.init(
            id: discussion.postId,
            parentId: nil,
            subject: discussion.title,
            message: discussion.message,
            created: discussion.created,
            authorName: discussion.authorName,
            attachments: discussion.attachments,
            isUnread: false,
            isDeleted: false
        )
    }
}

/// A post in a discussion: author, time and unread dot, then its message and attachments. The
/// first post also carries the subject; a reply sits indented with a guide line per level.
private struct MoodlePostCard: View {
    let entry: MoodleThreadEntry
    let isUnread: Bool
    let policy: VisualStylePolicy
    let store: MoodleCourseStore
    let discussion: MoodleDiscussion
    let files: MoodleFileOpener
    var now: Date = AppClock.now()

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.openMoodleLink) private var openMoodleLink

    private static let indent: CGFloat = 16
    private var post: MoodlePost { entry.post }
    private var isFirst: Bool { entry.depth == 0 }
    private var authorName: String? {
        post.authorName.map(MoodlePersonName.displayName).flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        card
            .padding(.leading, CGFloat(entry.depth) * Self.indent)
            .padding(.bottom, TigerDuckTheme.Spacing.sm)
            .background(alignment: .leading) {
                HStack(spacing: Self.indent - 1) {
                    ForEach(0..<entry.depth, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.textSecondary.opacity(0.2))
                            .frame(width: 1)
                    }
                }
                .padding(.leading, Self.indent / 2 - 0.5)
                .accessibilityHidden(true)
            }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                header
                if isFirst, !post.subject.isEmpty {
                    Text(post.subject)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHeading(.h1)
                }
                if let name = entry.replyingTo {
                    Label(name, systemImage: "arrowshape.turn.up.left")
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .accessibilityLabel("\(String(localized: "school_mail_reply")) \(name)")
                }
                message
            }
            .padding(isFirst ? TigerDuckTheme.Spacing.lg : TigerDuckTheme.Spacing.md)
            if !post.isDeleted {
                attachments
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .presetCard(policy: policy)
    }

    private var header: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            if let authorName {
                MoodleAvatar(name: authorName, size: 32)
                Text(authorName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            }
            if isUnread {
                Circle()
                    .fill(.tint)
                    .frame(width: 7, height: 7)
            }
            Spacer(minLength: TigerDuckTheme.Spacing.sm)
            if let created = post.created {
                Text(created.moodlePostDateString(now: now))
                    .font(TigerDuckTheme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerAccessibilityText)
    }

    private var attachments: some View {
        let refs = post.attachments.map { MoodleFileRef(file: $0, owner: .post(post.id)) }
        return ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
            Divider().padding(.leading, MoodleFileRow.textInset)
            MoodleFileRow(
                title: ref.file.name,
                file: ref.file,
                state: store.downloadState(of: ref.file, in: ref.owner),
                tap: { files.tap(ref, among: refs, store: store) },
                share: { files.share(ref, store: store) },
                openInMoodle: {
                    files.forgetPendingOpen()
                    Task { await openURL(MoodlePage.discussion(discussion.id)) }
                }
            )
        }
    }

    @ViewBuilder
    private var message: some View {
        if post.isDeleted {
            Text(MoodleHTMLText.plainText(fromHTML: post.message))
                .font(TigerDuckTheme.Typography.body)
                .italic()
                .foregroundStyle(Color.textSecondary)
        } else {
            Markdown(BulletinBodyRenderer.normalize(MoodleHTMLText.markdown(fromHTML: post.message)))
                .markdownTheme(.bulletin(accent: appState.accentColor))
                .environment(\.openURL, OpenURLAction { url in
                    files.forgetPendingOpen()
                    openMoodleLink(url)
                    return .handled
                })
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerAccessibilityText: String {
        var style = Date.FormatStyle(date: .long, time: .shortened)
        style.timeZone = AppConstants.taipeiTimeZone
        var parts: [String] = []
        if let authorName { parts.append(authorName) }
        if isUnread { parts.append(String(localized: "bulletin_unread_dot_label")) }
        if let created = post.created { parts.append(created.formatted(style)) }
        return parts.joined(separator: ", ")
    }
}
