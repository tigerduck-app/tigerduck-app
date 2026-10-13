#if DEBUG && os(iOS)
import Foundation
import Observation

/// What the developer typed on `Settings → Developer → Email`, before it is resolved into a
/// `MailServerConfig`.
///
/// Persisted as one JSON blob rather than eight defaults keys: the values only ever mean
/// anything together, and a half-written set (a host saved, a port not) is exactly the state
/// that must not be reachable.
nonisolated struct MailServerOverrideSettings: Codable, Equatable, Sendable {
    var isEnabled = false
    var addressDomain = ""
    var imapHost = ""
    var imapPort = 993
    var imapScheme: MailTransportScheme = .implicitTLS
    var smtpHost = ""
    var smtpPort = 465
    var smtpScheme: MailTransportScheme = .implicitTLS

    /// Trimmed and lower-cased, with a leading `@` dropped from the domain (typing `@example.com`
    /// is natural and is what the page's label shows), or nil when a field is missing or a port is
    /// out of range.
    ///
    /// Nil needs no handling: `MailServerConfig.resolve(override:)` treats it as "off" and returns
    /// the school configuration, so an override switched on before it was filled in never points
    /// the app at half a server. The screen keeps Apply disabled until this is non-nil, so that
    /// fallback is only a backstop.
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

/// `nonisolated` explicitly: the app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor`, and an extension declared in a different file than the type does not inherit
/// the type's own `nonisolated`. Without this, resolving the configuration would be a
/// main-actor hop — from `LiveMailClient`'s initializer and from `MailWarnings`, neither of
/// which is on the main actor.
nonisolated extension MailServerConfig {
    /// The one place an override becomes a configuration.
    ///
    /// Off, incomplete or unparseable resolves to `school`, so "the override is on" and "the app
    /// points somewhere else" are the same fact and the page banner can trust `isOverridden`.
    /// `organizationDomain` is the overridden address domain itself: a test mailbox has no wider
    /// organization, and `user@gmail.com` writing to `user@gmail.com` must not be badged External.
    /// Both schemes go through `transportScheme(for:requested:)`, which stops an override naming
    /// `mail.ntust.edu.tw` from dropping the real school connection to STARTTLS or plaintext.
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

/// Storage for the developer mail-server override.
///
/// `nonisolated`, with its own lock and an in-memory copy of the decoded settings, because
/// `MailServerConfig.effective` is read from places that are not on the main actor and cannot
/// await: `LiveMailClient`'s initializer, `MailMessageBuilder`, and `MailWarnings`' domain
/// rules, which run per message.
nonisolated final class DevMailServerOverride: @unchecked Sendable {
    static let shared = DevMailServerOverride()

    /// Deliberately not one of the `school_mail_*` keys: `DefaultsMailPreferences.reset()`
    /// clears those on every sign-out, and an override that switched itself off whenever the
    /// developer signed out would be worse than useless — applying it signs out, so it would
    /// erase itself on the way in.
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

/// The developer override as the UI holds it, and the one place a change to it takes effect. No
/// School Mail state carries an account or server dimension (`MailCache` is keyed by folder and
/// UID, `MailListViewModel` keeps folder roles and pages, the new-mail marker sits in `Defaults`),
/// so a change signs out rather than show the old server's mail with Delete attached. That stops
/// background refresh and clears the saved password, cache, markers, diagnostics, delivered
/// notifications and, with the password it was about, the `authFailed` lockout, which would
/// otherwise follow to a server that rejected nothing. `generation` lets the School Mail page drop
/// what it resolved against the old server. See docs/decisions/0007-dev-mail-server-override.md.
@MainActor
@Observable
final class DevMailServerSettings {
    static let shared = DevMailServerSettings()

    @ObservationIgnored private let store: DevMailServerOverride
    @ObservationIgnored private let resetMailState: @MainActor () -> Void

    /// The draft the Developer → Email screen edits. Writing it changes nothing on its own;
    /// `apply()` is what commits.
    var draft: MailServerOverrideSettings

    /// Bumped once per *effective* configuration change. A save that resolves to the same
    /// configuration (a typo corrected back, a field edited while the override is off) is not
    /// a change and must not sign anyone out.
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

    /// Why `draft` may not be applied, or nil when it may. The probe's
    /// `credentials(username:password:appliedIsOverridden:)` assumes an applied override means the
    /// saved password is not the school's, but `MailServerConfig.resolve(override:)` only clamps a
    /// school host's TLS. An applied override naming `mail.ntust.edu.tw` would be the school server
    /// with `isOverridden` true: sign in, point the draft at a third-party host, tap Test
    /// connection, and the school password goes out. Refusing it here keeps the premise true.
    /// `transportScheme(for:requested:)` still clamps the draft Test connection resolves, which
    /// never reaches this.
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

    /// Commits `draft`. Returns whether the effective configuration actually changed.
    @discardableResult
    func apply() -> Bool {
        commit(draft)
    }

    /// Switches the override off and puts the school server back.
    @discardableResult
    func resetToSchoolServer() -> Bool {
        let changed = commit(MailServerOverrideSettings())
        draft = store.settings
        return changed
    }

    private func commit(_ settings: MailServerOverrideSettings) -> Bool {
        // The screen already disables Apply for a refused draft; this is the rule itself rather
        // than a restatement of it, so nothing can commit one by another route.
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
