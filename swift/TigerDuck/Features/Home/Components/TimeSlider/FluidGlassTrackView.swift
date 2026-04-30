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

            ZStack {
                // Glass track background
                if #available(iOS 26, *) {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular, in: .capsule)
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                }

                // Tick marks
                tickMarks(centerX: centerX, visibleWidth: width)

                // Course segments positioned relative to center
                ForEach(viewModel.timeSlots) { slot in
                    let startOffset = viewModel.xOffset(for: slot.start)
                    let endOffset = viewModel.xOffset(for: slot.end)
                    let segWidth = max(TimeSliderMetrics.minimumFluidBlockWidth, endOffset - startOffset)
                    let segCenterX = centerX + (startOffset + endOffset) / 2

                    // Only render if visible
                    if segCenterX + segWidth / 2 > -50 && segCenterX - segWidth / 2 < width + 50 {
                        let isActive = viewModel.selectedTime >= slot.start && viewModel.selectedTime <= slot.end
                        let segOpacity = isActive
                            ? policy.timeSliderActiveSegmentOpacity
                            : policy.timeSliderInactiveSegmentOpacity

                        RoundedRectangle(cornerRadius: 4)
                            .fill(slot.course.color.opacity(segOpacity))
                            .frame(width: segWidth, height: TimeSliderMetrics.fluidSegmentHeight)
                            .position(x: segCenterX, y: trackHeight / 2)
                            .animation(.smooth(duration: 0.2), value: isActive)
                    }
                }

                // Center indicator
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(0.7))
                    .frame(width: TimeSliderMetrics.selectionThumbWidth, height: TimeSliderMetrics.selectionThumbHeight)
                    .position(x: centerX, y: trackHeight / 2)

                // Glow dot
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

    // MARK: - Tick Marks

    @ViewBuilder
    private func tickMarks(centerX: CGFloat, visibleWidth: CGFloat) -> some View {
        let markerInterval = TimeSliderMetrics.markerIntervalMinutes * 60
        let majorInterval = TimeSliderMetrics.majorMarkerIntervalMinutes * 60

        // Determine visible time range
        let selectedRef = viewModel.selectedTime.timeIntervalSinceReferenceDate

        // Generate markers covering visible range
        let visibleMinutes = Double(visibleWidth / TimeSliderMetrics.pointsPerMinute)
        let rangeStart = selectedRef - visibleMinutes * 60
        let rangeEnd = selectedRef + visibleMinutes * 60

        let firstMarker = floor(rangeStart / markerInterval) * markerInterval

        Canvas { context, size in
            var t = firstMarker
            while t <= rangeEnd {
                let markerDate = Date(timeIntervalSinceReferenceDate: t)
                let x = centerX + viewModel.xOffset(for: markerDate)

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
        if case .inClass(let slot) = viewModel.currentCourseState {
            return slot.course.color
        }
        return .white
    }
}
