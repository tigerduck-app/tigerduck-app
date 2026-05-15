import SwiftUI

struct CourseDetailSheet: View {
    let course: SDCourse
    let assignments: [SDAssignment]
    var timeRange: String? = nil
    var weekday: Int? = nil

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
                        InfoRow(label: String(localized: "course_detail_instructor_label"), value: course.instructor)
                        InfoRow(label: String(localized: "course_detail_code_label"), value: course.courseNo)
                        InfoRow(label: String(localized: "course_detail_credits_label"), value: "\(course.credits)")
                        InfoRow(label: String(localized: "course_detail_classroom_label"), value: weekday.map { course.classroom(for: $0) } ?? SDCourse.dedup(course.classroom))
                        if let timeRange {
                            InfoRow(label: String(localized: "course_detail_time_label"), value: timeRange)
                        }
                        InfoRow(label: String(localized: "course_detail_enrollment_label"), value: "\(course.enrolledCount) / \(course.maxCount)")
                    }
                    .padding(.horizontal)

                    // Assignments
                    if !assignments.isEmpty {
                        Divider().background(Color.textSecondary)
                            .padding(.horizontal)

                        Text(String(localized: "course_detail_incomplete_assignments"))
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
                                        Text(String(format: String(localized: "course_detail_due_prefix"), assignment.dueDate.shortDateString))
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
            .navigationTitle(course.displayName)
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

