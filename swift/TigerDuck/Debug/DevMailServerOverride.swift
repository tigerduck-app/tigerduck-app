#if DEBUG && os(iOS)
import Foundation
import Observation

nonisolated struct MailServerOverrideSettings: Codable, Equatable, Sendable {
    var isEnabled = false
    var addressDomain = ""
    var imapHost = ""
    var imapPort = 993
    var imapScheme: MailTransportScheme = .implicitTLS
    var smtpHost = ""
    var smtpPort = 465
    var smtpScheme: MailTransportScheme = .implicitTLS

    var normalized: MailServerOverrideSettings? {
        func clean(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var domain = clean(addressDomain)
        while domain.hasPrefix("@") { domain.removeFirst() }
        let imap = clean(imapHost)
        let smtp = clean(smtpHost)
        guard !domain.isEmpty, !imap.isEmpty, !smtp.isEmpty,
              (1...65535).contains(imapPort), (1...65535).contains(smtpPort) else { return nil }
        return MailServerOverrideSettings(
            isEnabled: isEnabled,
            addressDomain: domain,
            imapHost: imap,
            imapPort: imapPort,
            imapScheme: imapScheme,
            smtpHost: smtp,
            smtpPort: smtpPort,
            smtpScheme: smtpScheme
        )
    }
}

nonisolated extension MailServerConfig {
    static func resolve(override: MailServerOverrideSettings) -> MailServerConfig {
        guard override.isEnabled, let settings = override.normalized else { return .school }
        return MailServerConfig(
            addressDomain: settings.addressDomain,
            organizationDomain: settings.addressDomain,
            imapHost: settings.imapHost,
            imapPort: settings.imapPort,
            imapScheme: transportScheme(for: settings.imapHost, requested: settings.imapScheme),
            smtpHost: settings.smtpHost,
            smtpPort: settings.smtpPort,
            smtpScheme: transportScheme(for: settings.smtpHost, requested: settings.smtpScheme),
            isOverridden: true
        )
    }
}

nonisolated final class DevMailServerOverride: @unchecked Sendable {
    static let shared = DevMailServerOverride()

    static let storageKey = "debug_school_mail_server_override"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: MailServerOverrideSettings?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: MailServerOverrideSettings {
        lock.withLock {
            if let cached { return cached }
            let decoded = defaults.data(forKey: Self.storageKey)
                .flatMap { try? JSONDecoder().decode(MailServerOverrideSettings.self, from: $0) }
                ?? MailServerOverrideSettings()
            cached = decoded
            return decoded
        }
    }

    var effectiveConfig: MailServerConfig { MailServerConfig.resolve(override: settings) }

    func save(_ settings: MailServerOverrideSettings) {
        lock.withLock {
            cached = settings
            if let data = try? JSONEncoder().encode(settings) {
                defaults.set(data, forKey: Self.storageKey)
            } else {
                defaults.removeObject(forKey: Self.storageKey)
            }
        }
    }

    func clear() {
        save(MailServerOverrideSettings())
    }
}

@MainActor
@Observable
final class DevMailServerSettings {
    static let shared = DevMailServerSettings()

    @ObservationIgnored private let store: DevMailServerOverride
    @ObservationIgnored private let resetMailState: @MainActor () -> Void

    var draft: MailServerOverrideSettings

    private(set) var generation = 0

    init(
        store: DevMailServerOverride = .shared,
        resetMailState: @escaping @MainActor () -> Void = { MailAccountManager.shared.logout() }
    ) {
        self.store = store
        self.resetMailState = resetMailState
        draft = store.settings
    }

    var stored: MailServerOverrideSettings { store.settings }
    var effectiveConfig: MailServerConfig { store.effectiveConfig }

    static func applyRefusal(for draft: MailServerOverrideSettings) -> String? {
        guard draft.isEnabled, let settings = draft.normalized else { return nil }
        let school = [settings.imapHost, settings.smtpHost].filter(DevMailConnectionProbe.isSchoolHost)
        guard !school.isEmpty else { return nil }
        return """
        \(Array(Set(school)).sorted().joined(separator: ", ")) is an NTUST host, and an override \
        may not name one. Applying it would point the app at the school server while still \
        counting as an override, which is exactly the state the saved-password rules assume \
        cannot happen: sign in under it and the real mail password becomes something Test \
        connection would offer to whatever host this screen is edited to next. Use the override \
        off (the button below) to go back to the school server.
        """
    }

    @discardableResult
    func apply() -> Bool {
        commit(draft)
    }

    @discardableResult
    func resetToSchoolServer() -> Bool {
        let changed = commit(MailServerOverrideSettings())
        draft = store.settings
        return changed
    }

    private func commit(_ settings: MailServerOverrideSettings) -> Bool {
        guard Self.applyRefusal(for: settings) == nil else { return false }
        let before = store.effectiveConfig
        store.save(settings)
        guard store.effectiveConfig != before else { return false }
        resetMailState()
        generation += 1
        return true
    }
}
#endif
