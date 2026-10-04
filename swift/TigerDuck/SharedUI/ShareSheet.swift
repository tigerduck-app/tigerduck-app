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
        // Inside `.sheet` the activity controller is a child, not the
        // presented controller, so when it finishes on its own SwiftUI's
        // item binding stays set: the sheet is left blank, or gone while
        // SwiftUI still thinks it is up — and the next share of the same
        // file, same URL and so same id, never presents. Close through
        // SwiftUI instead, once an activity completes or the share sheet
        // itself is closed (no activity chosen).
        let dismiss = context.environment.dismiss
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            if completed || activityType == nil { dismiss() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
