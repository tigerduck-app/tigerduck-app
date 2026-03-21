import SwiftUI

struct CourseDetailSheet: View {
    let course: SDCourse
    let assignments: [SDAssignment]
    var timeRange: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                    // Course color bar
                    RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                        .fill(course.color)
                        .frame(height: 6)
                        .padding(.horizontal)

                    // Course info
                    VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
                        InfoRow(label: "授課教師", value: course.instructor)
                        InfoRow(label: "學分數", value: "\(course.credits)")
                        InfoRow(label: "教室", value: course.classroom)
                        if let timeRange {
                            InfoRow(label: "時間", value: timeRange)
                        }
                        InfoRow(label: "選課人數", value: "\(course.enrolledCount) / \(course.maxCount)")
                    }
                    .padding(.horizontal)

                    // Assignments
                    if !assignments.isEmpty {
                        Divider().background(Color.textSecondary)
                            .padding(.horizontal)

                        Text("未完成作業")
                            .font(TigerDuckTheme.Typography.headline)
                            .foregroundStyle(Color.textPrimary)
                            .padding(.horizontal)

                        ForEach(Array(assignments.enumerated()), id: \.element.assignmentId) { _, assignment in
                            Button {
                                if let url = assignment.moodleDeepLink {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(Color.accentPrimary)
                                    VStack(alignment: .leading) {
                                        Text(assignment.title)
                                            .font(TigerDuckTheme.Typography.body)
                                            .foregroundStyle(Color.textPrimary)
                                        Text("截止：\(assignment.dueDate.shortDateString)")
                                            .font(TigerDuckTheme.Typography.caption)
                                            .foregroundStyle(assignment.isOverdue ? Color.badgeRed : Color.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                        .foregroundStyle(Color.textSecondary)
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .cardPadding()
                            .glassCard()
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle(course.courseName)
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
        }
    }
}

