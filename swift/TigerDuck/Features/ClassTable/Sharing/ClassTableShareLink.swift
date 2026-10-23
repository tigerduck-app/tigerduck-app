import Foundation
import Observation

/// A share code opened as a link rather than scanned in the app: a Universal Link on the share
/// host, which the Camera, another QR app or a tapped link hands over, or the share page's
/// `tigerduck://share/<rest>`, which stands for `https://share.tigerduck.app/<rest>`. Any page or
/// app can open either, so a link goes through the import's usual confirmation, as a scan does.
nonisolated enum ClassTableShareLink {
    static let scheme = "tigerduck"
    static let host = "share"

    /// The text the import reads for `url`, or nil for a link the rest of the app handles.
    /// Everything on the share host counts, as the app claims all of it: a newer app's type
    /// reaches the decoder, which asks for an update, and a URL with no share code gets a message.
    static func codeText(_ url: URL) -> String? {
        if url.scheme?.lowercased() == "https", url.host()?.uppercased() == shareHostName {
            return url.absoluteString
        }
        // Matched as written, as `WidgetURLRouter` matches the widgets' links.
        guard url.scheme == scheme, url.host() == host else { return nil }
        let path = url.path(percentEncoded: true)
        return ClassTableShareCode.shareHost + "/" + (path.hasPrefix("/") ? path.dropFirst() : path[...])
    }

    private static let shareHostName = String(ClassTableShareCode.shareHost.dropFirst("HTTPS://".count))
}

/// A share link that came before its import could open, with no one signed in or onboarding not
/// finished, held until both are done. It is kept in memory only, so quitting the app loses it.
/// A newer link replaces it, and a sign-out, which moves `AuthService.loginGeneration`, drops it.
@Observable
final class HeldShareLink {
    struct Link: Equatable {
        let id = UUID()
        let text: String
        let loginGeneration: Int
    }

    static let shared = HeldShareLink()

    private(set) var link: Link?

    func arrived(_ text: String, loginGeneration: Int) {
        link = Link(text: text, loginGeneration: loginGeneration)
    }

    /// Whether a link's import may open: someone is signed in, onboarding is finished, and the
    /// sign-in sheet has closed. A sign-in saves the account before its sheet closes, and the
    /// import's sheet cannot show over it.
    static func mayOpen(in appState: AppState) -> Bool {
        appState.hasCompletedOnboarding && appState.authService.hasStoredCredentials
            && !appState.isShowingNTUSTLoginSheet
    }

    func take(in appState: AppState) -> String? {
        take(mayOpen: Self.mayOpen(in: appState), loginGeneration: appState.authService.loginGeneration)
    }

    /// The held link's text, taken, once it may open; nil while it may not, and for one that
    /// came before a sign-out, which this drops.
    func take(mayOpen: Bool, loginGeneration: Int) -> String? {
        guard let link else { return nil }
        guard link.loginGeneration == loginGeneration else {
            self.link = nil
            return nil
        }
        guard mayOpen else { return nil }
        self.link = nil
        return link.text
    }
}
