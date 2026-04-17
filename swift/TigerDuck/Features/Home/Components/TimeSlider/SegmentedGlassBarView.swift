import SwiftUI

struct SegmentedGlassBarView: View {
    var viewModel: TimeSliderViewModel
    var invertDirection: Bool = false
    var policy: VisualStylePolicy = VisualStylePolicy(preset: .default)
    @Namespace private var segmentNamespace
    @State private var lastDragX: CGFloat = 0

    private let barHeight = TimeSliderMetrics.segmentedBarHeight

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let centerX = width / 2

            segmentedBarContent(centerX: centerX, width: width)
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
                    }
            )
        }
        .frame(height: barHeight)
    }

    @ViewBuilder
    private func segmentedBarContent(centerX: CGFloat, width: CGFloat) -> some View {
        let content = ZStack {
            ForEach(viewModel.timeSlots) { slot in
                let startOffset = viewModel.xOffset(for: slot.start)
                let endOffset = viewModel.xOffset(for: slot.end)
                let segWidth = max(TimeSliderMetrics.minimumSegmentedBlockWidth, endOffset - startOffset)
                let segCenterX = centerX + (startOffset + endOffset) / 2

                // Only render if visible
                if segCenterX + segWidth / 2 > -50 && segCenterX - segWidth / 2 < width + 50 {
                    let isSelected = viewModel.selectedTime >= slot.start
                        && viewModel.selectedTime <= slot.end

                    segmentButton(slot: slot, isSelected: isSelected, segWidth: segWidth, segCenterX: segCenterX)
                }
            }

            // Center indicator
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.4))
                .frame(width: 2, height: barHeight - 8)
                .position(x: centerX, y: barHeight / 2)
        }

        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 4) {
                content
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func segmentButton(slot: CourseTimeSlot, isSelected: Bool, segWidth: CGFloat, segCenterX: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        let tint = slot.course.color.opacity(
            policy.segmentedBarTintOpacity(isSelected: isSelected)
        )

        Button {
            viewModel.onDragStarted()
            withAnimation(.smooth(duration: 0.35)) {
                viewModel.selectedTime = slot.start
            }
        } label: {
            Text(slot.course.courseName)
                .font(isSelected ? .caption.bold() : .caption2)
                .foregroundStyle(labelColor(for: slot, isSelected: isSelected))
                .lineLimit(1)
                .frame(width: segWidth, height: barHeight - 4)
        }
        .buttonStyle(.plain)
        .modifier(SegmentGlassModifier(tint: tint, shape: shape, glassID: slot.id, namespace: segmentNamespace))
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.smooth(duration: 0.3), value: isSelected)
        .position(x: segCenterX, y: barHeight / 2)
    }

    private func labelColor(for slot: CourseTimeSlot, isSelected: Bool) -> Color {
        switch policy.preset {
        case .default:
            return slot.course.color.opacity(isSelected ? 1.0 : 0.7)
        case .iosInspired:
            // iOS preset: label stays neutral when inactive, uses course
            // color only when selected, and even then at reduced saturation
            // so the overall bar reads system-y.
            if isSelected {
                return slot.course.color.opacity(0.95)
            } else {
                return .secondary
            }
        }
    }
}

// MARK: - Availability Helpers

private struct SegmentGlassModifier<ID: Hashable, S: Shape>: ViewModifier {
    let tint: Color
    let shape: S
    let glassID: ID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular.tint(tint), in: shape)
                .glassEffectID(glassID, in: namespace)
        } else {
            content
                .background(tint, in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}
