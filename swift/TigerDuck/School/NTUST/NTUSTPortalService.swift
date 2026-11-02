import Foundation

enum NTUSTPortalError: LocalizedError, Equatable {
    case notSignedIn
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "common_not_signed_in")
        case .unreadable: String(localized: "error_invalid_server_response")
        }
    }
}

/// The student portal's links, read with the school SSO session. It signs in only when the
/// page is not answered, so a live session costs one request.
@MainActor
struct NTUSTPortalService {
    struct Credentials: Sendable {
        let studentId: String
        let password: String
        let signIn: SignIn
    }

    typealias LoadPage = @MainActor (URL) async throws -> (Data, URLResponse)
    typealias ServiceSignIn = @MainActor (_ serviceURL: URL, _ credentials: Credentials) async throws -> Bool

    static let shared = NTUSTPortalService(
        load: { try await NTUSTSessionManager.shared.session.data(from: $0) },
        signIn: { url, credentials in
            // A lapsed portal session sends the page to the sign-in until its cookies are gone.
            NTUSTSessionManager.shared.dropServiceCookies(for: url)
            return try await SSOLoginService.ensureServiceLogin(
                session: NTUSTSessionManager.shared.session,
                serviceURL: url,
                studentId: credentials.studentId,
                password: credentials.password,
                for: credentials.signIn
            )
        }
    )

    let load: LoadPage
    let signIn: ServiceSignIn

    func links(in language: PortalLanguage, credentials: Credentials) async throws -> [PortalLink] {
        let url = language.pageURL
        if let links = try await read(url) { return links }
        try check(credentials.signIn)
        guard try await signIn(url, credentials) else { throw NTUSTPortalError.notSignedIn }
        try check(credentials.signIn)
        guard let links = try await read(url) else { throw NTUSTPortalError.unreadable }
        return links
    }

    /// Nil for an answer from another host, the sign-in form, or a page with no links.
    private func read(_ url: URL) async throws -> [PortalLink]? {
        let (data, response) = try await load(url)
        guard let landed = response.url, landed.host() == url.host(),
              let html = SSOForms.decodeHTML(data, response: response),
              !HTMLParser.looksLikeSSOLoginBody(html) else { return nil }
        let links = await Task.detached(priority: .userInitiated) {
            NTUSTPortalParser.links(in: html, pageURL: landed)
        }.value
        return links?.isEmpty == false ? links : nil
    }

    private func check(_ signIn: SignIn) throws {
        guard signIn.isCurrent else { throw CancellationError() }
    }
}
