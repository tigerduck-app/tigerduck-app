import SwiftUI

/// Modal detail for a single course row. The header mirrors the row layout
/// (name + code + grade chip) so context is preserved across the transition,
/// then surfaces the long-tail metadata that doesn't fit in the list view —
/// remarks, GE dimension, delivery mode, and raw credit type.
struct ScoreCourseDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let course: CourseGrade

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                    headerCard
                    metaSection
                    if !course.remark.isEmpty {
                        remarkSection
                    }
                }
                .padding(TigerDuckTheme.Spacing.lg)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle(course.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var headerCard: some View {
        HStack(alignment: .center, spacing: TigerDuckTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.name)
                    .font(TigerDuckTheme.Typography.title)
                    .foregroundStyle(Color.textPrimary)
                Text(course.code)
                    .font(TigerDuckTheme.Typography.caption.monospaced())
                    .foregroundStyle(Color.textSecondary)
                Text("\(displayTerm) · \(course.credits ?? 0) 學分")
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            Text(course.grade.isEmpty ? "—" : course.grade)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Color.textPrimary)
        }
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: appState.visualStylePolicy)
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            SectionHeader(title: "課程資訊")
            VStack(spacing: 0) {
                metaRow(label: "狀態", value: statusLabel)
                Divider().background(Color.white.opacity(0.05))
                metaRow(label: "學分類型", value: creditTypeLabel)
                if let dim = course.geDimension {
                    Divider().background(Color.white.opacity(0.05))
                    metaRow(label: "通識向度", value: dim)
                }
                Divider().background(Color.white.opacity(0.05))
                metaRow(label: "授課方式", value: course.distanceLearning ? "遠距" : "實體")
            }
            .presetCard(policy: appState.visualStylePolicy)
        }
    }

    private var remarkSection: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            SectionHeader(title: "備註")
            Text(course.remark)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TigerDuckTheme.Spacing.md)
                .presetCard(policy: appState.visualStylePolicy)
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.md)
        .padding(.vertical, TigerDuckTheme.Spacing.sm)
    }

    private var displayTerm: String {
        guard course.term.count == 4 else { return course.term }
        let year = String(course.term.prefix(3))
        let sem = String(course.term.suffix(1))
        let label = sem == "1" ? "上學期" : sem == "2" ? "下學期" : sem
        return "\(year) \(label)"
    }

    private var statusLabel: String {
        switch course.status {
        case .graded:   return "已評定"
        case .pending:  return "成績未到"
        case .passed:   return course.grade.isEmpty ? "通過 / 不通過" : course.grade
        case .withdrew: return "二次退選"
        case .exempted: return "抵免"
        case .unknown:  return "未知"
        }
    }

    private var creditTypeLabel: String {
        switch course.creditType {
        case .normal:           return "一般"
        case .educationProgram: return "教育學程 [n]"
        case .notCounted:       return "不計入 <n>"
        case .notRequired:      return "非必修 #n"
        case .notEarned:        return "未取得（不及格）(n)"
        case .unknown:          return "未知"
        }
    }
}
