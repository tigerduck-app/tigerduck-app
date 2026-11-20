import SwiftUI
import TigerDuckCore

struct TimetableCell: View {
    let viewModel: ClassTableViewModel
    let role: ClassTableGrid.CellRole
    let key: String
    let weekday: Int
    let periodId: String
    let meeting: CourseTimeSlot?
    let showsAssignmentBadges: Bool
    let differentiateWithoutColor: Bool?
    let drawsPeriodTiles: Bool
    let metrics: TimetableCellMetrics
    let withClubs: Bool

    private static let courseFade = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.1)),
        removal: .opacity.animation(.easeIn(duration: 0.1))
    )

    var body: some View {
        switch role {
        case .empty:
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                .fill(drawsPeriodTiles ? Color.clear : Color.emptyCellFill)
                .transition(.identity)

        case .solo(let course, let spanCount):
            TimetableSoloCell(
                viewModel: viewModel, course: course, spanCount: spanCount, weekday: weekday, periodId: periodId,
                meeting: meeting, showsAssignmentBadges: showsAssignmentBadges, drawsPeriodTiles: drawsPeriodTiles,
                metrics: metrics, withClubs: withClubs
            )
            .id(key)
            .transition(Self.courseFade)
            .zIndex(1)

        case let .conflictStart(courseA, spanA, offsetA, courseB, spanB, offsetB, combinedSpan):
            conflictCluster(
                segments: [
                    ClassTableConflictSegment(course: courseA, key: courseA.courseNo, span: spanA, offset: offsetA, lane: 0),
                    ClassTableConflictSegment(course: courseB, key: courseB.courseNo, span: spanB, offset: offsetB, lane: 1),
                ],
                combinedSpan: combinedSpan,
                laneCount: 2,
                weekday: weekday,
                periodId: periodId
            )
            .id(key)
            .transition(Self.courseFade)
            .zIndex(1)

        case let .conflictMany(segments, combinedSpan, laneCount):
            conflictCluster(
                segments: segments,
                combinedSpan: combinedSpan,
                laneCount: laneCount,
                weekday: weekday,
                periodId: periodId
            )
            .id(key)
            .transition(Self.courseFade)
            .zIndex(1)

        case .skip:
            Color.clear
                .transition(.identity)
        }
    }

    private func conflictCluster(
        segments: [ClassTableConflictSegment<CourseStore.Course>],
        combinedSpan: Int,
        laneCount: Int,
        weekday: Int,
        periodId: String
    ) -> some View {
        Color.clear
            .overlay(alignment: .top) {
                ConflictClusterView(
                    cluster: ConflictCluster(
                        viewModel: viewModel, showsAssignmentBadges: showsAssignmentBadges, segments: segments,
                        laneCount: laneCount, weekday: weekday, periodId: periodId, metrics: metrics,
                        withClubs: withClubs
                    ),
                    differentiateWithoutColorOverride: differentiateWithoutColor
                )
                .frame(height: metrics.height(spanning: combinedSpan))
            }
    }
}
