import SwiftUI

extension View {
    func assignmentBadge(show: Bool) -> some View {
        overlay(alignment: .bottomTrailing) {
            if show {
                Image(systemName: "book.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.gray.opacity(0.5))
                    .padding([.bottom, .trailing], 7)
            }
        }
    }
}

