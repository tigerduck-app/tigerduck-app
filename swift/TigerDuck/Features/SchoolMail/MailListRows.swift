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
                MailListRowButton(row: item, viewModel: viewModel, actions: actions, accentColor: accentColor, policy: policy,
                                  onOpen: onOpen)
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
