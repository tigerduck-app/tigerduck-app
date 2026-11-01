#if os(macOS)
import Defaults
import SwiftUI
import MarkdownUI
import os

struct MacBulletinsView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var viewModel = BulletinsViewModel()
    @Default(.bulletinsSyncedAt) private var bulletinsSyncedAt
    @State private var readStore = BulletinReadStateStore()
    private let taxonomy = BulletinTaxonomyStore.shared
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.MacView")

    @State private var selectedId: Int?
    @State private var detail: BulletinAPI.BulletinDetail?
    @State private var isLoadingDetail = false
    @State private var detailError: String?
    @State private var searchText: String = ""

    private let api = BulletinAPIClient()

    var body: some View {
        HSplitView {
            listPane
                // With `maxWidth: 420`, HSplitView drifts the divider past the user's intent when
                // the detail pane has short content, and the list hogs the width. This ceiling
                // keeps the selected bulletin the visual focus.
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
            logger.info("MacBulletinsView .task done — items=\(viewModel.filteredItems.count, privacy: .public) state=\(String(describing: viewModel.loadState), privacy: .private)")
        }
        .onDisappear { viewModel.pausePrefetch() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    SyncStatusDot(servers: [.backend], lastSynced: .at(bulletinsSyncedAt))
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        if viewModel.loadState == .loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(String(localized: "desktop_action_refresh"), systemImage: "arrow.clockwise")
                        }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(viewModel.loadState == .loading)
                    .help(String(localized: "desktop_action_refresh_help"))
                }
            }
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
            MacBulletinRow(bulletin: bulletin, isRead: readStore.isRead(bulletin.id), orgLabel: taxonomy.orgLabel(for:))
                .tag(bulletin.id)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var emptyListPlaceholder: some View {
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
            MacBulletinDetail(detail: detail, listSummary: summary(of: detail.id), orgLabel: taxonomy.orgLabel(for:))
        } else if let err = detailError {
            MacBulletinDetailError(message: err, listSummary: selectedId.flatMap(summary(of:))) {
                if let id = selectedId { Task { await loadDetail(id: id) } }
            }
        }
    }

    private func summary(of id: Int) -> String? {
        viewModel.filteredItems.first(where: { $0.id == id })?.summary
    }

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
