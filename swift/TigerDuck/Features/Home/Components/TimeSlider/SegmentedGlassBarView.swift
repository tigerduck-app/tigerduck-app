import SwiftUI

struct SegmentedGlassBarView: View {
    var viewModel: TimeSliderViewModel
    @Namespace private var segmentNamespace

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(viewModel.timeSlots) { slot in
                    let isSelected = viewModel.selectedTime >= slot.start
                        && viewModel.selectedTime <= slot.end
                    let duration = slot.end.timeIntervalSince(slot.start)

                    Button {
                        viewModel.onDragStarted()
                        withAnimation(.smooth(duration: 0.35)) {
                            viewModel.selectedTime = slot.start
                        }
                        viewModel.startAutoReturn()
                    } label: {
                        Text(slot.course.courseName)
                            .font(isSelected ? .caption.bold() : .caption2)
                            .foregroundStyle(
                                slot.course.color.opacity(isSelected ? 1.0 : 0.7)
                            )
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        .regular.tint(slot.course.color.opacity(isSelected ? 0.4 : 0.15)),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .glassEffectID(slot.id, in: segmentNamespace)
                    .scaleEffect(isSelected ? 1.05 : 1.0)
                    .animation(.smooth(duration: 0.3), value: isSelected)
                    .layoutPriority(duration)
                }
            }
        }
        .frame(height: 44)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let direction = value.translation.width
                    guard let currentIndex = currentSlotIndex else { return }
                    let targetIndex: Int
                    if direction < 0 {
                        targetIndex = min(currentIndex + 1, viewModel.timeSlots.count - 1)
                    } else {
                        targetIndex = max(currentIndex - 1, 0)
                    }
                    viewModel.onDragStarted()
                    withAnimation(.smooth(duration: 0.35)) {
                        viewModel.selectedTime = viewModel.timeSlots[targetIndex].start
                    }
                    viewModel.startAutoReturn()
                }
        )
    }

    private var currentSlotIndex: Int? {
        viewModel.timeSlots.firstIndex { slot in
            viewModel.selectedTime >= slot.start && viewModel.selectedTime <= slot.end
        } ?? viewModel.timeSlots.firstIndex { slot in
            slot.start > viewModel.selectedTime
        }.map { max(0, $0 - 1) }
    }
}
