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
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // In `.sheet` the controller is a child, so finishing on its own leaves the
        // item binding set and the next share of the same file (same id) never shows.
        // UIKit calls this after any dismissal, so close through SwiftUI every time.
        let dismiss = context.environment.dismiss
        controller.completionWithItemsHandler = { _, _, _, _ in dismiss() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
