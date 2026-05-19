import SwiftUI

struct CourseDetailView: View {
    let course: WatchCourse

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color(hex: course.colorHex) ?? .accentColor)
                        .frame(width: 4)
                    Text(course.name)
                        .font(.headline)
                }
                LabeledRow(symbol: "clock", text: "\(course.startHHmm)–\(course.endHHmm)")
                if !course.classroom.isEmpty {
                    LabeledRow(symbol: "mappin.and.ellipse", text: course.classroom)
                }
                if !course.teacher.isEmpty {
                    LabeledRow(symbol: "person", text: course.teacher)
                }
                LabeledRow(symbol: "number", text: course.periodLabel)
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle(course.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LabeledRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
    }
}
