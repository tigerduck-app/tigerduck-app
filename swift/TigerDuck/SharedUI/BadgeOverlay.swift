import SwiftUI

extension View {
    func assignmentBadge(show: Bool, color: Color) -> some View {
        overlay(alignment: .bottom) {
            if show {
                Capsule()
                    .fill(color)
                    .frame(width: 16, height: 3)
                    .padding(.bottom, 6)
            }
        }
    }
}

