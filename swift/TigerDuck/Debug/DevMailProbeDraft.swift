#if DEBUG && os(iOS)
import Foundation

nonisolated enum DevMailProbeDraft {
    static func refusal(for draft: MailServerOverrideSettings) -> String? {
        guard draft.isEnabled else {
            return """
            The override is off, so there is nothing here to test but the school server, and this \
            button never connects to that. Turn the override on and fill in a server first.
            """
        }
        guard let settings = draft.normalized else {
            return """
            Incomplete. This needs an address domain, an IMAP host, an SMTP host and two ports in \
            1–65535 before there is anything to connect to.
            """
        }
        let school = [settings.imapHost, settings.smtpHost].filter(isSchoolHost)
        guard school.isEmpty else {
            return """
            \(Array(Set(school)).sorted().joined(separator: ", ")) is an NTUST host, and this \
            button never tests the school server: it would put the real mail password through a \
            diagnostic connection, and the school path is not what this screen is for.
            """
        }
        return nil
    }

    static func isSchoolHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return false }
        if host == MailServerConfig.school.imapHost || host == MailServerConfig.school.smtpHost { return true }
        return MailServerConfig.isPinnedHost(host)
    }

    static func credentials(
        username: String?,
        password: String?,
        appliedIsOverridden: Bool
    ) -> DevMailProbeCredentials {
        let username = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password ?? ""
        guard !username.isEmpty, !password.isEmpty else {
            return .unavailable("no saved credentials, so this was connect-and-handshake only")
        }
        guard appliedIsOverridden else {
            return .unavailable("""
            the saved password belongs to the school account and is never sent anywhere else — \
            apply this override, sign in to the test account, then test again
            """)
        }
        return .use(username: username, password: password)
    }

    static func describeUsername(_ username: String) -> String {
        "username: \(username.count) characters, \(username.contains("@") ? "with" : "no") \"@\""
    }
}
#endif
