import MarkdownUI
import SwiftUI
import os

/// Full-screen bulletin reader. The parent pushes this via
/// `.navigationDestination`; the nav bar stays in place (with just
/// the back-button chevron hidden) because
/// `toolbar(.hidden, for: .navigationBar)` disables the
/// interactivePopGesture on iOS — which the user explicitly needs.
/// A transparent toolbar background lets the masthead feel edge-to-
/// edge without sacrificing the system swipe-from-left-edge dismissal.
struct BulletinDetailView: View {
    let bulletin: BulletinAPI.BulletinSummary
    let taxonomy: BulletinTaxonomyStore
    /// Optional — when supplied, opening this view marks the bulletin as
    /// read so the parent list can drop the unread dot + bold weight.
    var readState: BulletinReadStateStore? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var detail: BulletinAPI.BulletinDetail?
    @State private var loadError: String?
    @State private var isLoading: Bool = false
    @State private var showInAppBrowser: Bool = false

    /// Hoisted to a static so the bulletin-detail nav push doesn't build a
    /// new client and URLSession on every appearance. The base URL is
    /// resolved per request through the default provider, so a Debug
    /// endpoint override picks up immediately without an app relaunch.
    private static let apiClient: BulletinAPIClient = BulletinAPIClient()
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.Detail")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                metaRow
                titleBlock
                Divider().background(Color.textSecondary)
                bodyContent
                if !bulletin.contentTags.isEmpty {
                    footerTagStrip
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.xxl)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.backgroundPrimary)
        .overlay(alignment: .bottomTrailing) {
            sourceLinkButton
                .padding(.trailing, TigerDuckTheme.Spacing.lg)
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: bulletin.id) {
            readState?.markRead(bulletin.id)
            await loadDetail()
        }
        .sheet(isPresented: $showInAppBrowser) {
            if let url = URL(string: bulletin.sourceUrl) {
                InAppBrowserView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Subviews

    /// Meta row: understated "department · date" text, so the department reads
    /// as attribution rather than a tag. Category labels sit at the article foot
    /// as hashtags.
    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            if let org = bulletin.canonicalOrg {
                Text(taxonomy.orgLabel(for: org))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            if let importance = bulletin.importance, importance == .high {
                importanceBadge
            }
            if bulletin.isDeleted {
                Text(String(localized: "bulletin_withdrawn_badge"))
                    .font(TigerDuckTheme.Typography.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.textSecondary.opacity(0.2), in: Capsule())
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: 0)
            if let posted = bulletin.postedAt {
                Text(posted.fullDateString)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    private var titleBlock: some View {
        Text(bulletin.displayTitle)
            .font(TigerDuckTheme.Typography.title)
            .foregroundStyle(Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHeading(.h1)
    }

    private var footerTagStrip: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Divider().background(Color.textSecondary.opacity(0.4))
            WrappingHStack(items: bulletin.contentTags, spacing: 6, lineSpacing: 6) { tag in
                Text("#\(taxonomy.tagLabel(for: tag))")
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.12), in: Capsule())
            }
        }
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if isLoading, detail == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if let error = loadError {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                Text(String(localized: "bulletin_body_load_failed"))
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                Text(error)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                if let summary = bulletin.summary, !summary.isEmpty {
                    Markdown(BulletinBodyRenderer.normalize(summary))
                        .markdownTheme(bulletinMarkdownTheme)
                        .padding(.top, TigerDuckTheme.Spacing.md)
                }
            }
        } else if let detail {
            Markdown(BulletinBodyRenderer.normalize(
                BulletinBodyRenderer.bodyMarkdown(
                    for: detail,
                    fallbackSummary: bulletin.summary
                )
            ))
                .markdownTheme(bulletinMarkdownTheme)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let summary = bulletin.summary, !summary.isEmpty {
            Markdown(BulletinBodyRenderer.normalize(summary))
                .markdownTheme(bulletinMarkdownTheme)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var sourceLinkButton: some View {
        if let url = URL(string: bulletin.sourceUrl) {
            Button {
                if appState.browserPreference == .inApp {
                    showInAppBrowser = true
                } else {
                    openURL(url)
                }
            } label: {
                Label(String(localized: "bulletin_source_link_label"), systemImage: "safari")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.tint, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
        }
    }

    private var importanceBadge: some View {
        Text(String(localized: "bulletin_importance_high_badge"))
            .font(TigerDuckTheme.Typography.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.orange)
    }

    private var bulletinMarkdownTheme: Theme {
        .bulletin(accent: appState.accentColor)
    }

    // MARK: - Loading

    private func loadDetail() async {
        guard detail == nil else { return }
        // Cache-first: the stored body is eventually replaced by a fresh
        // server fetch below, but showing the cache immediately means a
        // re-opened bulletin has no spinner at all.
        if let cached = DataCache.shared.loadBulletinDetail(id: bulletin.id) {
            detail = cached
        }
        let hadCached = detail != nil
        isLoading = !hadCached
        loadError = nil
        defer { isLoading = false }
        do {
            let fresh = try await Self.apiClient.getBulletin(id: bulletin.id)
            detail = fresh
            DataCache.shared.saveBulletinDetail(fresh)
        } catch {
            logger.error("detail load failed id=\(bulletin.id, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            // Don't surface the error when we have cached content —
            // offline-first behaviour means the user keeps reading.
            if !hadCached {
                loadError = error.localizedDescription
            }
        }
    }
}

/// Minimal flow layout used for the article-foot tag strip. iOS 16+ ships
/// `Layout`, which we use to wrap tags across multiple lines without
/// reaching for a horizontal ScrollView.
private struct WrappingHStack<Item: Hashable, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let lineSpacing: CGFloat
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: spacing, lineSpacing: lineSpacing) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}
