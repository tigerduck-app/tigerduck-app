import SwiftUI
import TigerDuckCore

struct ConflictPickerSheet: View {
    struct Row: Identifiable {
        let id: String
        let color: Color
        let title: String
        let details: [String]
        var spokenDetails: [String]? = nil
    }

    @Environment(\.dismiss) private var dismiss

    let title: String
    let rows: [Row]
    let onPick: (Row.ID) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row)
                        if index < rows.count - 1 {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
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
        Button {
            onPick(row.id)
        } label: {
            CourseListRow(color: row.color, title: row.title, details: row.details)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(([row.title] + (row.spokenDetails ?? row.details)).joined(separator: ", ")))
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
        self.init(
            id: String(club.id), color: Color(hex: UInt(club.color)), title: club.clubName, details: club.details,
            spokenDetails: club.spokenDetails
        )
    }
}

extension ClubOccurrence {
    var details: [String] { details(time: TimeRange.text(from: start, to: end)) }

    var spokenDetails: [String] { details(time: TimeRange.spoken(from: start, to: end)) }

    private func details(time: String) -> [String] {
        [name, time, location].filter { !$0.isEmpty }
    }
}
