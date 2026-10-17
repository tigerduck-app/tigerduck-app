import MarkdownUI
import SwiftUI

struct MoodleDiscussionView: View {
    let store: MoodleCourseStore
    let discussion: MoodleDiscussion
    let forum: MoodleForum

    @Environment(AppState.self) private var appState
    /// The posts unread when the opening loaded them, which keep their dot while it lasts. Nil
    /// until an opening loads the posts.
    @State private var unreadAtOpening: Set<Int>?
    @State private var isOpening = false
    @State private var files = MoodleFileOpener()
    @State private var presence = PagePresence()

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
        .refreshable { await refresh() }
        .moodleRefreshFailureNote(thread, hasContent: thread.value != nil)
        .moodleArticleChrome()
        .moodleRefreshShortcut { await refresh() }
        .moodleAutoRefresh(every: thread.ttl, fetchedAt: { thread.fetchedAt }) {
            await refresh()
        }
        // `.task` runs on every appearance; only one before the posts have loaded opens.
        .task {
            guard unreadAtOpening == nil else { return }
            await refresh()
        }
        .onAppear { presence.isShown = true }
        .onDisappear { presence.isShown = false }
        .moodleFilePresentation(files)
    }

    /// Until an opening has loaded the posts, a refresh is that opening, so Moodle hears of the
    /// view once they show. One opening runs at a time; a refresh meanwhile joins its fetch.
    private func refresh() async {
        guard unreadAtOpening == nil, !isOpening else {
            await store.refreshThread(of: discussion)
            return
        }
        isOpening = true
        defer { isOpening = false }
        unreadAtOpening = await store.openThread(of: discussion, in: forum, isShown: { presence.isShown })
    }

    @ViewBuilder
    private func repliesPlaceholder(_ thread: MoodleFeed<MoodleDiscussionThread>) -> some View {
        if let failure = thread.failure, !thread.isRefreshing {
            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                Text(MoodleFirstLoadView.message(for: failure))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "action_retry")) {
                    Task { await refresh() }
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

/// Read by an opening once its posts arrive. Retry and ⌘R open in a task that leaving the page
/// does not cancel, and a page gone by then must not tell Moodle the discussion was read.
private final class PagePresence {
    var isShown = false
}

nonisolated struct MoodleThreadEntry: Equatable, Identifiable {
    let post: MoodlePost
    let depth: Int
    /// Whom a reply nested deeper than the levels shown answers.
    let replyingTo: String?

    var id: Int { post.id }
}

nonisolated extension MoodleDiscussionThread {
    static let maxDepth = 3

    /// Missing parents and cyclic links must not hide replies. The cached first post keeps
    /// a discussion readable before its full thread arrives.
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
