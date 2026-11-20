import Foundation

@MainActor
struct PortalLinks {
    static let freshness = FreshnessPolicy(lifetime: 86_400)

    @MainActor
    final class UnreadablePages: AccountScoped {
        static let shared = UnreadablePages()

        fileprivate struct Key: Hashable {
            let studentId: String
            let signIn: SignIn
            let language: PortalLanguage
        }

        fileprivate var latest: [Key: (at: Date, message: String)] = [:]

        static func forgetAccount(in storage: AccountStorage) {
            shared.latest = [:]
        }
    }

    var files = PortalLinkFiles()
    var service = NTUSTPortalService.shared
    var unreadablePages = UnreadablePages.shared
    var demoLinks: (PortalLanguage) -> [PortalLink] = { DemoPortal.links(in: $0) }
    var now: () -> Date = { Date() }

    func saved(studentId: String, language: PortalLanguage) -> (links: [PortalLink], fetchedAt: Date)? {
        files.load(studentId: studentId, language: language).map { ($0.links, $0.fetchedAt) }
    }

    func recentUnreadablePage(studentId: String, language: PortalLanguage, for signIn: SignIn) -> String? {
        let key = UnreadablePages.Key(studentId: studentId, signIn: signIn, language: language)
        guard let page = unreadablePages.latest[key], Self.freshness.isFresh(storedAt: page.at, now: now()) else { return nil }
        return page.message
    }

    func fetch(
        studentId: String, password: String, language: PortalLanguage, for signIn: SignIn
    ) async throws -> (links: [PortalLink], fetchedAt: Date) {
        let key = UnreadablePages.Key(studentId: studentId, signIn: signIn, language: language)
        let credentials = NTUSTPortalService.Credentials(studentId: studentId, password: password, signIn: signIn)
        let links: [PortalLink]
        do {
            links = signIn.isDemo ? demoLinks(language) : try await service.links(in: language, credentials: credentials)
        } catch {
            if signIn.isCurrent, error as? NTUSTPortalError == .unreadable {
                unreadablePages.latest[key] = (now(), error.localizedDescription)
            }
            throw error
        }
        guard signIn.isCurrent else { throw CancellationError() }
        unreadablePages.latest[key] = nil
        let saved = PortalLinkFiles.Saved(links: links, fetchedAt: now())
        files.save(saved, studentId: studentId, language: language)
        return (links, saved.fetchedAt)
    }
}
