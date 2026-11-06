#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class MailComposeContacts {
    private var contacts = SignInBound<[MailRecipientSuggestions.Contact]>(empty: [])
    @ObservationIgnored private let signIn: SignIn
    @ObservationIgnored private let own: String

    init(signIn: SignIn, own: String) {
        self.signIn = signIn
        self.own = own
    }

    func load(from cache: MailCache, drafts: String?, now: Date) async {
        let own = own
        let drafts = drafts ?? MailFolderRole.drafts.imapName
        let found = await Task.detached {
            MailRecipientSuggestions.contacts(in: cache.loadPages(), own: own, drafts: drafts, now: now)
        }.value
        contacts.set(found, for: signIn)
    }

    func suggestions(for typed: String, to: String, cc: String, bcc: String) -> [MailAddress] {
        let addressed = MailRecipients.parse(to: to, cc: cc, bcc: bcc)
        let taken = (addressed.to + addressed.cc + addressed.bcc).map(\.address)
        return MailRecipientSuggestions.matching(contacts.value, typed: typed, taken: taken)
    }
}
#endif
