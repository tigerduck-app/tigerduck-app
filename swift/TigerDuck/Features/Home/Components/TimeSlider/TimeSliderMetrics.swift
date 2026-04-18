import CoreGraphics

enum TimeSliderMetrics {
    // MARK: - Timeline Density (tweak these for best UX)

    /// Base points-per-minute for course blocks. Lower = smaller blocks = faster scrolling.
    static let pointsPerMinute: CGFloat = 0.9

    /// Logarithmic compression reference. Gaps longer than this get compressed harder.
    static let logarithmicReferenceMinutes: Double = 30

    /// Minimum visual gap (points) kept between consecutive courses after compression.
    static let minimumGapPoints: CGFloat = 20

    /// Maximum visual gap (points) for even the longest breaks.
    static let maximumGapPoints: CGFloat = 80

    // MARK: - Multi-day Timeline

    /// Number of days loaded on both sides of the selected date.
    static let timelineDayRadius: Int = 28

    /// Rebuild when the selection approaches this many days from the loaded edge.
    static let timelineRebuildTriggerDays: Int = 7

    /// Visual gap (points) inserted between the last course of one day and first of next.
    static let dayBoundaryGapPoints: CGFloat = 40

    // MARK: - Track Appearance

    static let fluidTrackHeight: CGFloat = 36
    static let fluidSegmentHeight: CGFloat = 20
    static let minimumFluidBlockWidth: CGFloat = 28

    // MARK: - Tick Marks

    /// Interval (minutes) between small dot markers on the track.
    static let markerIntervalMinutes: Double = 15

    /// Interval (minutes) between tall line markers.
    static let majorMarkerIntervalMinutes: Double = 60

    static let markerDotSize: CGFloat = 3
    static let majorMarkerHeight: CGFloat = 14

    // MARK: - Haptics

    /// Crossing each interval emits one selection haptic while dragging.
    static let dragHapticIntervalMinutes: Double = 15

    // MARK: - Selection Thumb

    static let selectionThumbWidth: CGFloat = 2
    static let selectionThumbHeight: CGFloat = 28
    static let glowDotSize: CGFloat = 8
}
