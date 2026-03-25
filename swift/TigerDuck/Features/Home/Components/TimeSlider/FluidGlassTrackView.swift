import SwiftUI

struct FluidGlassTrackView: View {
    var viewModel: TimeSliderViewModel
    var invertDirection: Bool = false
    @State private var lastDragX: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let centerX = width / 2

            ZStack {
                // Glass track background
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular, in: .capsule)

                // Course segments positioned relative to center
                ForEach(viewModel.timeSlots) { slot in
                    let startOffset = viewModel.xOffset(for: slot.start)
                    let endOffset = viewModel.xOffset(for: slot.end)
                    let segWidth = max(4, endOffset - startOffset)
                    let segCenterX = centerX + (startOffset + endOffset) / 2
                    let isActive = viewModel.selectedTime >= slot.start && viewModel.selectedTime <= slot.end

                    RoundedRectangle(cornerRadius: 4)
                        .fill(slot.course.color.opacity(isActive ? 0.5 : 0.3))
                        .frame(width: segWidth, height: 24)
                        .position(x: segCenterX, y: 16)
                        .animation(.smooth(duration: 0.2), value: isActive)
                }

                // Center indicator (current selection point)
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(0.7))
                    .frame(width: 2, height: 28)
                    .position(x: centerX, y: 16)

                // Glow dot at center
                Circle()
                    .fill(thumbGlowColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: thumbGlowColor.opacity(0.6), radius: 6)
                    .position(x: centerX, y: 16)
            }
            .frame(height: 32)
            .clipShape(Capsule())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.translation.width - lastDragX
                        lastDragX = value.translation.width
                        viewModel.onDragChanged(dx: dx, invertDirection: invertDirection)
                    }
                    .onEnded { _ in
                        lastDragX = 0
                        viewModel.onDragEnded()
                    }
            )
        }
        .frame(height: 32)
    }

    private var thumbGlowColor: Color {
        if case .inClass(let course) = viewModel.currentCourseState {
            return course.color
        }
        return .white
    }
}
