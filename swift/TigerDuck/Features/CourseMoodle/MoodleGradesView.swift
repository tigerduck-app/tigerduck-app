import MarkdownUI
import SwiftUI

/// A course's grades on Moodle for the signed-in student: the course total, then each graded
/// item in the gradebook's order. An item with feedback opens in place to show it, and a long
/// press opens the item's activity in Moodle.
struct MoodleGradesView: View {
    let store: MoodleCourseStore

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var expanded: Set<Int> = []

    var body: some View {
        List {
            if let grades = store.grades.value {
                let total = grades.total
                let items = grades.graded
                if total != nil || !items.isEmpty {
                    VStack(spacing: TigerDuckTheme.Spacing.lg) {
                        if let total {
                            MoodleGradeTotalCard(total: total, policy: appState.visualStylePolicy)
                        }
                        if !items.isEmpty {
                            itemsCard(items)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: TigerDuckTheme.Spacing.xs,
                        leading: TigerDuckTheme.Spacing.lg,
                        bottom: TigerDuckTheme.Spacing.lg,
                        trailing: TigerDuckTheme.Spacing.lg
                    ))
                }
            } else {
                MoodleFirstLoadView(
                    failure: store.grades.isRefreshing ? nil : store.grades.failure,
                    retry: { await store.refreshGrades() }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .refreshable { await store.refreshGrades() }
        .moodleTextLinks()
        .moodleListChrome(
            title: String(localized: "course_detail_moodle_grades_label"),
            status: store.grades.status,
            isLoading: store.grades.isRefreshing,
            page: .gradeReport(courseId: store.courseId),
            refresh: { await store.refreshGrades() }
        )
        .moodleAutoRefresh(every: store.grades.ttl, fetchedAt: { store.grades.fetchedAt }) {
            await store.refreshGrades()
        }
    }

    private func itemsCard(_ items: [MoodleGradeItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().padding(.leading, MoodleGradeRow.textInset)
                }
                row(item)
            }
        }
        .presetCard(policy: appState.visualStylePolicy)
    }

    /// An item no activity gives has no long-press menu, rather than an empty one.
    @ViewBuilder
    private func row(_ item: MoodleGradeItem) -> some View {
        let content = MoodleGradeRow(item: item, accent: appState.accentColor, isExpanded: isExpanded(item.id))
        if let page = item.activityPage {
            content.contextMenu {
                Button {
                    Task { await openURL(page) }
                } label: {
                    Label(String(localized: "action_open_in_moodle"), systemImage: "arrow.up.right.square")
                }
            }
        } else {
            content
        }
    }

    private func isExpanded(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOn in
                if isOn { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }
}

/// The course total, styled as the course detail's classroom and time cards.
struct MoodleGradeTotalCard: View {
    let total: MoodleGradeItem
    let policy: VisualStylePolicy

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Text(String(localized: "score_credit_total"))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
                Text(total.grade ?? "")
                    .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let max = total.maxText {
                    Text(verbatim: "/ \(max)")
                        .font(TigerDuckTheme.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .presetCard(policy: policy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "score_credit_total"))
        .accessibilityValue(total.spokenGrade)
    }
}

/// A graded item: its kind's icon, its name, and its grade over the most it could be, which
/// never truncate. An item with feedback is a button that shows the feedback under it; the
/// rest cannot be tapped. At accessibility sizes the grade moves under the name.
struct MoodleGradeRow: View {
    let item: MoodleGradeItem
    let accent: Color
    @Binding var isExpanded: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The line between rows and the feedback start under the name, not under the icon.
    static let textInset: CGFloat = TigerDuckTheme.Spacing.lg + iconWidth + TigerDuckTheme.Spacing.md
    private static let iconWidth: CGFloat = 28

    var body: some View {
        if item.feedback.isEmpty {
            summary
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityValue(item.spokenGrade)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { isExpanded.toggle() }
                } label: {
                    summary
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.name)
                .accessibilityValue(item.spokenGrade)
                if isExpanded {
                    feedback
                }
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.md) {
            // Past this size the wider symbols, such as the quiz's, run out of the icon's column.
            Image(systemName: item.symbol)
                .font(TigerDuckTheme.Typography.body)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.tint)
                .frame(width: Self.iconWidth)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                    name
                    HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
                        gradeText
                        maxText
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                name
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    gradeText
                    maxText
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var name: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Text(item.name)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !item.feedback.isEmpty {
                Image(systemName: "text.bubble")
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var gradeText: some View {
        Text(item.grade ?? "")
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color.textPrimary)
    }

    @ViewBuilder
    private var maxText: some View {
        if let max = item.maxText {
            Text(verbatim: "/ \(max)")
                .font(TigerDuckTheme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var feedback: some View {
        Markdown(item.feedback)
            .markdownTheme(.bulletin(accent: accent))
            .markdownTextStyle { FontSize(.em(0.88)) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Self.textInset)
            .padding(.trailing, TigerDuckTheme.Spacing.lg)
            .padding(.bottom, TigerDuckTheme.Spacing.md)
            .transition(.opacity)
    }
}

extension MoodleGradeItem {
    /// The icon of the item's kind: an assignment, a quiz, or any other grade.
    var symbol: String {
        switch module {
        case "assign": "doc.text"
        case "quiz": "checklist"
        default: "number"
        }
    }

    /// The most the grade could be, written only beside a grade that is a number: over a letter,
    /// a percentage or a scale's word, the maximum would misread. Its digits follow Moodle's,
    /// whatever the device's region.
    var maxText: String? {
        guard let maxGrade, let grade, grade.wholeMatch(of: /-?[0-9]+([.,][0-9]+)?/) != nil else { return nil }
        return maxGrade.formatted(
            .number.grouping(.never).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))
        )
    }

    /// The grade as VoiceOver reads it, with the most it could be.
    var spokenGrade: String {
        guard let grade else { return "" }
        return maxText.map { "\(grade) / \($0)" } ?? grade
    }

    /// The item's activity on Moodle; nil for an item no activity gives, such as one the teacher
    /// added by hand.
    var activityPage: MoodlePage? {
        guard let module, let cmid, module.wholeMatch(of: /[a-z0-9_]+/) != nil else { return nil }
        return .activity(module: module, cmid: cmid)
    }
}

extension MoodlePage {
    /// The course's grade report, which lists the items not graded yet too.
    static func gradeReport(courseId: Int) -> MoodlePage {
        MoodlePage(path: "/grade/report/user/index.php?id=\(courseId)")
    }

    static func activity(module: String, cmid: Int) -> MoodlePage {
        MoodlePage(path: "/mod/\(module)/view.php?id=\(cmid)")
    }
}
