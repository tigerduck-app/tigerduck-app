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

    /// Hoisted to a static so the bulletin-detail nav push doesn't hit
    /// Defaults + Keychain on every appearance just to reconstruct the
    /// same client. The push-server URL / shared secret are stable for
    /// the app's lifetime — a stale resolution after the user changes
    /// the override in Settings is acceptable; the next app launch
    /// rebuilds the client.
    private static let apiClient: BulletinAPIClient = BulletinAPIClient(
        baseURL: PushServerConfig.resolveServerURL(),
        sharedSecret: PushServerConfig.resolveSharedSecret()
    )
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

    /// Meta row: understated "處室 · 日期" text so the department feels like
    /// attribution rather than a tag. Category labels live at the article
    /// foot as hashtags.
    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            if let org = bulletin.canonicalOrg {
                Text(taxonomy.orgLabel(for: org))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
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
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
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
                    .background(Color.accentColor, in: Capsule())
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

    /// MarkdownUI theme tuned to match the rest of the app — we want the
    /// renderer's headers / lists / links to feel native to TigerDuck
    /// rather than MarkdownUI's GitHub-flavored defaults.
    private var bulletinMarkdownTheme: Theme {
        Theme()
            .text {
                ForegroundColor(Color.textPrimary)
            }
            .link {
                ForegroundColor(Color.accentColor)
                UnderlineStyle(.single)
            }
            .strong {
                FontWeight(.bold)
            }
            .emphasis {
                FontStyle(.italic)
            }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.25))
                    .markdownMargin(top: .em(0.6))
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.3))
            }
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
            logger.error("detail load failed id=\(bulletin.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        let maxX = bounds.maxX

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
