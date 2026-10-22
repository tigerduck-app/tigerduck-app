import SwiftUI

extension OpenURLAction {
    /// Opens `url`, then `fallback` when nothing on the device takes `url`, as with a
    /// `moodlemobile://` link where the Moodle app is not installed. Either one opens signed in
    /// through `autologin` when it is a Moodle web page; a link the Moodle app takes asks for no key.
    func callAsFunction(_ url: URL, fallback: URL?, autologin: MoodleAutologinService = .shared) async {
        if await accepts(await autologin.url(for: url)) { return }
        guard let fallback, fallback != url else { return }
        self(await autologin.url(for: fallback))
    }

    private func accepts(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            self(url) { continuation.resume(returning: $0) }
        }
    }
}
