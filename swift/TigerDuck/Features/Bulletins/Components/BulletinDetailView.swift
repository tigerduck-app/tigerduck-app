import SwiftUI
import os

struct BulletinDetailView: View {
    let bulletin: BulletinAPI.BulletinSummary
    let taxonomy: BulletinTaxonomyStore

    @Environment(AppState.self) private var appState
    @State private var detail: BulletinAPI.BulletinDetail?
    @State private var loadError: String?
    @State private var isLoading: Bool = false
    @State private var showInAppBrowser: Bool = false

    private let apiClient: BulletinAPIClient = BulletinAPIClient(
        baseURL: PushCoordinator.resolveServerURL(),
        sharedSecret: PushCoordinator.resolveSharedSecret()
    )
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.Detail")

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                    header

                    Text(bulletin.displayTitle)
                        .font(TigerDuckTheme.Typography.title)
                        .foregroundStyle(Color.textPrimary)

                    if !bulletin.contentTags.isEmpty {
                        tagStrip
                    }

                    Divider().background(Color.textSecondary)

                    bodyContent
                }
                .padding(TigerDuckTheme.Spacing.lg)
                .padding(.bottom, 80)
            }

            if let url = URL(string: bulletin.sourceUrl) {
                Button {
                    if appState.browserPreference == .inApp {
                        showInAppBrowser = true
                    } else {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("原文公告", systemImage: "safari")
                        .font(.callout.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.accentPrimary, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                }
                .padding(TigerDuckTheme.Spacing.lg)
            }
        }
        .background(Color.backgroundPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: bulletin.id) { await loadDetail() }
        .sheet(isPresented: $showInAppBrowser) {
            if let url = URL(string: bulletin.sourceUrl) {
                InAppBrowserView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var header: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            if let org = bulletin.canonicalOrg {
                Text(taxonomy.orgLabel(for: org))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.accentPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentPrimary.opacity(0.15), in: Capsule())
            }
            if let importance = bulletin.importance, importance != .normal {
                importanceBadge(for: importance)
            }
            if bulletin.isDeleted {
                Text("已撤下")
                    .font(TigerDuckTheme.Typography.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.textSecondary.opacity(0.2), in: Capsule())
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            if let posted = bulletin.postedAt {
                Text(posted.shortDateString)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var tagStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TigerDuckTheme.Spacing.xs) {
                ForEach(bulletin.contentTags, id: \.self) { tag in
                    Text(taxonomy.tagLabel(for: tag))
                        .font(TigerDuckTheme.Typography.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentPrimary.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentPrimary)
                }
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if isLoading, detail == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if let error = loadError {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                Text("無法載入內文")
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                Text(error)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                if let summary = bulletin.summary, !summary.isEmpty {
                    Text(summary)
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(Color.textPrimary)
                        .padding(.top, TigerDuckTheme.Spacing.md)
                }
            }
        } else if let detail {
            Text(formattedBody(detail: detail))
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let summary = bulletin.summary, !summary.isEmpty {
            Text(summary)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
                .lineSpacing(6)
        }
    }

    private func importanceBadge(for importance: BulletinAPI.Importance) -> some View {
        let label: String
        let color: Color
        switch importance {
        case .high:
            label = "重要"
            color = .orange
        case .low:
            label = "一般"
            color = .secondary
        case .normal:
            label = "常規"
            color = .gray
        }
        return Text(label)
            .font(TigerDuckTheme.Typography.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Content helpers

    /// Prefer the LLM-cleaned `body_clean` (fact-preserving summary the
    /// server classifier produces) over the raw markdown. We fall back to
    /// body_md only when body_clean is missing so older rows still render.
    private func formattedBody(detail: BulletinAPI.BulletinDetail) -> AttributedString {
        let source = detail.bodyClean?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? detail.bodyMd?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? detail.summary
            ?? ""
        if let attributed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(source)
    }

    // MARK: - Loading

    private func loadDetail() async {
        guard detail == nil else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            detail = try await apiClient.getBulletin(id: bulletin.id)
        } catch {
            logger.error("detail load failed id=\(bulletin.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
