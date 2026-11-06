#if os(iOS)
import SwiftUI

struct MailRowActionsSheet: View {
    let row: MailListRow
    let canFlag: Bool
    let composing: MailComposeMode?
    let onAction: (MailRowAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var closeSize: CGFloat = 30

    var body: some View {
        List {
            Section {
                tiles
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } header: {
                header
            }
            Section {
                item(.toggleRead)
                if canFlag { item(.toggleFlag) }
                item(.move)
            }
            Section { item(.trash) }
        }
        .listStyle(.insetGrouped)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: TigerDuckTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(MailRowView.sender(of: row.summary))
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                Text(MailRowView.subject(of: row.summary))
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Spacer(minLength: 0)
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: closeSize, height: closeSize)
                    .background(Circle().fill(Color.textPrimary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "action_close"))
        }
        .textCase(nil)
        .padding(.bottom, TigerDuckTheme.Spacing.sm)
    }

    private var tiles: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: TigerDuckTheme.Spacing.sm))
            : AnyLayout(HStackLayout(spacing: TigerDuckTheme.Spacing.sm))
        return layout {
            ForEach(MailRowAction.composeModes, id: \.self) { mode in tile(.compose(mode), loading: composing == mode) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tile(_ action: MailRowAction, loading: Bool) -> some View {
        Button { onAction(action) } label: {
            VStack(spacing: TigerDuckTheme.Spacing.xs) {
                if loading {
                    ProgressView()
                } else {
                    Image(systemName: action.icon(for: row.summary))
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                Text(action.title(for: row.summary))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
            .padding(.horizontal, TigerDuckTheme.Spacing.xs)
            .background(Color.secondarySystemGroupedBackgroundCompat,
                        in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(composing != nil)
    }

    private func item(_ action: MailRowAction) -> some View {
        Button(role: action == .trash ? .destructive : nil) { onAction(action) } label: {
            Label {
                Text(action.title(for: row.summary))
                    .foregroundStyle(action == .trash ? Color.red : Color.textPrimary)
            } icon: {
                Image(systemName: action.icon(for: row.summary))
                    .foregroundStyle(action == .trash ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tint))
            }
        }
        .disabled(composing != nil)
    }
}

struct MailRowActionsPresenter: ViewModifier {
    let list: MailListViewModel
    @Bindable var actions: MailRowActions
    @Binding var compose: MailComposeContext?

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.sheetRow, onDismiss: runAfterSheet) { row in
                MailRowActionsSheet(row: row, canFlag: list.canFlag(row.folder), composing: actions.composing) {
                    choose($0, on: row)
                }
            }
            .sheet(item: $actions.moving) { pending in
                MailMoveSheet(viewModel: pending.model, otherFolders: list.otherFolders, onMove: { folder in
                    actions.moving = nil
                    Task { await actions.move(pending, to: folder, in: list) }
                }, onCancel: { actions.moving = nil })
            }
            .confirmationDialog(String(localized: "school_mail_delete_forever_title"), isPresented: Binding(
                get: { actions.deletingForever != nil }, set: { if !$0 { actions.deletingForever = nil } }
            ), titleVisibility: .visible, presenting: actions.deletingForever) { pending in
                Button(String(localized: "school_mail_delete"), role: .destructive) {
                    Task { await actions.deleteForever(pending, in: list) }
                }
            } message: { _ in
                Text(String(localized: "school_mail_delete_forever_message"))
            }
    }

    private func runAfterSheet() {
        let next = actions.afterSheet
        actions.afterSheet = nil
        next?()
    }

    private func choose(_ action: MailRowAction, on row: MailListRow) {
        guard case .compose(let mode) = action else {
            actions.afterSheet = { actions.perform(action, on: row, in: list) }
            actions.sheetRow = nil
            return
        }
        Task {
            let context = await actions.compose(mode, row: row, in: list)
            guard actions.sheetRow?.id == row.id else { return }
            actions.afterSheet = { compose = context }
            actions.sheetRow = nil
        }
    }
}
#endif
