import SwiftUI

struct FluidGlassTrackView: View {
    var viewModel: TimeSliderViewModel
    var invertDirection: Bool = false
    var policy: VisualStylePolicy = VisualStylePolicy(preset: .default)
    @State private var lastDragX: CGFloat = 0
    @Environment(\.layoutDirection) private var layoutDirection

    private let trackHeight = TimeSliderMetrics.fluidTrackHeight

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let centerX = width / 2
            let rtlFactor: CGFloat = layoutDirection == .rightToLeft ? -1 : 1

            ZStack {
                if #available(iOS 26, *) {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular, in: .capsule)
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                }

                tickMarks(centerX: centerX, visibleWidth: width, rtlFactor: rtlFactor)

                ForEach(viewModel.timeSlots) { slot in
                    let startOffset = viewModel.xOffset(for: slot.start)
                    let endOffset = viewModel.xOffset(for: slot.end)
                    let segWidth = max(TimeSliderMetrics.minimumFluidBlockWidth, endOffset - startOffset)
                    let segCenterX = centerX + rtlFactor * (startOffset + endOffset) / 2

                    if segCenterX + segWidth / 2 > -50 && segCenterX - segWidth / 2 < width + 50 {
                        let isActive = viewModel.selectedTime >= slot.start && viewModel.selectedTime <= slot.end
                        let segOpacity = isActive
                            ? policy.timeSliderActiveSegmentOpacity
                            : policy.timeSliderInactiveSegmentOpacity
                        let lane = viewModel.slotLanes[slot.id] ?? TimeSliderLane(lane: 0, count: 1)
                        let laneHeight = TimeSliderMetrics.fluidSegmentHeight / CGFloat(lane.count)
                        let laneTop = (trackHeight - TimeSliderMetrics.fluidSegmentHeight) / 2 + CGFloat(lane.lane) * laneHeight
                        let top: CGFloat = lane.lane == 0 ? 4 : 0
                        let bottom: CGFloat = lane.lane == lane.count - 1 ? 4 : 0

                        UnevenRoundedRectangle(
                            topLeadingRadius: top,
                            bottomLeadingRadius: bottom,
                            bottomTrailingRadius: bottom,
                            topTrailingRadius: top
                        )
                            .fill(slot.course.color.opacity(segOpacity))
                            .frame(width: segWidth, height: laneHeight)
                            .position(x: segCenterX, y: laneTop + laneHeight / 2)
                            .animation(.smooth(duration: 0.2), value: isActive)
                    }
                }

                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(0.7))
                    .frame(width: TimeSliderMetrics.selectionThumbWidth, height: TimeSliderMetrics.selectionThumbHeight)
                    .position(x: centerX, y: trackHeight / 2)

                Circle()
                    .fill(thumbGlowColor)
                    .frame(width: TimeSliderMetrics.glowDotSize, height: TimeSliderMetrics.glowDotSize)
                    .shadow(color: thumbGlowColor.opacity(0.6), radius: 6)
                    .position(x: centerX, y: trackHeight / 2)
            }
            .frame(height: trackHeight)
            .clipShape(Capsule())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let rawDelta = value.translation.width - lastDragX
                        lastDragX = value.translation.width
                        let dx = layoutDirection == .rightToLeft ? -rawDelta : rawDelta
                        viewModel.onDragChanged(dx: dx, invertDirection: invertDirection)
                    }
                    .onEnded { _ in
                        lastDragX = 0
                    }
            )
        }
        .frame(height: trackHeight)
    }

    @ViewBuilder
    private func tickMarks(centerX: CGFloat, visibleWidth: CGFloat, rtlFactor: CGFloat) -> some View {
        let markerInterval = TimeSliderMetrics.markerIntervalMinutes * 60
        let majorInterval = TimeSliderMetrics.majorMarkerIntervalMinutes * 60

        let selectedRef = viewModel.selectedTime.timeIntervalSinceReferenceDate

        let visibleMinutes = Double(visibleWidth / TimeSliderMetrics.pointsPerMinute)
        let rangeStart = selectedRef - visibleMinutes * 60
        let rangeEnd = selectedRef + visibleMinutes * 60

        let firstMarker = floor(rangeStart / markerInterval) * markerInterval

        Canvas { context, size in
            var t = firstMarker
            while t <= rangeEnd {
                let markerDate = Date(timeIntervalSinceReferenceDate: t)
                let x = centerX + rtlFactor * viewModel.xOffset(for: markerDate)

                if x > -10 && x < size.width + 10 {
                    let isMajor = t.truncatingRemainder(dividingBy: majorInterval) == 0

                    if isMajor {
                        let rect = CGRect(
                            x: x - 0.5,
                            y: (trackHeight - TimeSliderMetrics.majorMarkerHeight) / 2,
                            width: 1,
                            height: TimeSliderMetrics.majorMarkerHeight
                        )
                        context.fill(Path(rect), with: .color(.white.opacity(0.15)))
                    } else {
                        let dotSize = TimeSliderMetrics.markerDotSize
                        let rect = CGRect(
                            x: x - dotSize / 2,
                            y: trackHeight / 2 - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.1)))
                    }
                }

                t += markerInterval
            }
        }
        .allowsHitTesting(false)
    }

    private var thumbGlowColor: Color {
        guard policy.timeSliderUsesCourseColoredThumb else {
            return .white
        }
        if case .inClass(let slots) = viewModel.currentCourseState, let slot = slots.first {
            return slot.course.color
        }
        return .white
    }
}
