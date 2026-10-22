import SwiftUI

extension OpenURLAction {
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
