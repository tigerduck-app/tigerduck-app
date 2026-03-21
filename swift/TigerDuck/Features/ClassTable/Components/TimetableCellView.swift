import SwiftUI

struct TimetableCellView: View {
    let course: SDCourse?
    let hasBadge: Bool
    let onTap: () -> Void

    var body: some View {
        if let course {
            Button(action: onTap) {
                RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                    .fill(course.color.opacity(0.25))
                    .overlay {
                        RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                            .strokeBorder(course.color.opacity(0.4), lineWidth: 1)
                    }
                    .overlay {
                        Text(course.courseName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(4)
                    }
                    .overlay(alignment: .bottom) {
                        if hasBadge {
                            Capsule()
                                .fill(course.color)
                                .frame(width: 16, height: 3)
                                .padding(.bottom, 3)
                        }
                    }
            }
            .buttonStyle(.plain)
        } else {
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                .fill(Color.cardSurface.opacity(0.15))
        }
    }
}
