import MarkdownUI
import SwiftUI

/// The course detail's Moodle section, under its incomplete assignments: a header with the
/// status dot, one card with a row for each kind of data the course has on Moodle, then the
/// course's summary. A row shows only once its data has something in it, and the section only
/// once it has a row or a summary. The section brings the gap above it and the course detail
/// adds no spacing of its own, so with neither the section adds nothing to the sheet.
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
                            Divider().padding(.leading, MoodleSectionRowView.textInset)
                        }
                        NavigationLink(value: Self.route(for: row.kind)) {
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
        HStack {
            Text(String(localized: "calendar_source_moodle"))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            MoodleStatusDot(status: store.sectionStatus, isLoading: store.isSectionRefreshing)
        }
    }

    static func route(for kind: MoodleSectionRow.Kind) -> MoodleCourseRoute {
        switch kind {
        case .announcements: .announcements
        case .materials: .materials
        case .members: .members
        }
    }
}

extension View {
    /// Keeps the section's data fresh while the course detail shows, rows or none: the first
    /// fetch is what brings the rows and the summary.
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

/// A course's summary on Moodle, at the foot of its section: four lines of plain text that open
/// in place to the whole summary, drawn as an announcement's message is. The open summary keeps
/// its links working, so the chevron under it, not the text, closes it again.
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

/// One row of the Moodle section: the kind's icon and name, then its unread dot, its count and
/// a chevron, which stay on the right however the name wraps.
struct MoodleSectionRowView: View {
    let row: MoodleSectionRow

    /// The line between rows starts under the text, not under the icon.
    static let textInset: CGFloat = TigerDuckTheme.Spacing.lg + iconWidth + TigerDuckTheme.Spacing.md
    private static let iconWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: icon)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(.tint)
                .frame(width: Self.iconWidth)
            Text(title)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                if row.hasUnread {
                    Circle()
                        .fill(.tint)
                        .frame(width: 7, height: 7)
                }
                Text(row.count, format: .number)
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
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var icon: String {
        switch row.kind {
        case .announcements: "megaphone"
        case .materials: "folder"
        case .members: "person.2"
        }
    }

    private var title: String {
        switch row.kind {
        case .announcements: String(localized: "feature_announcements")
        case .materials: String(localized: "course_detail_files_label")
        case .members: String(localized: "course_detail_members_label")
        }
    }

    private var accessibilityValue: String {
        let count = row.count.formatted()
        return row.hasUnread ? "\(count), \(String(localized: "bulletin_unread_dot_label"))" : count
    }
}
