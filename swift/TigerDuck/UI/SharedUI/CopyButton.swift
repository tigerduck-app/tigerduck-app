import SwiftUI

/// Copies `text` and says so with `toast` through the nearest `toastHost()` above it, and the
/// success haptic.
struct CopyButton<Label: View>: View {
    let text: String
    let toast: LocalizedStringResource
    @ViewBuilder let label: () -> Label

    @Environment(\.showToast) private var showToast
    @State private var copies = 0

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copies += 1
            showToast(toast)
        } label: {
            label()
        }
        .sensoryFeedback(.success, trigger: copies)
    }
}
