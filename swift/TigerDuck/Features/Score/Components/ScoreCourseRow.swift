import SwiftUI

struct ScoreCourseRow: View {
    @Environment(AppState.self) private var appState

    let course: CourseGrade
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: TigerDuckTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: TigerDuckTheme.Spacing.xs) {
                        Text(course.name)
                            .font(TigerDuckTheme.Typography.body.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if course.distanceLearning {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.caption2)
                                .foregroundStyle(ScoreColor.skyBlue)
                        }
                    }

                    HStack(spacing: TigerDuckTheme.Spacing.xs) {
                        Text(course.code)
                            .font(TigerDuckTheme.Typography.caption.monospaced())
                            .foregroundStyle(Color.textSecondary)
                        Text("·")
                            .foregroundStyle(Color.textSecondary)
                        if let credits = course.credits {
                            Text(String(format: String(localized: "score_course_credits"), credits.creditsText))
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        } else {
                            Text("—")
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        CreditTypeBadge(creditType: course.creditType)
                        if let dim = course.geDimension {
                            Text(dim)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.textPrimary.opacity(0.08), in: Capsule())
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                }
                Spacer()
                GradeChip(course: course)
            }
            .padding(.vertical, TigerDuckTheme.Spacing.sm)
            .padding(.horizontal, TigerDuckTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct GradeChip: View {
    let course: CourseGrade

    var body: some View {
        let descriptor = resolveDescriptor()
        HStack(spacing: 4) {
            if let icon = descriptor.icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(descriptor.label)
                .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(descriptor.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(descriptor.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .frame(minWidth: 64)
    }

    private func resolveDescriptor() -> (label: String, color: Color, icon: String?) {
        switch course.status {
        case .pending:
            return (String(localized: "score_grade_pending"), ScoreColor.grey, "hourglass")
        case .withdrew:
            return (String(localized: "score_grade_withdrew"), ScoreColor.grey, "xmark.circle")
        case .exempted:
            return (String(localized: "score_grade_exempted"), ScoreColor.skyBlue, "checkmark.seal")
        case .passed:
            let passed = course.isPassStatusPassed
            return (
                passed
                    ? String(localized: "score_grade_passed")
                    : String(localized: "score_grade_failed"),
                passed ? ScoreColor.teal : ScoreColor.red,
                passed ? "checkmark" : "xmark"
            )
        case .graded:
            return (course.grade, ScoreColor.grade(course.grade), nil)
        case .unknown:
            return (course.grade.isEmpty ? "—" : course.grade, Color.textSecondary, nil)
        }
    }
}
