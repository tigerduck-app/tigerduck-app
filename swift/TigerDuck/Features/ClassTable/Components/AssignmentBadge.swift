import SwiftUI

// Assignment badge is implemented as a View modifier in SharedUI/BadgeOverlay.swift
// This file provides additional assignment-related badge utilities if needed.

struct AssignmentCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.badgeRed, in: Capsule())
        }
    }
}
