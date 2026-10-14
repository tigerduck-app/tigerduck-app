import SwiftUI

extension View {
    func assignmentBadge(
        show: Bool,
        iconSize: CGFloat = 14,
        padding: CGFloat = 7,
        color: Color = Color.textSecondary.opacity(0.5)
    ) -> some View {
        overlay(alignment: .bottomTrailing) {
            if show {
                // Read with the course card it sits on. The class table cells set a label
                // of their own, which names the mark instead.
                Image(systemName: "book.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(color)
                    .padding([.bottom, .trailing], padding)
                    .accessibilityLabel(Text(String(localized: "a11y_class_table_cell_assignment_indicator")))
            }
        }
    }

    /// The class table's mark for a course whose assignments are all ignored. It takes the
    /// assignment badge's place, which such a course never shows.
    func ignoredAssignmentsBadge(
        show: Bool,
        iconSize: CGFloat,
        padding: CGFloat,
        color: Color = Color.textSecondary.opacity(0.5)
    ) -> some View {
        overlay(alignment: .bottomTrailing) {
            if show {
                IgnoredAssignmentsIcon(size: iconSize)
                    .foregroundStyle(color)
                    .padding([.bottom, .trailing], padding)
                    .accessibilityLabel(Text(String(localized: "a11y_class_table_cell_assignments_ignored")))
            }
        }
    }
}

/// `book.fill` struck through like the system's slashed symbols, since SF Symbols has no
/// slashed book.
struct IgnoredAssignmentsIcon: View {
    let size: CGFloat

    var body: some View {
        let lineWidth = size * 0.09
        Image(systemName: "book.fill")
            .font(.system(size: size))
            // A clear band on the slash's upper side keeps it apart from the fill, as the system draws it.
            .mask {
                Rectangle()
                    .overlay {
                        Slash(offset: lineWidth / 2).stroke(style: StrokeStyle(lineWidth: lineWidth * 2, lineCap: .round))
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            .overlay {
                Slash(offset: 0).stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
    }

    /// A line at 45 degrees down to the right across a square centred in the frame, moved `offset`
    /// towards the upper right.
    private struct Slash: Shape {
        let offset: CGFloat

        func path(in rect: CGRect) -> Path {
            let half = min(rect.width, rect.height) / 2
            let shift = offset / 2.squareRoot()
            let center = CGPoint(x: rect.midX + shift, y: rect.midY - shift)
            return Path { path in
                path.move(to: CGPoint(x: center.x - half, y: center.y - half))
                path.addLine(to: CGPoint(x: center.x + half, y: center.y + half))
            }
        }
    }
}
