import SwiftUI
import TigerDuckCore

/// One weekday's club activities, over the rows of the class table.
struct TimetableClubColumn: View {
    let viewModel: ClassTableViewModel
    let weekday: Int
    let periods: [TimetablePeriod]
    let metrics: TimetableCellMetrics
    let drawsPeriodTiles: Bool
    let policy: VisualStylePolicy

    var body: some View {
        let blocks = ClassTableClubLayout.blocks(
            ClassTableClubLayout.segments(
                of: viewModel.grid.clubs[weekday] ?? [],
                courses: ClassTableClubLayout.courseTimes(viewModel.grid.courses, weekday: weekday)
            ),
            periods: periods.compactMap(\.minutes),
            rowPitch: metrics.cellHeight + metrics.rowSpacing,
            cellHeight: metrics.cellHeight
        )
        let drawn = blocks.map(\.segment.occurrence)
        ZStack(alignment: .top) {
            ForEach(blocks) { block in
                TimetableClubBlock(
                    viewModel: viewModel, block: block, drawn: drawn, metrics: metrics, drawsPeriodTiles: drawsPeriodTiles,
                    policy: policy
                )
                .frame(height: block.height)
                .offset(y: block.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A piece of a club activity: a course block's shape and fill in the club's color, with a bar of
/// that color down its leading edge.
struct TimetableClubBlock: View {
    let viewModel: ClassTableViewModel
    let block: ClassTableClubLayout.Block
    /// The activities the column draws, which a tap offers when they meet this one.
    let drawn: [ClubOccurrence]
    let metrics: TimetableCellMetrics
    let drawsPeriodTiles: Bool
    let policy: VisualStylePolicy

    static let barWidth: CGFloat = 3

    var body: some View {
        let club = block.segment.occurrence
        let color = Color(hex: UInt(club.color))
        let shape = RoundedRectangle(
            cornerRadius: drawsPeriodTiles ? TigerDuckTheme.CornerRadius.xs : TigerDuckTheme.CornerRadius.sm
        )
        shape
            .fill(policy.classTableCourseFill(color))
            .overlay(alignment: .leading) {
                color.frame(width: Self.barWidth)
            }
            .clipShape(shape)
            .overlay {
                if block.showsName {
                    Text(club.clubName)
                        .timetableBlockName(metrics: metrics, policy: policy, lineLimit: block.showsLocation ? 3 : 2)
                        .padding(.leading, Self.barWidth)
                        .padding(.bottom, block.showsLocation ? metrics.roomHintSize + 2 : 0)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if block.showsLocation {
                    Text(club.location)
                        .timetableBlockRoom(metrics: metrics, policy: policy)
                        .padding(.leading, Self.barWidth + 3)
                        .padding(.bottom, 2)
                        .padding(.trailing, 3)
                }
            }
            .contentShape(.contextMenuPreview, shape)
            .scrollSafeTapAction {
                viewModel.selectClubs(ClassTableClubLayout.overlapping(club, among: drawn))
            }
            .accessibilityLabel(Text(Self.spoken(club)))
            .contextMenu {
                Button {
                    viewModel.editor.dialogs.clubToRecolor = .init(id: club.clubID, name: club.clubName)
                } label: {
                    Label(String(localized: "class_table_club_color_picker_title"), systemImage: "paintpalette")
                }
            }
    }

    static func spoken(_ club: ClubOccurrence) -> String {
        [club.clubName, club.name, ClassTimeline.timeRange(from: club.start, to: club.end), club.location]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
