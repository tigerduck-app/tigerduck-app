#if os(iOS)
import Defaults
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
                if viewModel.mode != .source {
                    MailTextSizeControl()
                }
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
                        Task { if let kind = await viewModel.prepareDelete() { onDelete(kind) } }
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

/// The menu stays open on a tap, so the reader sees the mail change size behind it.
struct MailTextSizeControl: View {
    @Default(.mailTextZoom) private var storedZoom

    var body: some View {
        let zoom = PageZoom.mail.clamped(storedZoom)
        let percent = PageZoom.text(zoom)
        ControlGroup {
            Button(String(localized: "school_mail_text_smaller"), systemImage: "textformat.size.smaller") {
                PageZoom.mail.smaller(than: zoom).map { storedZoom = $0 }
            }
            .disabled(PageZoom.mail.smaller(than: zoom) == nil)
            // SwiftUI hands a menu item only its title's accessibility label, not the button's label or value.
            Button { storedZoom = PageZoom.standard } label: {
                Text(percent).accessibilityLabel(Text(verbatim: "\(String(localized: "school_mail_text_size_reset")), \(percent)"))
            }
            Button(String(localized: "school_mail_text_larger"), systemImage: "textformat.size.larger") {
                PageZoom.mail.larger(than: zoom).map { storedZoom = $0 }
            }
            .disabled(PageZoom.mail.larger(than: zoom) == nil)
        }
        .menuActionDismissBehavior(.disabled)
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
