import SwiftUI

struct MoreEditModeView: View {
    @Binding var isEditing: Bool

    var body: some View {
        // Placeholder for future drag-to-reorder and hide/show functionality
        Text(String(localized: "more_edit_mode_in_development"))
            .foregroundStyle(Color.textSecondary)
    }
}
