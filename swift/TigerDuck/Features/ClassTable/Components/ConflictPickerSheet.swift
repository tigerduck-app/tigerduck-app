import SwiftUI
import TigerDuckCore

/// The blocks that share a place on the class table, to pick the one to open.
struct ConflictPickerSheet: View {
    struct Row: Identifiable {
        let id: String
        let color: Color
        let title: String
        let details: [String]
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let rows: [Row]
    let onPick: (Row.ID) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)
                    if index < rows.count - 1 {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.backgroundPrimary)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        // At the accessibility sizes the lines wrap, since the time and place tell rows apart.
        let stacked = dynamicTypeSize.isAccessibilitySize
        return Button {
            onPick(row.id)
        } label: {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                ColorSquare(color: row.color, side: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(TigerDuckTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(stacked ? nil : 1)
                    Text(row.details.joined(separator: " · "))
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(stacked ? nil : 1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(([row.title] + row.details).joined(separator: ", ")))
    }
}

extension ConflictPickerSheet.Row {
    init(course: CourseStore.Course) {
        var parts = [course.courseNo]
        if !course.instructor.isEmpty { parts.append(course.instructor) }
        let classroom = CourseStore.Course.dedup(course.classroom)
        if !classroom.isEmpty { parts.append(classroom) }
        self.init(id: course.courseNo, color: course.color, title: course.displayName, details: parts)
    }

    init(club: ClubOccurrence) {
        self.init(id: String(club.id), color: Color(hex: UInt(club.color)), title: club.clubName, details: club.details)
    }
}

extension ClubOccurrence {
    /// The activity, its time and its place, which a picker row and VoiceOver read after the club.
    var details: [String] {
        [name, ClassTimeline.timeRange(from: start, to: end), location].filter { !$0.isEmpty }
    }
}

/// A rounded swatch of a course's or a club's color.
struct ColorSquare: View {
    let color: Color
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .frame(width: side, height: side)
    }
}
