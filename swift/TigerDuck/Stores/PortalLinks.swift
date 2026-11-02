import Foundation

/// The student portal's links of an account in one language: the saved ones, and the school's,
/// which are saved for the sign-in they were read for while it lasts.
@MainActor
struct PortalLinks {
    static let freshness = FreshnessPolicy(lifetime: 86_400)

    /// The last portal page with no links each sign-in got in a language, which each read meets
    /// only after the school's sign-in. It counts toward `freshness` as saved links do, so opening
    /// the page again does not sign in again; a network failure is not kept, and the next open
    /// tries again.
    @MainActor
    final class Failures {
        static let shared = Failures()

        fileprivate struct Key: Hashable {
            let signIn: SignIn
            let language: PortalLanguage
        }

        fileprivate var latest: [Key: (at: Date, message: String)] = [:]
    }

    var files = PortalLinkFiles()
    var service = NTUSTPortalService.shared
    var failures = Failures.shared
    var demoLinks: (PortalLanguage) -> [PortalLink] = { DemoPortal.links(in: $0) }
    var now: () -> Date = { Date() }

    func saved(studentId: String, language: PortalLanguage) -> (links: [PortalLink], fetchedAt: Date)? {
        files.load(studentId: studentId, language: language).map { ($0.links, $0.fetchedAt) }
    }

    /// The message of a portal page with no links within `freshness`, for the sign-in and language.
    func recentFailure(language: PortalLanguage, for signIn: SignIn) -> String? {
        guard let failure = failures.latest[Failures.Key(signIn: signIn, language: language)],
              Self.freshness.isFresh(storedAt: failure.at, now: now()) else { return nil }
        return failure.message
    }

    func fetch(
        studentId: String, password: String, language: PortalLanguage, for signIn: SignIn
    ) async throws -> (links: [PortalLink], fetchedAt: Date) {
        let key = Failures.Key(signIn: signIn, language: language)
        let credentials = NTUSTPortalService.Credentials(studentId: studentId, password: password, signIn: signIn)
        let links: [PortalLink]
        do {
            links = signIn.isDemo ? demoLinks(language) : try await service.links(in: language, credentials: credentials)
        } catch {
            if signIn.isCurrent, error as? NTUSTPortalError == .unreadable {
                failures.latest[key] = (now(), error.localizedDescription)
            }
            throw error
        }
        guard signIn.isCurrent else { throw CancellationError() }
        failures.latest[key] = nil
        let saved = PortalLinkFiles.Saved(links: links, fetchedAt: now())
        files.save(saved, studentId: studentId, language: language)
        return (links, saved.fetchedAt)
    }
}
