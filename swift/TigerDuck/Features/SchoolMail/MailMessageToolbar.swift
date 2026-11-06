#if os(iOS)
import SwiftUI

enum MailDeleteConfirmation { case toTrash, permanent }

struct MailMessageToolbar: ToolbarContent {
    @Bindable var viewModel: MailMessageViewModel
    let onCompose: (MailComposeMode) -> Void
    let onMove: () -> Void
    let onDelete: (MailDeleteConfirmation) -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(MailRowAction.composeModes, id: \.self) { mode in
                    Button { onCompose(mode) } label: { label(.compose(mode)) }
                }
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
                    .accessibilityLabel(String(localized: "school_mail_reply_menu"))
            }
            .disabled(viewModel.detail == nil)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Picker(String(localized: "school_mail_view_mode"), selection: $viewModel.mode) {
                        ForEach(viewModel.availableModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }
                if viewModel.offersLightMode {
                    Section {
                        Toggle(isOn: $viewModel.viewsInLightMode) {
                            Label(String(localized: "school_mail_view_light_mode"), systemImage: "sun.max")
                        }
                    }
                }
                Section {
                    Button { Task { await viewModel.toggleSeen() } } label: { label(.toggleRead) }
                    Button { onMove() } label: { label(.move) }
                        .disabled(viewModel.isMoving)
                }
                Section {
                    Button(role: .destructive) {
                        Task { onDelete(await viewModel.prepareDelete() ? .permanent : .toTrash) }
                    } label: {
                        label(.trash)
                    }
                    .disabled(viewModel.isMoving)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(String(localized: "school_mail_message_actions"))
            }
        }
    }

    private func label(_ action: MailRowAction) -> some View {
        Label(action.title(for: viewModel.detail?.summary), systemImage: action.icon(for: viewModel.detail?.summary))
    }
}

struct MailMoveSheet: View {
    let viewModel: MailMessageViewModel
    let otherFolders: [String]
    let onMove: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(MailFolderRole.allCases.filter {
                    viewModel.folderRoles[$0] != nil && viewModel.folderRoles[$0] != viewModel.route.folder
                }, id: \.self) { role in
                    Button(role.title) { onMove(viewModel.folderRoles[role]!) }
                        .disabled(viewModel.isMoving)
                }
                ForEach(otherFolders.filter { $0 != viewModel.route.folder }, id: \.self) { folder in
                    Button(ModifiedUTF7.decode(folder)) { onMove(folder) }
                        .disabled(viewModel.isMoving)
                }
            }
            .navigationTitle(String(localized: "school_mail_move_to"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel"), action: onCancel)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
