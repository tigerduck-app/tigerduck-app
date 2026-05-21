import SwiftUI

/// Single row for one graded course inside a semester disclosure group.
/// Tapping invokes `onTap` so the parent can present a detail sheet.
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
                                .foregroundStyle(Color(hex: 0x85C1E9))
                        }
                    }

                    HStack(spacing: TigerDuckTheme.Spacing.xs) {
                        Text(course.code)
                            .font(TigerDuckTheme.Typography.caption.monospaced())
                            .foregroundStyle(Color.textSecondary)
                        Text("·")
                            .foregroundStyle(Color.textSecondary)
                        if let credits = course.credits {
                            Text(String(format: String(localized: "score_course_credits"), credits))
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
                                .background(Color.white.opacity(0.08), in: Capsule())
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

/// Right-aligned grade pill — color and glyph both keyed off the combined
/// grade + status so "通過" and "D" both read at a glance.
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
            return (String(localized: "score_grade_pending"), Color(hex: 0x95A5A6), "hourglass")
        case .withdrew:
            return (String(localized: "score_grade_withdrew"), Color(hex: 0x95A5A6), "xmark.circle")
        case .exempted:
            return (String(localized: "score_grade_exempted"), Color(hex: 0x85C1E9), "checkmark.seal")
        case .passed:
            let passed = course.isPassStatusPassed
            return (
                passed
                    ? String(localized: "score_grade_passed")
                    : String(localized: "score_grade_failed"),
                passed ? Color(hex: 0x4ECDC4) : Color(hex: 0xE74C3C),
                passed ? "checkmark" : "xmark"
            )
        case .graded:
            return (course.grade, gradeColor(course.grade), nil)
        case .unknown:
            return (course.grade.isEmpty ? "—" : course.grade, Color.textSecondary, nil)
        }
    }

    private func gradeColor(_ grade: String) -> Color {
        let upper = grade.uppercased()
        if upper.hasPrefix("A") { return Color(hex: 0x2ECC71) }
        if upper.hasPrefix("B") { return Color(hex: 0x3498DB) }
        if upper.hasPrefix("C") { return Color(hex: 0xF7DC6F) }
        if upper.hasPrefix("D") || upper.hasPrefix("E") || upper.hasPrefix("F") {
            return Color(hex: 0xFF6B6B)
        }
        return Color.textPrimary
    }
}
