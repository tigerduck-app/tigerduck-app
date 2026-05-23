#if os(macOS)
import SwiftUI
import MarkdownUI
import os

/// macOS bulletins surface — Mail-style list/detail split.
///
/// Leans on the cross-platform `BulletinsViewModel` for fetch +
/// pagination + cache merge, and `BulletinReadStateStore` for the
/// device-local read state. The view itself just owns the selection
/// and the on-demand `BulletinDetail` fetch for the right pane.
struct MacBulletinsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = BulletinsViewModel()
    @State private var readStore = BulletinReadStateStore()
    // Shared with iPhone: same fetch-once taxonomy cache, so org/tag rawIds
    // resolve to localized labels instead of leaking the raw SQL key.
    private let taxonomy = BulletinTaxonomyStore.shared
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.MacView")

    @State private var selectedId: Int?
    @State private var detail: BulletinAPI.BulletinDetail?
    @State private var isLoadingDetail = false
    @State private var detailError: String?
    @State private var searchText: String = ""

    private let api = BulletinAPIClient(
        baseURL: PushServerConfig.resolveServerURL(),
        sharedSecret: PushServerConfig.resolveSharedSecret()
    )

    var body: some View {
        HSplitView {
            listPane
                // Tighter cap than before: HSplitView lets `maxWidth: 420`
                // drift the divider past the user's intent when the right
                // pane has short content, and the list column ends up
                // hogging width. Pinning a narrower ceiling keeps the
                // bulletin reader the visual focus once one is selected.
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
            detailPane
                .frame(minWidth: 420, maxWidth: .infinity)
                .layoutPriority(1)
        }
        .task {
            logger.info("MacBulletinsView .task fired — calling loadIfNeeded against \(PushServerConfig.resolveServerURL().absoluteString, privacy: .public)")
            viewModel.searchText = searchText
            await viewModel.loadIfNeeded()
            await taxonomy.loadIfNeeded()
            logger.info("MacBulletinsView .task done — items=\(viewModel.filteredItems.count, privacy: .public) state=\(String(describing: viewModel.loadState), privacy: .public)")
        }
        .onChange(of: searchText) { _, newValue in
            viewModel.searchText = newValue
        }
        .onChange(of: selectedId) { _, newValue in
            detail = nil
            detailError = nil
            guard let id = newValue else {
                return
            }
            readStore.markRead(id)
            Task { await loadDetail(id: id) }
        }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if viewModel.loadState == .loading && viewModel.filteredItems.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if viewModel.filteredItems.isEmpty {
                emptyListPlaceholder
            } else {
                bulletinList
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "bulletin_search_prompt"), text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
        )
    }

    private var bulletinList: some View {
        List(viewModel.filteredItems, selection: $selectedId) { bulletin in
            bulletinRow(bulletin)
                .tag(bulletin.id)
        }
        .listStyle(.inset)
    }

    private func bulletinRow(_ b: BulletinAPI.BulletinSummary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(readStore.isRead(b.id) ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(b.displayTitle)
                    .font(.system(.body, design: .default).weight(readStore.isRead(b.id) ? .regular : .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let org = b.canonicalOrg, !org.isEmpty {
                        Text(taxonomy.orgLabel(for: org))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(.quaternary)
                            )
                    }
                    if let posted = b.postedAt {
                        Text(posted, format: .dateTime.month().day())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let summary = b.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var emptyListPlaceholder: some View {
        // Failed-fetch state was previously indistinguishable from
        // successful-but-empty — both rendered the tray icon. Split them
        // so a network failure surfaces the actual error.
        if case let .failed(message) = viewModel.loadState {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "wifi.exclamationmark")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(String(localized: "bulletin_body_load_failed"))
                    .font(.callout)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Button(String(localized: "action_retry")) {
                    Task { await viewModel.refresh() }
                }
                .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "tray")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(String(localized: searchText.isEmpty ? "desktop_bulletins_empty" : "desktop_bulletins_no_matches"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if selectedId == nil {
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(String(localized: "desktop_bulletins_select_one"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoadingDetail && detail == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail {
            bulletinDetail(detail)
        } else if let err = detailError {
            detailErrorPane(message: err)
        }
    }

    /// Error pane keeps the list-row `summary` visible — the bulletin's
    /// curated headline + abstract is still useful while the detail fetch
    /// is down. Mirrors `BulletinDetailView`'s offline-first behaviour.
    private func detailErrorPane(message: String) -> some View {
        let fallback = viewModel.filteredItems.first(where: { $0.id == selectedId })?.summary
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(String(localized: "bulletin_body_load_failed"))
                    .font(.headline)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(String(localized: "action_retry")) {
                if let id = selectedId { Task { await loadDetail(id: id) } }
            }
            if let fallback, !fallback.isEmpty {
                Divider()
                Markdown(BulletinBodyRenderer.normalize(fallback))
                    .markdownTheme(.basic)
            }
        }
        .padding(28)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bulletinDetail(_ d: BulletinAPI.BulletinDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(d.displayTitle)
                        .font(.title.bold())
                    HStack(spacing: 8) {
                        if let org = d.canonicalOrg, !org.isEmpty {
                            Label(taxonomy.orgLabel(for: org), systemImage: "building.2")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let posted = d.postedAt {
                            Label(posted.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                let fallback = viewModel.filteredItems
                    .first(where: { $0.id == d.id })?.summary
                let body = BulletinBodyRenderer.bodyMarkdown(
                    for: d,
                    fallbackSummary: fallback
                )
                if body.isEmpty {
                    Text(String(localized: "desktop_bulletins_no_body"))
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Markdown(BulletinBodyRenderer.normalize(body))
                        .markdownTheme(.basic)
                        .textSelection(.enabled)
                }

                if let url = URL(string: d.sourceUrl) {
                    Link(destination: url) {
                        Label(String(localized: "bulletin_source_link_label"), systemImage: "arrow.up.right.square")
                    }
                    .padding(.top, 8)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Detail fetch

    private func loadDetail(id: Int) async {
        isLoadingDetail = true
        detailError = nil
        do {
            let d = try await api.getBulletin(id: id)
            if selectedId == id {
                detail = d
            }
        } catch {
            if selectedId == id {
                detailError = (error as NSError).localizedDescription
            }
        }
        if selectedId == id {
            isLoadingDetail = false
        }
    }
}
#endif
