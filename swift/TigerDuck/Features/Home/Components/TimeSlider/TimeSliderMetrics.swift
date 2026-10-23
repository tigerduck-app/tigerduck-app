import CoreGraphics

enum TimeSliderMetrics {

    static let pointsPerMinute: CGFloat = 0.9

    static let logarithmicReferenceMinutes: Double = 30

    static let minimumGapPoints: CGFloat = 20

    static let maximumGapPoints: CGFloat = 80

    static let timelineDayRadius: Int = CourseTimeSlot.defaultDayRadius

    static let timelineRebuildTriggerDays: Int = 7

    static let dayBoundaryGapPoints: CGFloat = 40

    static let fluidTrackHeight: CGFloat = 36
    static let fluidSegmentHeight: CGFloat = 20
    static let minimumFluidBlockWidth: CGFloat = 28

    static let markerIntervalMinutes: Double = 15

    static let majorMarkerIntervalMinutes: Double = 60

    static let markerDotSize: CGFloat = 3
    static let majorMarkerHeight: CGFloat = 14

    static let dragHapticIntervalMinutes: Double = 15

    static let selectionThumbWidth: CGFloat = 2
    static let selectionThumbHeight: CGFloat = 28
    static let glowDotSize: CGFloat = 8
}
