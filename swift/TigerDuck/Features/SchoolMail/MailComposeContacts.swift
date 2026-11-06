#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class MailComposeContacts {
    private var contacts = SignInBound<[MailRecipientSuggestions.Contact]>(empty: [])
    @ObservationIgnored private let signIn: SignIn
    @ObservationIgnored private let own: String
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let roles: [MailFolderRole: String]
    @ObservationIgnored private let now: () -> Date

    init(signIn: SignIn, own: String, cache: MailCache, roles: [MailFolderRole: String], now: @escaping () -> Date) {
        self.signIn = signIn
        self.own = own
        self.cache = cache
        self.roles = roles
        self.now = now
    }

    func load() async {
        let (own, cache, roles, now) = (own, cache, roles, now())
        let found = try? await MailMessageRenderer.detachedCancellably {
            let pages = cache.loadPages()
            try Task.checkCancellation()
            return MailRecipientSuggestions.contacts(in: pages, own: own, roles: roles, now: now)
        }
        guard let found, !Task.isCancelled else { return }
        contacts.set(found, for: signIn)
    }

    func suggestions(for typed: String, addressed fields: [String]) -> [MailAddress] {
        let taken = fields.flatMap { MailRecipients.parse($0).addresses.map(\.address) }
        return MailRecipientSuggestions.matching(contacts.value, typed: typed, taken: taken)
    }
}
#endif
