import SwiftUI

struct SkipClassButton: View {
    let course: SDCourse
    let onSkip: (SDCourse) -> Void
    @State private var flyAway = false

    private var isSkipped: Bool {
        course.isSkipped(on: Date())
    }

    var body: some View {
        Button {
            if isSkipped {
                course.toggleSkip(on: Date())
            } else {
                withAnimation(.spring(duration: 0.5, bounce: 0.3)) {
                    flyAway = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    course.toggleSkip(on: Date())
                    onSkip(course)
                    withAnimation(.smooth(duration: 0.3)) {
                        flyAway = false
                    }
                }
            }
        } label: {
            Text(isSkipped ? "已翹" : "翹")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .modifier(SkipGlassModifier(isSkipped: isSkipped))
        .offset(y: flyAway ? -80 : 0)
        .rotationEffect(flyAway ? .degrees(-15) : .zero)
        .scaleEffect(flyAway ? 0.3 : 1.0)
        .opacity(flyAway ? 0 : 1)
    }
}

// MARK: - Availability Helpers

private struct SkipGlassModifier: ViewModifier {
    let isSkipped: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(
                isSkipped ? .regular.tint(.white.opacity(0.3)) : .regular.interactive(),
                in: .capsule
            )
        } else {
            content.background(
                isSkipped ? .white.opacity(0.15) : .ultraThinMaterial,
                in: Capsule()
            )
        }
    }
}
