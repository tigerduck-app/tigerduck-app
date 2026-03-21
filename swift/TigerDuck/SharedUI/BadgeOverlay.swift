import SwiftUI

struct BadgeOverlay: View {
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(Color.badgeRed)
            .frame(width: size, height: size)
    }
}

extension View {
    func assignmentBadge(show: Bool, size: CGFloat = 12) -> some View {
        overlay(alignment: .topTrailing) {
            if show {
                BadgeOverlay(size: size)
                    .offset(x: 4, y: -4)
            }
        }
    }
}

