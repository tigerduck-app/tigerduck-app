#if os(iOS)
import SwiftUI

struct MailTitleBar: View {
    let viewModel: MailListViewModel
    let isLoggedIn: Bool

    static var headerActionHeight: CGFloat { HeaderMenuButton<EmptyView>.height }
    private static let headerActionWidth: CGFloat = 44

    var body: some View {
        HStack {
            Text(String(localized: "feature_school_mail"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if isLoggedIn {
                HStack(spacing: TigerDuckTheme.Spacing.lg) {
                    statusDot
                    headerActions
                }
            }
        }
        .frame(minHeight: Self.headerActionHeight)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

    private var statusDot: some View {
        SyncStatusDot(
            status: viewModel.serverStatus,
            label: String(localized: "feature_school_mail"),
            icon: "envelope.fill",
            text: viewModel.statusText,
            isLoading: viewModel.isSyncing,
            lastSynced: .at(viewModel.syncedAt)
        )
    }

    /// The button is `.borderless` because the row is a `List` row: the default style there
    /// gives the whole row one tap target and drops the tint. `MailFolderChipBar` and
    /// `SyncStatusDot` take `.plain` in the same situation, for the same reason.
    @ViewBuilder
    private var headerActions: some View {
        let row = Button { viewModel.unreadOnly.toggle() } label: {
            headerIcon(viewModel.unreadOnly
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(String(localized: "school_mail_unread_only"))
        if #available(iOS 26, *) {
            row.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            row.background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
        }
    }

    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body)
            .frame(width: Self.headerActionWidth, height: Self.headerActionHeight)
            .contentShape(.rect)
    }
}

/// Search, in the list's own content rather than `.searchable`, which would put the field alone
/// in the navigation bar of a page without a navigation title and push the header a bar lower
/// than Home's.
struct MailSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textSecondary)
            TextField(String(localized: "school_mail_search_prompt"), text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused(isFocused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "action_clear_text"))
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.md)
        .padding(.vertical, TigerDuckTheme.Spacing.sm)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }
}

struct MailComposeButton: View {
    let accentColor: Color
    let action: () -> Void
    @ScaledMetric(relativeTo: .title2) private var glyphLift: CGFloat = 2
    private static let size: CGFloat = 56

    var body: some View {
        Button(action: action) {
            let glyph = Image(systemName: "square.and.pencil")
                .font(.title2)
                // Optical centring, keep it: `square.and.pencil` draws its rounded square below
                // the centre of its box (the pencil takes the room above). Already centred on x.
                .offset(y: -glyphLift)
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
            if #available(iOS 26, *) {
                glyph.foregroundStyle(.white)
                    .glassEffect(.regular.tint(accentColor).interactive(), in: .circle)
            } else {
                glyph.foregroundStyle(accentColor)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "school_mail_compose"))
        .padding(.trailing, TigerDuckTheme.Spacing.lg)
        .padding(.bottom, TigerDuckTheme.Spacing.sm)
    }
}

#if DEBUG
struct MailDeveloperServerBanner: View {
    var body: some View {
        let config = MailServerConfig.effective
        Group {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Developer server override — not your school mail")
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textPrimary)
                    Text("@\(config.addressDomain) · IMAP \(config.imapHost):\(config.imapPort) · SMTP \(config.smtpHost):\(config.smtpPort)")
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            } icon: {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(Color.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(TigerDuckTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: TigerDuckTheme.Spacing.md, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.sm)
        }
    }
}
#endif
#endif
