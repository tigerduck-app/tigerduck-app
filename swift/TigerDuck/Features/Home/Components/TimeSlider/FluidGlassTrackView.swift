import SwiftUI

struct FluidGlassTrackView: View {
    var viewModel: TimeSliderViewModel

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .leading) {
                // Glass track background
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular, in: .capsule)

                // Course segments
                ForEach(viewModel.timeSlots) { slot in
                    let startX = viewModel.normalizedPosition(for: slot.start) * width
                    let endX = viewModel.normalizedPosition(for: slot.end) * width
                    let segWidth = max(4, endX - startX)
                    let isActive = viewModel.selectedTime >= slot.start && viewModel.selectedTime <= slot.end

                    RoundedRectangle(cornerRadius: 4)
                        .fill(slot.course.color.opacity(isActive ? 0.5 : 0.3))
                        .frame(width: segWidth, height: 24)
                        .offset(x: startX)
                        .animation(.smooth(duration: 0.2), value: isActive)
                }

                // Thumb
                let thumbX = viewModel.normalizedPosition(for: viewModel.selectedTime) * width

                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle().stroke(.white.opacity(0.5), lineWidth: 2)
                    )
                    .shadow(color: thumbGlowColor.opacity(0.4), radius: 8)
                    .offset(x: thumbX - 12)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !viewModel.isUserDragging {
                            viewModel.onDragStarted()
                        }
                        let normalized = max(0, min(1, value.location.x / width))
                        viewModel.selectedTime = viewModel.time(forNormalized: normalized)
                    }
                    .onEnded { _ in
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
