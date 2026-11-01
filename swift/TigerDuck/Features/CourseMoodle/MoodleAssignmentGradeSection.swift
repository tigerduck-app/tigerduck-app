#if os(iOS)
import SwiftUI

struct MoodleAssignmentGradeSection: View {
    let grade: MoodleAssignmentGrade
    let policy: VisualStylePolicy
    let accent: Color
    let files: MoodleFileOpener

    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            MoodleAssignmentSectionTitle(title: String(localized: "assignment_detail_grade"))
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
                if let shown = grade.grade {
                    scoreRow(MoodleAssignmentDetails.score(of: shown))
                }
                if let gradedAt = grade.gradedAt {
                    MoodleAssignmentTimeRow(label: String(localized: "assignment_detail_graded_at"), time: MoodleAssignmentDetails.timeText(gradedAt))
                }
                if let feedback = grade.feedback {
                    if grade.grade != nil || grade.gradedAt != nil { Divider() }
                    VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                        Text(String(localized: "assignment_detail_feedback"))
                            .font(.footnote)
                            .foregroundStyle(Color.textSecondary)
                        MoodleAssignmentMarkdown(text: MoodleAssignmentDetails.markdown(ofHTML: feedback), accent: accent, files: files)
                    }
                }
            }
            .padding(TigerDuckTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .presetCard(policy: policy)
        }
    }

    private func scoreRow(_ score: MoodleAssignmentDetails.Score) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
            Text(score.value)
                .font(.system(size: scoreSize, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(accent)
            if let max = score.max {
                Text(verbatim: "/ \(max)")
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.spoken)
    }
}
#endif
