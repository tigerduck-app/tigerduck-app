#if os(iOS)
import SwiftUI

struct MailListRowsSection: View {
    let viewModel: MailListViewModel
    let actions: MailRowActions
    let accentColor: Color
    let policy: VisualStylePolicy
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
                MailListRowButton(row: item, viewModel: viewModel, actions: actions, accentColor: accentColor, policy: policy,
                                  onOpen: onOpen)
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
    let actions: MailRowActions
    let accentColor: Color
    let policy: VisualStylePolicy
    let onOpen: (MailListRow) -> Void

    var body: some View {
        let canFlag = viewModel.canFlag(row.folder)
        Button { onOpen(row) } label: {
            MailRowView(summary: row.summary, showsFlag: canFlag, policy: policy)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(
            top: TigerDuckTheme.Spacing.xs, leading: TigerDuckTheme.Spacing.lg,
            bottom: TigerDuckTheme.Spacing.xs, trailing: TigerDuckTheme.Spacing.lg
        ))
        .swipeActions(edge: .leading) { swipeButton(.toggleRead) }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            ForEach(MailRowAction.trailing(canFlag: canFlag), id: \.self, content: swipeButton)
        }
        .task { await viewModel.loadMoreIfNeeded(after: row) }
    }

    private func swipeButton(_ action: MailRowAction) -> some View {
        Button { actions.perform(action, on: row, in: viewModel) } label: {
            Label(action.title(for: row.summary), systemImage: action.icon(for: row.summary))
                .labelStyle(.iconOnly)
        }
        .tint(tint(of: action))
    }

    private func tint(of action: MailRowAction) -> Color {
        switch action {
        case .trash: .red
        case .toggleFlag: .orange
        case .more: .gray
        default: accentColor
        }
    }
}

struct MailListNotices: View {
    let viewModel: MailListViewModel

    var body: some View {
        if let notice = viewModel.sentCopyNotice {
            banner(notice, systemImage: "tray.and.arrow.down") { viewModel.dismissSentCopyNotice() }
        }
        if let error = viewModel.status.actionError {
            banner(error, systemImage: "xmark.octagon.fill") { viewModel.status.actionError = nil }
        }
    }

    private func banner(_ message: String, systemImage: String, dismiss: @escaping () -> Void) -> some View {
        MailWarningBanner(message: message, systemImage: systemImage,
                          actionTitle: String(localized: "settings_acknowledged"), action: dismiss)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
#endif
