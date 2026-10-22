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
    #endif

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
                    member: member,
                    picture: member.pictureURL.flatMap { store.pictures[$0] },
                    policy: appState.visualStylePolicy,
                    writeTo: writeTo,
                    isOpeningPicture: isOpeningPicture,
                    openPicture: openPicture
                )
                .task(id: member.pictureURL) { await store.loadPicture(of: member) }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.xxl)
            .padding(.bottom, TigerDuckTheme.Spacing.xxl)
        }
        .background(Color.backgroundPrimary)
        .moodleArticleChrome(page: .profile(userId: member.id, courseId: store.courseId))
        .quickLookPreview($picturePreview)
        #if os(iOS)
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

    private func openPicture() {
        guard !isOpeningPicture else { return }
        isOpeningPicture = true
        Task {
            picturePreview = await store.picturePreview(of: member)
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

    private static let avatarSize: CGFloat = 88

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

    @ViewBuilder
    private var avatar: some View {
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
private struct MemberMail: Identifiable {
    let context: MailComposeContext
    let session = MailPageSession()

    var id: UUID { context.id }
}
#endif
