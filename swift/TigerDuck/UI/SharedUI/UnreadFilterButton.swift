import SwiftUI

/// The filter of a list with read and unread items: a tap switches between all and unread only,
/// and a long press offers to mark every shown item read, which VoiceOver also lists among the
/// filter's actions.
struct UnreadFilterButton<Icon: View>: View {
    @Binding var unreadOnly: Bool
    /// Names the unread-only state, which VoiceOver reads as selected while it is on.
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
