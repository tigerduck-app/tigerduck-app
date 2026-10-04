#if os(iOS)
import SwiftUI
import UIKit

/// The system share sheet for one local file, for use inside `.sheet`.
///
/// A file URL rather than the file's contents, so the sheet offers what the
/// file is: an image gets Save Image next to Save to Files and AirDrop, and
/// every destination receives the file under its own name.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
