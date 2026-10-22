import MarkdownUI
import SwiftUI

struct MoodleCourseSection: View {
    let store: MoodleCourseStore
    let policy: VisualStylePolicy

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = store.sectionRows
        let summary = store.shownSummary
        // What comes and goes inside this stack fades in as a fetch brings it. On the course
        // detail's stack, the keys would change as the store arrives and animate the sheet's first
        // layout, sliding the content in from a corner.
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
            if !rows.isEmpty || summary != nil {
                Divider().background(Color.textSecondary)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.top, TigerDuckTheme.Spacing.lg)
                header
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, MoodleCountRow.textInset)
                        }
                        NavigationLink(value: Self.route(for: row.kind, in: store)) {
                            MoodleSectionRowView(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .presetCard(policy: policy)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
            if let summary {
                MoodleCourseSummaryView(summary: summary)
                    .padding(.top, TigerDuckTheme.Spacing.sm)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: rows)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: summary)
    }

    private var header: some View {
        Text(String(localized: "calendar_source_moodle"))
            .font(TigerDuckTheme.Typography.headline)
            .foregroundStyle(Color.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    static func route(for kind: MoodleSectionRow.Kind, in store: MoodleCourseStore) -> MoodleCourseRoute {
        switch kind {
        case .announcements:
            return .announcements
        case .materials:
            return .materials
        case .assignments:
            return .assignments
        case .grades:
            return .grades
        case .members:
            return .members
        case .forums:
            let forums = store.generalForums
            if forums.count == 1, let only = forums.first { return .forum(only) }
            return .forums
        }
    }
}

extension View {
    func moodleSectionRefresh(_ store: MoodleCourseStore?) -> some View {
        background {
            if let store {
                Color.clear
                    .moodleAutoRefresh(every: store.forums.ttl, fetchedAt: { store.forumsFetchedAt }) {
                        await store.refreshForums()
                    }
                    .moodleAutoRefresh(every: store.materials.ttl, fetchedAt: { store.materialsFetchedAt }) {
                        await store.refreshMaterials()
                    }
                    .moodleAutoRefresh(every: store.grades.ttl, fetchedAt: { store.grades.fetchedAt }) {
                        await store.refreshGrades()
                    }
                    .moodleAutoRefresh(every: store.members.ttl, fetchedAt: { store.membersFetchedAt }) {
                        await store.refreshMembers()
                    }
                    .moodleAutoRefresh(every: store.summary.ttl, fetchedAt: { store.summary.fetchedAt }) {
                        await store.refreshSummary()
                    }
                    .id(ObjectIdentifier(store))
            }
        }
    }
}

struct MoodleCourseSummaryView: View {
    let summary: MoodleCourseSummary

    private static let previewLineLimit = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
            Text(String(localized: "course_detail_summary_label"))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if isExpanded {
                VStack(alignment: .trailing, spacing: 0) {
                    MoodleCourseSummaryBody(html: summary.html)
                    toggle(label: String(localized: "course_detail_summary_label")) {
                        chevron("chevron.up")
                            .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                    }
                }
            } else {
                toggle(label: summary.text) {
                    HStack(alignment: .lastTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
                        Text(summary.text)
                            .font(TigerDuckTheme.Typography.body)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(Self.previewLineLimit)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        chevron("chevron.down")
                    }
                }
            }
        }
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.textSecondary)
            .accessibilityHidden(true)
    }

    private func toggle(label: String, @ViewBuilder content: () -> some View) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { isExpanded.toggle() }
        } label: {
            content().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct MoodleCourseSummaryBody: View {
    let html: String

    @Environment(AppState.self) private var appState
    @Environment(\.openMoodleLink) private var openMoodleLink

    var body: some View {
        Markdown(BulletinBodyRenderer.normalize(MoodleHTMLText.markdown(fromHTML: html)))
            .markdownTheme(.bulletin(accent: appState.accentColor))
            .environment(\.openURL, OpenURLAction { url in
                openMoodleLink(url)
                return .handled
            })
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MoodleSectionRowView: View {
    let row: MoodleSectionRow

    var body: some View {
        MoodleCountRow(icon: icon, title: title, count: row.count, hasUnread: row.hasUnread)
    }

    private var icon: String {
        switch row.kind {
        case .announcements: "megaphone"
        case .materials: "folder"
        case .assignments: "doc.text"
        case .grades: "chart.bar"
        case .members: "person.2"
        case .forums: "bubble.left.and.bubble.right"
        }
    }

    private var title: String {
        switch row.kind {
        case .announcements: String(localized: "feature_announcements")
        case .materials: String(localized: "course_detail_files_label")
        case .assignments: String(localized: "course_detail_assignments_label")
        case .grades: String(localized: "course_detail_moodle_grades_label")
        case .members: String(localized: "course_detail_members_label")
        case .forums: String(localized: "course_detail_forums_label")
        }
    }
}

struct MoodleCountRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let count: Int
    let hasUnread: Bool

    static let textInset: CGFloat = TigerDuckTheme.Spacing.lg + iconWidth + TigerDuckTheme.Spacing.md
    private static let iconWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: icon)
                .font(TigerDuckTheme.Typography.body)
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .foregroundStyle(.tint)
                .frame(width: Self.iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                if hasUnread {
                    Circle()
                        .fill(.tint)
                        .frame(width: 7, height: 7)
                }
                Text(count, format: .number)
                    .font(TigerDuckTheme.Typography.body)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.textSecondary.opacity(0.5))
            }
            .fixedSize()
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].compactMap(\.self).joined(separator: ", "))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let count = count.formatted()
        return hasUnread ? "\(count), \(String(localized: "bulletin_unread_dot_label"))" : count
    }
}
