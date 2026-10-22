import SwiftUI
import SafariServices

/// SFSafariViewController only safely accepts http(s). Other schemes
/// (`javascript:`, `data:`, `file:`) crash on init, so the wrapper falls
/// back to a graceful unsupported-URL view instead of forwarding the URL
/// blindly.
struct InAppBrowserView: View {
    let url: URL

    var body: some View {
        if Self.isSupported(url) {
            SafariRepresentable(url: url)
                .ignoresSafeArea()
        } else {
            UnsupportedURLView(url: url)
        }
    }

    private static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

private struct SafariRepresentable: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct UnsupportedURLView: View {
    let url: URL

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("error_browser_unsupported_url")
                .font(.headline)
            Text(url.absoluteString)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .padding(.horizontal)
        }
        .padding()
    }
}
