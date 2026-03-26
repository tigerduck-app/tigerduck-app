import SwiftUI

struct SegmentedGlassBarView: View {
    var viewModel: TimeSliderViewModel
    var invertDirection: Bool = false
    @Namespace private var segmentNamespace
    @State private var lastDragX: CGFloat = 0

    private let barHeight = TimeSliderMetrics.segmentedBarHeight

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let centerX = width / 2

            GlassEffectContainer(spacing: 4) {
                ZStack {
                    ForEach(viewModel.timeSlots) { slot in
                        let startOffset = viewModel.xOffset(for: slot.start)
                        let endOffset = viewModel.xOffset(for: slot.end)
                        let segWidth = max(TimeSliderMetrics.minimumSegmentedBlockWidth, endOffset - startOffset)
                        let segCenterX = centerX + (startOffset + endOffset) / 2

                        // Only render if visible
                        if segCenterX + segWidth / 2 > -50 && segCenterX - segWidth / 2 < width + 50 {
                            let isSelected = viewModel.selectedTime >= slot.start
                                && viewModel.selectedTime <= slot.end

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
                                    .frame(width: segWidth, height: barHeight - 4)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(
                                .regular.tint(slot.course.color.opacity(isSelected ? 0.4 : 0.15)),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .glassEffectID(slot.id, in: segmentNamespace)
                            .scaleEffect(isSelected ? 1.05 : 1.0)
                            .animation(.smooth(duration: 0.3), value: isSelected)
                            .position(x: segCenterX, y: barHeight / 2)
                        }
                    }

                    // Center indicator
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.4))
                        .frame(width: 2, height: barHeight - 8)
                        .position(x: centerX, y: barHeight / 2)
                }
            }
            .frame(height: barHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 5)
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
        .frame(height: barHeight)
    }
}
