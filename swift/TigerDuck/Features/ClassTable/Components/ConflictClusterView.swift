import SwiftUI

struct ConflictCluster {
    let viewModel: ClassTableViewModel
    let showsAssignmentBadges: Bool
    let segments: [ClassTableConflictSegment<CourseStore.Course>]
    let laneCount: Int
    let weekday: Int
    let periodId: String
    let metrics: TimetableCellMetrics

    var periodLabel: String {
        viewModel.grid.activePeriods.first { $0.id == periodId }?.displayLabel ?? periodId
    }

    func showsBadge(for course: CourseStore.Course) -> Bool {
        showsAssignmentBadges && viewModel.hasAssignment(for: course.courseNo)
    }

    func showsIgnoredMark(for course: CourseStore.Course) -> Bool {
        showsAssignmentBadges && viewModel.editor.ignoresAssignments(of: course.courseNo)
    }
}

struct ConflictClusterView: View {
    let cluster: ConflictCluster
    let differentiateWithoutColorOverride: Bool?

    @Environment(\.accessibilityDifferentiateWithoutColor) private var environmentDiffWithoutColor
    private var diffWithoutColor: Bool { differentiateWithoutColorOverride ?? environmentDiffWithoutColor }

    var body: some View {
        if cluster.segments.count == 2 {
            ConflictPairView(cluster: cluster, diffWithoutColor: diffWithoutColor)
        } else {
            ConflictLanesView(cluster: cluster, diffWithoutColor: diffWithoutColor)
        }
    }
}
