#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MailComposeView: View {
    private enum Field: Hashable { case to, cc, bcc, subject, body }

    @State private var viewModel: MailComposeViewModel
    private let mode: MailComposeMode

    @Environment(\.dismiss) private var dismiss
    @State private var showLeaveDialog = false
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @FocusState private var focused: Field?

    init(context: MailComposeContext, session: MailPageSession, folderRoles: [MailFolderRole: String]) {
        let account = MailAccountManager.shared
        let sender = MailAddress(name: account.displayName, address: account.address ?? "")
        _viewModel = State(initialValue: MailComposeViewModel(context: context, session: session, sender: sender, folderRoles: folderRoles))
        mode = context.mode
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel"), action: cancel)
                        .disabled(viewModel.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await viewModel.send() }
                    } label: {
                        LoadingButtonLabel(isLoading: viewModel.isSending) {
                            Text(String(localized: "school_mail_send")).fontWeight(.semibold)
                        }
                    }
                    .disabled(viewModel.isSending || viewModel.isLoading)
                }
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
                Task { for url in urls { await addFile(url) } }
            }
            .onChange(of: photoItems) { _, items in
                Task { await addPhotos(items) }
            }
            .onChange(of: viewModel.didFinish) { _, finished in
                if finished { dismiss() }
            }
            .task { await viewModel.prepare() }
            // While a send/save is in flight, or there's something to lose, the sheet cannot be
            // swiped away out from under it (dispatch addition 2): the send is never cancelled
            // halfway, and Cancel (above) refuses the same way.
            .interactiveDismissDisabled(viewModel.hasChanges || viewModel.isSending)
        }
    }

    private var title: String {
        switch mode {
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
        TextField(title, text: text)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused, equals: field)
    }

    // MARK: Attachments

    /// The security-scoped access, the read and the UTType lookup all run off the main actor
    /// (dispatch addition 4) -- a failed read is reported the same way an over-budget attachment
    /// is, never silently dropped (dispatch addition 3).
    private func addFile(_ url: URL) async {
        let picked = await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil as (Data, String, String)? }
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return (data, mimeType, url.lastPathComponent)
        }.value
        guard let (data, mimeType, filename) = picked else {
            viewModel.attachmentReadFailed()
            return
        }
        viewModel.addAttachment(filename: filename, mimeType: mimeType, data: data)
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        var anyFailed = false
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                anyFailed = true
                continue
            }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            viewModel.addAttachment(filename: "IMG_\(index + 1).\(ext)", mimeType: type?.preferredMIMEType ?? "image/jpeg", data: data)
        }
        if anyFailed { viewModel.attachmentReadFailed() }
        photoItems = []
    }
}
#endif
