#if os(iOS)
import SwiftUI

struct MailListRowsSection: View {
    let viewModel: MailListViewModel
    let accentColor: Color
    let onOpen: (MailListRow) -> Void

    var body: some View {
        let items = viewModel.displayedRows
        if items.isEmpty {
            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView().padding(.vertical, 60).centeredListRow()
            case .failed(let message):
                LoadFailureView(title: String(localized: "school_mail_load_failed_title"), message: message) {
                    Task { await viewModel.refresh() }
                }
                .centeredListRow()
            case .loaded:
                EmptyStateView(
                    icon: viewModel.unreadOnly ? "envelope.open" : "tray",
                    title: String(localized: "school_mail_empty_title"),
                    message: String(localized: "school_mail_empty_message")
                )
                .frame(height: 200)
                .centeredListRow()
            }
        } else {
            ForEach(items) { item in
                MailListRowButton(row: item, viewModel: viewModel, accentColor: accentColor, onOpen: onOpen)
            }
        }
        if !items.isEmpty || (viewModel.loadState != .idle && viewModel.loadState != .loading) {
            MailListFooter(viewModel: viewModel, hasRows: !items.isEmpty)
        }
    }
}

struct MailListFooter: View {
    let viewModel: MailListViewModel
    let hasRows: Bool

    var showsSpinner: Bool {
        (hasRows && viewModel.isPaginating)
            || (viewModel.search.indexProgress != nil && viewModel.background.indexer.isDownloading)
    }

    var text: String? {
        guard let progress = viewModel.search.indexProgress else { return nil }
        return progress.text() ?? (showsSpinner ? nil : String(localized: "school_mail_search_index_partial"))
    }

    var body: some View {
        if viewModel.search.indexProgress != nil {
            row(text: text)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "school_mail_search_index_partial"))
        } else if showsSpinner {
            row(text: nil)
        }
    }

    private func row(text: String?) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            if showsSpinner { ProgressView() }
            if let text {
                Text(text)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .centeredListRow()
    }
}

struct MailListRowButton: View {
    let row: MailListRow
    let viewModel: MailListViewModel
    let accentColor: Color
    let onOpen: (MailListRow) -> Void

    var body: some View {
        Button { onOpen(row) } label: {
            MailRowView(summary: row.summary)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(
            top: TigerDuckTheme.Spacing.xs, leading: TigerDuckTheme.Spacing.lg,
            bottom: TigerDuckTheme.Spacing.xs, trailing: TigerDuckTheme.Spacing.lg
        ))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { Task { await viewModel.toggleRead(row) } } label: {
                Label(
                    row.summary.isSeen ? String(localized: "school_mail_mark_unread") : String(localized: "school_mail_mark_read"),
                    systemImage: row.summary.isSeen ? "envelope.badge" : "envelope.open"
                )
                .labelStyle(.iconOnly)
            }
            .tint(accentColor)
        }
        .task { await viewModel.loadMoreIfNeeded(after: row) }
    }
}
#endif
