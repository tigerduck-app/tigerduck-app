import Defaults
import SwiftUI

struct TimetableSoloCell: View {
    let viewModel: ClassTableViewModel
    let course: CourseStore.Course
    let spanCount: Int
    let weekday: Int
    let periodId: String
    let meeting: CourseTimeSlot?
    let showsAssignmentBadges: Bool
    let drawsPeriodTiles: Bool
    let metrics: TimetableCellMetrics

    @Environment(AppEnvironment.self) private var app
    @Default(.outlineRequiredCourses) private var outlineRequiredCourses

    private var policy: VisualStylePolicy { app.preferences.visualStylePolicy }

    var body: some View {
        let hasBadge = showsAssignmentBadges && viewModel.hasAssignment(for: course.courseNo)
        let ignoresAssignments = showsAssignmentBadges && viewModel.editor.ignoresAssignments(of: course.courseNo)
        let totalHeight = metrics.height(spanning: spanCount)
        let roomHint = app.preferences.showClassroomInClassTable
            ? CourseRoomHint.room(for: course, weekday: weekday, periodId: periodId)
            : nil
        let bottomLine = BlockLine(meeting: meeting, roomHint: roomHint, showsRooms: app.preferences.showClassroomInClassTable)
        let changedTime = meeting.flatMap(MeetingText.changedTime)
        let markColor = policy.classTableCourseSecondaryTextColor.opacity(0.5)

        Color.clear
            .overlay(alignment: .top) {
                courseFace(
                    course, spanCount: spanCount,
                    showsRoomHint: bottomLine != nil, showsMark: hasBadge || ignoresAssignments,
                    isCancelled: meeting?.isCancelled == true, showsTimeLine: changedTime != nil
                )
                    .overlay(alignment: .bottomLeading) {
                        if let bottomLine {
                            blockLine(bottomLine)
                                .padding(.leading, 3)
                                .padding(.bottom, 2)
                                .padding(.trailing, hasBadge || ignoresAssignments ? metrics.badgeIconSize + 6 : 3)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let changedTime {
                            changeLabel(changedTime, systemImage: "clock.fill")
                                .monospacedDigit()
                                .padding(.leading, 3)
                                .padding(.top, 3)
                                .padding(.trailing, 3)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if meeting?.notes.isEmpty == false {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: metrics.badgeIconSize + 2))
                                .foregroundStyle(Color.changeInk)
                                .padding(4)
                                .accessibilityHidden(true)
                        }
                    }
                    .assignmentBadge(show: hasBadge, iconSize: metrics.badgeIconSize, padding: 4, color: markColor)
                    .ignoredAssignmentsBadge(
                        show: ignoresAssignments, iconSize: metrics.badgeIconSize, padding: 4, color: markColor
                    )
                    .frame(height: totalHeight)
                    .scrollSafeTapAction {
                        viewModel.selectCourse(course, weekday: weekday, periodId: periodId)
                    }
                    .accessibilityLabel(
                        Text(String(
                            format: String(localized: "a11y_timetable_cell"),
                            AppConstants.Periods.shortWeekdayLabel(weekday),
                            viewModel.grid.activePeriods.first { $0.id == periodId }?.displayLabel ?? periodId,
                            spokenCourse(
                                course, room: bottomLine?.room ?? roomHint, changes: MeetingText.spoken(meeting),
                                hasAssignment: hasBadge, ignoresAssignments: ignoresAssignments
                            )
                        ))
                    )
                    .courseEditMenu(isEditable: viewModel.shownPerson == nil) {
                        TimetableCourseMenu(course: course, editor: viewModel.editor)
                    }
            }
    }

    private enum MeetingText {
        static func changedTime(_ meeting: CourseTimeSlot) -> String? {
            guard !meeting.isCancelled else { return nil }
            switch (meeting.originalStart != nil, meeting.originalEnd != nil) {
            case (true, true): return "\(meeting.start.timeString)–\(meeting.end.timeString)"
            case (true, false): return meeting.start.timeString
            case (false, true): return "–\(meeting.end.timeString)"
            case (false, false): return nil
            }
        }

        static func spoken(_ meeting: CourseTimeSlot?) -> [String] {
            guard let meeting else { return [] }
            let state = meeting.isCancelled
                ? [String(localized: "course_card_cancelled")]
                : meeting.hasChangedTime ? ["\(meeting.start.timeString) - \(meeting.end.timeString)"] : []
            return state + meeting.notes.compactMap { $0.note() }
        }
    }

    private enum BlockLine {
        case room(String), changedRoom(String), cancelled

        init?(meeting: CourseTimeSlot?, roomHint: String?, showsRooms: Bool) {
            if meeting?.isCancelled == true {
                self = .cancelled
            } else if let meeting, meeting.hasChangedRoom, showsRooms {
                self = .changedRoom(meeting.room)
            } else if let roomHint {
                self = .room(roomHint)
            } else {
                return nil
            }
        }

        var room: String? {
            if case .changedRoom(let room) = self { return room }
            return nil
        }
    }

    @ViewBuilder
    private func blockLine(_ line: BlockLine) -> some View {
        switch line {
        case .room(let room):
            Text(room)
                .timetableBlockRoom(metrics: metrics, policy: policy)
        case .changedRoom(let room):
            changeLabel(room, systemImage: "arrow.left.arrow.right")
        case .cancelled:
            Text(String(localized: "course_card_cancelled"))
                .font(.system(size: metrics.roomHintSize, weight: .semibold))
                .foregroundStyle(policy.classTableCourseSecondaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func changeLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.roomHintSize * 0.8, weight: .bold))
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .font(.system(size: metrics.roomHintSize, weight: .semibold))
        .foregroundStyle(Color.changeInk)
    }

    @ViewBuilder
    private func courseFace(
        _ course: CourseStore.Course, spanCount: Int, showsRoomHint: Bool, showsMark: Bool,
        isCancelled: Bool = false, showsTimeLine: Bool = false
    ) -> some View {
        if drawsPeriodTiles {
            VStack(spacing: metrics.rowSpacing) {
                ForEach(0..<spanCount, id: \.self) { index in
                    courseTile(
                        course,
                        cornerRadius: TigerDuckTheme.CornerRadius.xs,
                        lineLimit: 3,
                        leavesBottomLine: (showsRoomHint || showsMark) && index == spanCount - 1,
                        leavesTopLine: showsTimeLine && index == 0,
                        isCancelled: isCancelled
                    )
                    .frame(height: metrics.cellHeight)
                }
            }
        } else {
            courseTile(
                course,
                cornerRadius: TigerDuckTheme.CornerRadius.sm,
                lineLimit: spanCount > 1 ? 3 : 2,
                leavesBottomLine: showsRoomHint,
                leavesTopLine: showsTimeLine,
                isCancelled: isCancelled
            )
        }
    }

    private func courseTile(
        _ course: CourseStore.Course, cornerRadius: CGFloat, lineLimit: Int, leavesBottomLine: Bool,
        leavesTopLine: Bool = false, isCancelled: Bool = false
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(policy.classTableCourseFill(course.color).opacity(isCancelled ? 0.4 : 1))
            .overlay {
                if outlineRequiredCourses, course.isRequired {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(policy.classTableCourseOutline(course.color), lineWidth: 1)
                }
            }
            .overlay {
                Text(course.displayName)
                    .timetableBlockName(metrics: metrics, policy: policy, lineLimit: lineLimit, isCancelled: isCancelled)
                    .padding(.bottom, leavesBottomLine ? metrics.roomHintSize + 2 : 0)
                    .padding(.top, leavesTopLine ? metrics.roomHintSize + 2 : 0)
            }
    }
}
