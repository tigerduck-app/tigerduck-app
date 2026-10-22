#if os(iOS)
import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let dismiss = context.environment.dismiss
        controller.completionWithItemsHandler = { _, _, _, _ in dismiss() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
