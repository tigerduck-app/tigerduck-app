import SwiftUI

struct UnreadFilterButton<Icon: View>: View {
    @Binding var unreadOnly: Bool
    let accessibilityLabel: String
    let markAllReadTitle: String
    /// Nil while nothing shown is unread.
    let markAllRead: (() -> Void)?
    @ViewBuilder let icon: (_ systemName: String) -> Icon

    var body: some View {
        Menu {
            Button(markAllReadTitle, systemImage: "checkmark.circle") { markAllRead?() }
                .disabled(markAllRead == nil)
        } label: {
            icon(unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        } primaryAction: {
            unreadOnly.toggle()
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(unreadOnly ? .isSelected : [])
        .accessibilityActions {
            if let markAllRead { Button(markAllReadTitle, action: markAllRead) }
        }
    }
}
