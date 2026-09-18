#if os(iOS)
import SwiftUI

/// 信箱設定 (design doc §6.5): the display name, the guide, and what the mailbox is costing
/// in disk.
///
/// The new-mail switch and 通知診斷 used to live here too. They moved to
/// `MailNotificationSettingsView`, reached from Settings → 通知 with the app's other
/// notification screens — moved, not copied, so only one screen owns the switch.
struct MailSettingsView: View {
    @State private var displayNameDraft = ""
    /// Bytes under the whole mail cache root. Nil while the first walk is still running, so the
    /// row can say "…" rather than claim a size it has not measured yet.
    @State private var cacheBytes: Int?
    private let account = MailAccountManager.shared

    /// The display name is written onto outgoing mail, so signed out there is nothing for
    /// it to belong to. Dimmed rather than hidden: the field keeps its place on the screen.
    /// Demo mode counts as signed in, like everywhere else — `isLoggedIn` is the stored
    /// student ID, which a demo login sets like any other.
    static func displayNameIsEnabled(isLoggedIn: Bool) -> Bool {
        isLoggedIn
    }

    /// Formatted by the platform, so the number needs no string of its own. `nonisolated`
    /// because the row passes it as a function value to `Optional.map`, which is not a
    /// main-actor context.
    nonisolated static func cacheSizeText(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Measuring walks a directory tree, so it never runs on the main actor — the same rule
    /// every other `MailCache` caller follows. Static and cache-injected so the screen's own
    /// measure/clear path is what the tests drive, against a temporary directory.
    nonisolated static func measureCache(_ cache: MailCache) async -> Int {
        await Task.detached { cache.totalBytes() }.value
    }

    /// Reuses `clearAll()` — the same wipe signing out performs — and re-measures, so the row
    /// shows the result instead of the figure from before. No confirmation on purpose: every
    /// byte of it is re-downloadable, and signing out already clears the same directory.
    nonisolated static func clearCache(_ cache: MailCache) async -> Int {
        await Task.detached {
            cache.clearAll()
            return cache.totalBytes()
        }.value
    }

    var body: some View {
        List {
            Section {
                TextField(String(localized: "school_mail_settings_display_name"), text: $displayNameDraft)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit { account.displayName = displayNameDraft.mailNonEmpty }
            } header: {
                Text(String(localized: "school_mail_settings_display_name"))
            } footer: {
                Text(String(localized: "school_mail_settings_display_name_hint"))
            }
            .disabled(!Self.displayNameIsEnabled(isLoggedIn: account.isLoggedIn))

            Section {
                NavigationLink(String(localized: "school_mail_use_other_app")) { MailGuideView() }
            }

            Section {
                LabeledContent(String(localized: "school_mail_cache_size")) {
                    Text(cacheBytes.map(Self.cacheSizeText) ?? "…")
                }
                Button(String(localized: "school_mail_clear_cache")) {
                    Task { cacheBytes = await Self.clearCache(account.cache) }
                }
                .disabled((cacheBytes ?? 0) == 0)
            }
        }
        .navigationTitle(String(localized: "school_mail_account_title"))
        .onAppear { displayNameDraft = account.displayName ?? "" }
        .onDisappear { account.displayName = displayNameDraft.mailNonEmpty }
        // Re-measured every time the screen is entered: mail read since the last visit has
        // grown the cache behind it.
        .task { cacheBytes = await Self.measureCache(account.cache) }
    }
}
#endif
