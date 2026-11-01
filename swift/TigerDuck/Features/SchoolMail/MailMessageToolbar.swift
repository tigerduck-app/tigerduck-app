#if os(iOS)
import SwiftUI

struct MailMessageToolbar: ToolbarContent {
    @Bindable var viewModel: MailMessageViewModel
    let onCompose: (MailComposeMode) -> Void
    let onMove: () -> Void
    let onDelete: (Bool) -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { onCompose(.reply) } label: { Label(String(localized: "school_mail_reply"), systemImage: "arrowshape.turn.up.left") }
                Button { onCompose(.replyAll) } label: { Label(String(localized: "school_mail_reply_all"), systemImage: "arrowshape.turn.up.left.2") }
                Button { onCompose(.forward) } label: { Label(String(localized: "school_mail_forward"), systemImage: "arrowshape.turn.up.right") }
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
                    Button { Task { await viewModel.toggleSeen() } } label: {
                        let seen = viewModel.detail?.summary.isSeen ?? true
                        Label(seen ? String(localized: "school_mail_mark_unread") : String(localized: "school_mail_mark_read"),
                              systemImage: seen ? "envelope.badge" : "envelope.open")
                    }
                    Button { onMove() } label: {
                        Label(String(localized: "school_mail_move_to"), systemImage: "folder")
                    }
                    .disabled(viewModel.isMoving)
                }
                Section {
                    Button(role: .destructive) {
                        Task { onDelete(await viewModel.prepareDelete()) }
                    } label: {
                        Label(String(localized: "school_mail_delete"), systemImage: "trash")
                    }
                    .disabled(viewModel.isMoving)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(String(localized: "school_mail_message_actions"))
            }
        }
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
