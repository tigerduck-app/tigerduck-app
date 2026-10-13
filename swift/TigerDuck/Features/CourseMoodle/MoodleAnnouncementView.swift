import MarkdownUI
import SwiftUI

/// One announcement, laid out as a school bulletin is: author and time, title, the message,
/// its attachments, and a capsule to open it in Moodle. Its content came with the list, so it
/// has nothing to load. Opening it tells Moodle once that it was read.
struct MoodleAnnouncementView: View {
    let store: MoodleCourseStore
    let discussion: MoodleDiscussion
    let open: (MoodleCourseRoute) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    /// Coming back from a screen pushed over this one is not another opening.
    @State private var didOpen = false
    #if os(iOS)
    @State private var inAppPage: InAppPage?
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                authorRow
                Text(discussion.title)
                    .font(TigerDuckTheme.Typography.title)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHeading(.h1)
                Divider().background(Color.textSecondary)
                Markdown(BulletinBodyRenderer.normalize(MoodleHTMLText.markdown(fromHTML: discussion.message)))
                    .markdownTheme(.bulletin(accent: appState.accentColor))
                    .environment(\.openURL, OpenURLAction { url in
                        openLink(url)
                        return .handled
                    })
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !discussion.attachments.isEmpty {
                    attachments
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.xxl)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.backgroundPrimary)
        .overlay(alignment: .bottomTrailing) {
            MoodleOpenCapsule(page: .discussion(discussion.id))
                .padding(.trailing, TigerDuckTheme.Spacing.lg)
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
        }
        .moodleArticleChrome()
        .task {
            guard !didOpen else { return }
            didOpen = true
            store.open(discussion)
        }
        #if os(iOS)
        .sheet(item: $inAppPage) { page in
            InAppBrowserView(url: page.url)
                .ignoresSafeArea()
        }
        #endif
    }

    /// The author opens their member page where the course's members have them.
    private var authorRow: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            if let name = discussion.authorName.map(MoodlePersonName.displayName), !name.isEmpty {
                let member = store.member(discussion.authorId)
                MoodleAvatar(name: name, size: 24, picture: member?.pictureURL.flatMap { store.pictures[$0] })
                    .task(id: member?.pictureURL) {
                        if let member { await store.loadPicture(of: member) }
                    }
                if let member {
                    Button { open(.member(member)) } label: { authorName(name) }
                        .buttonStyle(.plain)
                } else {
                    authorName(name)
                }
            }
            Spacer(minLength: 0)
            Text(discussion.created.moodleDateTimeString)
                .font(TigerDuckTheme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Color.textSecondary)
                .fixedSize()
        }
    }

    private func authorName(_ name: String) -> some View {
        Text(name)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tint)
            .lineLimit(1)
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            Text(String(localized: "school_mail_attachments"))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(discussion.attachments.enumerated()), id: \.offset) { index, file in
                    if index > 0 {
                        Divider().padding(.leading, MoodleFileRow.textInset)
                    }
                    MoodleFileRow(file: file)
                }
            }
            .presetCard(policy: appState.visualStylePolicy)
        }
        .padding(.top, TigerDuckTheme.Spacing.sm)
    }

    /// A Moodle link opens signed in; any other opens where the reader's setting says.
    private func openLink(_ url: URL) {
        if MoodleAutologinService.isMoodlePage(url) {
            Task { await openURL(MoodlePage.browserURL(url), fallback: nil) }
            return
        }
        #if os(iOS)
        if appState.browserPreference == .inApp, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            inAppPage = InAppPage(url: url)
            return
        }
        #endif
        openURL(url)
    }
}

#if os(iOS)
private struct InAppPage: Identifiable {
    let url: URL
    var id: URL { url }
}
#endif
