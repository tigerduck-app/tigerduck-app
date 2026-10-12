import SwiftUI

extension OpenURLAction {
    /// Opens `url`, then `fallback` when nothing on the device takes `url`, as with a
    /// `moodlemobile://` link where the Moodle app is not installed.
    func callAsFunction(_ url: URL, fallback: URL?) {
        self(url) { accepted in
            guard !accepted, let fallback, fallback != url else { return }
            self(fallback)
        }
    }
}
