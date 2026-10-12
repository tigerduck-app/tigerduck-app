import SwiftUI

extension View {
    func assignmentBadge(show: Bool, iconSize: CGFloat = 14, padding: CGFloat = 7) -> some View {
        overlay(alignment: .bottomTrailing) {
            if show {
                // Read with the course card it sits on. The class table cells set a label
                // of their own, which names the mark instead.
                Image(systemName: "book.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(Color.textSecondary.opacity(0.5))
                    .padding([.bottom, .trailing], padding)
                    .accessibilityLabel(Text(String(localized: "a11y_class_table_cell_assignment_indicator")))
            }
        }
    }
}

