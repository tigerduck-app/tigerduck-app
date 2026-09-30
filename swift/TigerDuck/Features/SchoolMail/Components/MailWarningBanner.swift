#if os(iOS)
import SwiftUI

/// Warning card above the body — the iOS twin of Android's `FdroidNoticeCard`
/// (orange warning icon, card surface).
struct MailWarningBanner: View {
    let message: String
    var systemImage = "exclamationmark.triangle.fill"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .top, spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.schoolOrange)
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                Text(message)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.caption.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .cardPadding()
        .presetCard(policy: appState.visualStylePolicy)
    }
}

/// Tapping a link first shows where it really goes (§6.3); issues are listed in red. `target`
/// carries the already-canonicalized href judged by `MailWarnings` — the same string shown here
/// is the one `onOpen` opens (message-screen dispatch, 2026-09-16 additions 1–2). When
/// `target.canOpen` is false (an http(s) href a browser-style parse rejected) there is no Open
/// action at all.
struct MailLinkConfirmation: View {
    let target: MailLinkTarget
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(format: String(localized: "school_mail_link_host"), target.href))
                        .foregroundStyle(target.issues.isEmpty ? Color.textPrimary : Color.red)
                        .textSelection(.enabled)
                    ForEach(Array(target.issues.enumerated()), id: \.offset) { _, issue in
                        Label(Self.text(for: issue), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if target.canOpen {
                    Section {
                        Button(String(localized: "school_mail_open"), action: onOpen)
                    }
                }
            }
            .navigationTitle(String(localized: "school_mail_link_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel"), action: onCancel)
                }
            }
        }
        .presentationDetents([.medium])
    }

    static func text(for issue: MailLinkIssue) -> String {
        switch issue {
        case .mismatch(let shown, let real): String(format: String(localized: "school_mail_link_mismatch"), shown, real)
        case .punycode: String(localized: "school_mail_link_punycode")
        case .insecure: String(localized: "school_mail_link_insecure")
        }
    }
}
#endif
