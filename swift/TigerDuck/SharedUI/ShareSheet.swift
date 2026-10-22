#if os(iOS)
import SwiftUI
import UIKit

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
