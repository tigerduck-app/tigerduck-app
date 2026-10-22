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
                Image(systemName: "book.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(color)
                    .padding([.bottom, .trailing], padding)
                    .accessibilityLabel(Text(String(localized: "a11y_class_table_cell_assignment_indicator")))
            }
        }
    }

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

struct IgnoredAssignmentsIcon: View {
    let size: CGFloat

    var body: some View {
        let lineWidth = size * 0.09
        Image(systemName: "book.fill")
            .font(.system(size: size))
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
