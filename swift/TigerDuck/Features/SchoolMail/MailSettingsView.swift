#if os(iOS)
import SwiftUI

struct MailSettingsView: View {
    @State private var displayNameDraft = ""
    @State private var cacheBytes: Int?
    private let account = MailAccountManager.shared

    static func displayNameIsEnabled(isLoggedIn: Bool) -> Bool {
        isLoggedIn
    }

    nonisolated static func cacheSizeText(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    nonisolated static func measureCache(_ cache: MailCache) async -> Int {
        await Task.detached { cache.totalBytes() }.value
    }

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
        .task { cacheBytes = await Self.measureCache(account.cache) }
    }
}
#endif
