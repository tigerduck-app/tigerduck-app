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
                centered { ProgressView().padding(.vertical, 60) }
            case .failed(let message):
                centered {
                    LoadFailureView(title: String(localized: "school_mail_load_failed_title"), message: message) {
                        Task { await viewModel.refresh() }
                    }
                }
            case .loaded:
                centered {
                    EmptyStateView(
                        icon: viewModel.unreadOnly ? "envelope.open" : "tray",
                        title: String(localized: "school_mail_empty_title"),
                        message: String(localized: "school_mail_empty_message")
                    )
                    .frame(height: 200)
                }
            }
        } else {
            ForEach(items) { item in
                MailListRowButton(row: item, viewModel: viewModel, accentColor: accentColor, onOpen: onOpen)
            }
            if viewModel.isPaginating {
                centered { ProgressView().padding(.vertical, TigerDuckTheme.Spacing.md) }
            }
        }
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
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
