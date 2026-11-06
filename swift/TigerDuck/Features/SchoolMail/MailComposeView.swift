#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MailComposeView: View {
    private enum Field: Hashable { case to, cc, bcc, subject, body }

    @State private var viewModel: MailComposeViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var showLeaveDialog = false
    @State private var showSendDialog = false
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pendingPicks = 0
    @FocusState private var focused: Field?

    init(context: MailComposeContext, session: MailPageSession, folderRoles: [MailFolderRole: String], events: MailboxEvents) {
        let account = MailAccountManager.shared
        let sender = MailAddress(name: account.displayName, address: account.address ?? "")
        self.init(viewModel: MailComposeViewModel(context: context, session: session, sender: sender,
                                                  folderRoles: folderRoles, events: events))
    }

    init(viewModel: MailComposeViewModel) { _viewModel = State(initialValue: viewModel) }

    init(context: MailComposeContext, session: MailPageSession, folderRoles: [MailFolderRole: String],
         onFolderRolesChanged: @escaping ([MailFolderRole: String]) -> Void, onSentCopyNotice: @escaping (String) -> Void) {
        let events = MailboxEvents()
        events.observe { event in
            if case let .folderRoles(roles) = event { onFolderRolesChanged(roles) }
            if case let .sentCopyNotice(notice) = event { onSentCopyNotice(notice) }
        }
        self.init(context: context, session: session, folderRoles: folderRoles, events: events)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let loadError = viewModel.loadError {
                    Section {
                        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                            Label(loadError, systemImage: "exclamationmark.triangle")
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(.red)
                            Button(String(localized: "action_retry")) { Task { await viewModel.retryPrepare() } }
                                .font(TigerDuckTheme.Typography.caption.weight(.semibold))
                                .disabled(viewModel.isSending)
                        }
                    }
                }

                Section {
                    addressField(String(localized: "school_mail_to"), text: $viewModel.to, field: .to)
                    if viewModel.showCcBcc {
                        addressField(String(localized: "school_mail_cc"), text: $viewModel.cc, field: .cc)
                        addressField(String(localized: "school_mail_bcc"), text: $viewModel.bcc, field: .bcc)
                    } else {
                        Button(String(localized: "school_mail_show_cc_bcc")) { viewModel.showCcBcc = true }
                    }
                    TextField(String(localized: "school_mail_subject"), text: $viewModel.subject)
                        .focused($focused, equals: .subject)
                        .submitLabel(.next)
                        .onSubmit { focused = .body }
                }

                Section(String(localized: "school_mail_body")) {
                    TextEditor(text: $viewModel.body)
                        .focused($focused, equals: .body)
                        .frame(minHeight: 240)
                }

                Section(String(localized: "school_mail_attachments")) {
                    ForEach(viewModel.attachments) { attachment in
                        HStack {
                            Label(attachment.filename, systemImage: "doc")
                                .lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) { viewModel.removeAttachment(attachment.id) } label: {
                                Label(String(localized: "school_mail_delete"), systemImage: "trash")
                            }
                        }
                    }
                    Button { showFileImporter = true } label: {
                        Label(String(localized: "school_mail_add_attachment"), systemImage: "paperclip")
                    }
                    PhotosPicker(selection: $photoItems, matching: .images) {
                        Label(String(localized: "school_mail_add_attachment"), systemImage: "photo")
                    }
                }

                if let error = viewModel.error {
                    Section {
                        Label(error, systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(viewModel.isSending)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel"), action: cancel)
                        .disabled(viewModel.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if viewModel.confirmationIsWarranted() { showSendDialog = true }
                    } label: {
                        LoadingButtonLabel(isLoading: viewModel.isSending) {
                            Text(String(localized: "school_mail_send")).fontWeight(.semibold)
                        }
                    }
                    .disabled(viewModel.isSending || viewModel.isLoading || pendingPicks > 0)
                }
            }
            .alert(String(localized: "feature_school_mail"), isPresented: Binding(
                get: { viewModel.errorNeedsAcknowledging },
                set: { if !$0 { viewModel.acknowledgeError() } })
            ) {
                Button(String(localized: "settings_acknowledged")) {}
            } message: {
                Text(viewModel.error ?? "")
            }
            .confirmationDialog(String(localized: "school_mail_send_confirm_title"), isPresented: $showSendDialog, titleVisibility: .visible) {
                Button(String(localized: "school_mail_send")) {
                    Task { await viewModel.send() }
                }
                Button(String(localized: "school_mail_keep_editing"), role: .cancel) {}
            }
            .confirmationDialog(String(localized: "school_mail_leave_title"), isPresented: $showLeaveDialog, titleVisibility: .visible) {
                Button(String(localized: "school_mail_save_draft")) {
                    Task { if await viewModel.saveDraft() { dismiss() } }
                }
                Button(String(localized: "school_mail_discard"), role: .destructive) { dismiss() }
                Button(String(localized: "school_mail_keep_editing"), role: .cancel) {}
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                pendingPicks += 1
                Task {
                    for url in urls { await addFile(url) }
                    pendingPicks -= 1
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                pendingPicks += 1
                Task {
                    await addPhotos(items)
                    pendingPicks -= 1
                }
            }
            .onChange(of: viewModel.shouldClose) { _, closes in
                if closes { dismiss() }
            }
            .task { await viewModel.prepare() }
            .interactiveDismissDisabled(viewModel.hasChanges || viewModel.isSending)
        }
    }

    private var title: String {
        switch viewModel.mode {
        case .reply: String(localized: "school_mail_reply")
        case .replyAll: String(localized: "school_mail_reply_all")
        case .forward: String(localized: "school_mail_forward")
        case .new, .draft: String(localized: "school_mail_compose")
        }
    }

    private func cancel() {
        guard !viewModel.isSending else { return }
        if viewModel.hasChanges { showLeaveDialog = true } else { dismiss() }
    }

    private func addressField(_ title: String, text: Binding<String>, field: Field) -> some View {
        MailRecipientTokenField(title: title, text: text, focus: $focused, field: field, suggest: viewModel.recipientSuggestions(for:))
    }

    private func addFile(_ url: URL) async {
        guard let picked = await MailComposeFiles.read(url) else {
            viewModel.attachmentReadFailed()
            return
        }
        viewModel.addAttachment(filename: picked.filename, mimeType: picked.mimeType, data: picked.data)
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        let unreadable = await MailComposeFiles.loadPhotos(items) { filename, mimeType, data in
            viewModel.addAttachment(filename: filename, mimeType: mimeType, data: data)
        }
        if !unreadable.isEmpty { viewModel.attachmentReadFailed() }
        photoItems = []
    }
}
#endif
