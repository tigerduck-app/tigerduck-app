#if os(iOS)
import PhotosUI
#endif
import QuickLook
import SwiftUI

struct MoodleMemberView: View {
    let store: MoodleCourseStore
    let member: MoodleMember

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var picturePreview: URL?
    @State private var isOpeningPicture = false
    #if os(iOS)
    @State private var mail: MemberMail?
    @State private var sentCopyNotice: String?
    @State private var canChangePicture = false
    @State private var isPickingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var photoLoad: Task<Void, Never>?
    @State private var cropping: PhotoToCrop?
    @State private var isUploadingPicture = false
    @State private var pictureFailure: String?
    @State private var profileEditor: ProfileEditorPage?
    @State private var isOpeningProfileEditor = false
    #endif

    /// The list's copy, so a new picture shows once the members are fetched again.
    private var shown: MoodleMember { store.member(member.id) ?? member }
    private var isOwn: Bool { member.id == store.members.value?.ownId }

    var body: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                #if os(iOS)
                if let sentCopyNotice {
                    MailWarningBanner(
                        message: sentCopyNotice,
                        systemImage: "tray.and.arrow.down",
                        actionTitle: String(localized: "settings_acknowledged"),
                        action: { self.sentCopyNotice = nil }
                    )
                }
                #endif
                MoodleMemberProfile(
                    member: shown,
                    picture: shown.pictureURL.flatMap { store.pictures[$0] },
                    policy: appState.visualStylePolicy,
                    writeTo: writeTo,
                    isOpeningPicture: isOpeningPicture,
                    openPicture: openPicture,
                    changePicture: changePicture,
                    isUploadingPicture: isUploadingPicture
                )
                .task(id: shown.pictureURL) { await store.loadPicture(of: shown) }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.xxl)
            .padding(.bottom, TigerDuckTheme.Spacing.xxl + editButtonRoom)
        }
        .background(Color.backgroundPrimary)
        .moodleArticleChrome(page: .profile(userId: member.id, courseId: store.courseId))
        .quickLookPreview($picturePreview)
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            if isOwn { editOnMoodleButton }
        }
        .task(id: isOwn) {
            if isOwn { canChangePicture = await store.allowsPictureChange() }
        }
        .photosPicker(isPresented: $isPickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            photoLoad?.cancel()
            photoLoad = Task { await crop(item) }
        }
        .fullScreenCover(item: $cropping) { photo in
            MoodlePictureCropView(image: photo.image, onCancel: { cropping = nil }) { jpeg in
                cropping = nil
                upload(jpeg)
            }
        }
        .sheet(item: $profileEditor, onDismiss: { Task { await store.refetchMembers() } }) { page in
            InAppBrowserView(url: page.url)
                .ignoresSafeArea()
        }
        .alert(pictureFailure ?? "", isPresented: Binding(
            get: { pictureFailure != nil },
            set: { if !$0 { pictureFailure = nil } }
        )) {}
        .sheet(item: $mail) { mail in
            MailComposeView(
                context: mail.context,
                session: mail.session,
                folderRoles: [:],
                onFolderRolesChanged: { _ in },
                onSentCopyNotice: { sentCopyNotice = $0 }
            )
            .onDisappear { Task { await mail.session.close() } }
        }
        #endif
    }

    #if os(iOS)
    private var changePicture: (() -> Void)? {
        isOwn && canChangePicture ? { isPickingPhoto = true } : nil
    }

    private var editOnMoodleButton: some View {
        Button(action: openProfileEditor) {
            Image(systemName: "pencil")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: Self.editButtonSize, height: Self.editButtonSize)
                .background(Circle().fill(.tint))
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "course_member_edit_on_moodle"))
        .padding(TigerDuckTheme.Spacing.lg)
    }

    private static let editButtonSize: CGFloat = 56

    /// Lets the end of the page scroll clear of the edit button.
    private var editButtonRoom: CGFloat { isOwn ? Self.editButtonSize + TigerDuckTheme.Spacing.lg : 0 }

    private func openProfileEditor() {
        guard !isOpeningProfileEditor, profileEditor == nil, let url = MoodlePage.profileEditor.webURL else { return }
        isOpeningProfileEditor = true
        Task {
            profileEditor = ProfileEditorPage(url: await MoodleAutologinService.shared.url(for: url))
            isOpeningProfileEditor = false
        }
    }

    private func crop(_ item: PhotosPickerItem) async {
        let data: Data?
        do {
            data = try await item.loadTransferable(type: Data.self)
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.captureError(error, context: ["phase": "moodlePicture.loadPhoto"])
            data = nil
        }
        let picked = await Task.detached { data.flatMap { MoodlePictureCropView.downsampled($0) } }.value
        // A later pick cancels this one, which a slow photo could otherwise replace.
        guard !Task.isCancelled else { return }
        guard let picked else {
            pictureFailure = String(localized: "course_member_picture_unreadable")
            return
        }
        cropping = PhotoToCrop(image: UIImage(cgImage: picked))
    }

    private func upload(_ jpeg: Data) {
        guard !isUploadingPicture else { return }
        isUploadingPicture = true
        Task {
            defer { isUploadingPicture = false }
            do {
                try await store.updatePicture(jpeg)
            } catch {
                pictureFailure = MoodleFirstLoadView.message(for: error)
            }
        }
    }
    #else
    private var changePicture: (() -> Void)? { nil }
    private var isUploadingPicture: Bool { false }
    private var editButtonRoom: CGFloat { 0 }
    #endif

    private func openPicture() {
        guard !isOpeningPicture else { return }
        isOpeningPicture = true
        Task {
            picturePreview = await store.picturePreview(of: shown)
            isOpeningPicture = false
        }
    }

    private func writeTo(_ address: String) {
        #if os(iOS)
        if MailAccountManager.shared.isLoggedIn {
            mail = MemberMail(context: MailComposeContext(mode: .new, to: [MailAddress(name: member.name, address: address)]))
            return
        }
        #endif
        guard let url = URL(string: "mailto:\(address)") else { return }
        openURL(url)
    }
}

struct MoodleMemberProfile: View {
    let member: MoodleMember
    let picture: CGImage?
    let policy: VisualStylePolicy
    let writeTo: (String) -> Void
    var isOpeningPicture = false
    let openPicture: () -> Void
    /// Nil hides the camera button: Moodle changes only the signed-in account's picture, and only
    /// on a site that lists `core_user_update_picture`.
    var changePicture: (() -> Void)? = nil
    var isUploadingPicture = false

    private static let avatarSize: CGFloat = 88
    private static let badgeSize: CGFloat = 28

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            header
            let rows = Self.rows(of: member)
            if !rows.isEmpty {
                details(rows)
            }
            if !member.description.isEmpty {
                Text(member.description)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !member.interests.isEmpty {
                interests
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(spacing: TigerDuckTheme.Spacing.xs) {
            avatar
                .padding(.bottom, TigerDuckTheme.Spacing.xs)
            Text(member.name)
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            Text(MoodleMemberSection.Placement(member).title)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var avatar: some View {
        pictureButton
            .overlay { if isUploadingPicture { ProgressView() } }
            .overlay(alignment: .bottomTrailing) {
                if let changePicture {
                    Button(action: changePicture) {
                        Image(systemName: "camera.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: Self.badgeSize, height: Self.badgeSize)
                            .background(Circle().fill(.tint))
                            .overlay(Circle().stroke(Color.backgroundPrimary, lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                    .disabled(isUploadingPicture)
                    .accessibilityLabel(String(localized: "course_member_change_picture"))
                }
            }
    }

    @ViewBuilder
    private var pictureButton: some View {
        let image = MoodleAvatar(name: member.name, size: Self.avatarSize, picture: picture)
        if picture != nil {
            Button(action: openPicture) {
                image.overlay { if isOpeningPicture { ProgressView() } }
            }
            .buttonStyle(.plain)
            .disabled(isOpeningPicture)
            .accessibilityLabel(String(localized: "course_member_profile_picture"))
        } else {
            image
        }
    }

    nonisolated struct Row: Equatable {
        enum Value: Equatable {
            case text(String)
            case email(String)

            var isEmail: Bool {
                if case .email = self { return true }
                return false
            }
        }

        let label: String
        let value: Value
    }

    nonisolated static func rows(of member: MoodleMember) -> [Row] {
        var rows: [Row] = []
        if let studentId = member.studentId {
            rows.append(Row(label: String(localized: "sign_in_student_id"), value: .text(studentId)))
        }
        if let department = member.department {
            rows.append(Row(label: String(localized: "course_member_department"), value: .text(department.name)))
        }
        if let email = member.email {
            rows.append(Row(label: String(localized: "course_member_email"), value: .email(email)))
        }
        if !member.groups.isEmpty {
            rows.append(Row(label: String(localized: "course_member_groups"), value: .text(member.groups.joined(separator: "、"))))
        }
        rows += member.fields.map { Row(label: $0.name, value: .text($0.value)) }
        return rows
    }

    private func details(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label)
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    value(row.value)
                        .font(TigerDuckTheme.Typography.body)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: row.value.isEmail ? .contain : .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardPadding()
        .presetCard(policy: policy)
    }

    @ViewBuilder
    private func value(_ value: Row.Value) -> some View {
        switch value {
        case .text(let text):
            Text(text)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
        case .email(let address):
            if let url = URL(string: "mailto:\(address)") {
                // Wrapped, an address would break with a hyphen it does not have.
                Text(AttributedString(address, attributes: AttributeContainer().link(url)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .truncationMode(.middle)
                    .environment(\.openURL, OpenURLAction { _ in
                        writeTo(address)
                        return .handled
                    })
            } else {
                Text(address).foregroundStyle(Color.textPrimary)
            }
        }
    }

    private var interests: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(member.interests.enumerated()), id: \.offset) { _, interest in
                Text(verbatim: "#\(interest)")
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.12), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if os(iOS)
private struct PhotoToCrop: Identifiable {
    let image: UIImage
    let id = UUID()
}

private struct ProfileEditorPage: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct MemberMail: Identifiable {
    let context: MailComposeContext
    let session = MailPageSession()

    var id: UUID { context.id }
}
#endif
