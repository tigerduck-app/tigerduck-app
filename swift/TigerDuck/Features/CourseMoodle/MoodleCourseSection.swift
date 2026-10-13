import SwiftUI

/// The course detail's Moodle section, under its incomplete assignments: a header with the
/// status dot, then one card with a row for each kind of data the course has on Moodle. A row
/// shows only once its data has something in it, and the section only once it has a row; with
/// none it adds nothing to the sheet, not even spacing.
struct MoodleCourseSection: View {
    let store: MoodleCourseStore
    let policy: VisualStylePolicy

    var body: some View {
        let rows = store.sectionRows
        if !rows.isEmpty {
            Divider().background(Color.textSecondary)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            header
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
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
        case .members: .members
        }
    }
}

extension View {
    /// Keeps the section's data fresh while the course detail shows, rows or none: the first
    /// fetch is what brings the rows.
    func moodleSectionRefresh(_ store: MoodleCourseStore?) -> some View {
        background {
            if let store {
                Color.clear
                    .moodleAutoRefresh(every: store.forums.ttl, fetchedAt: { store.forumsFetchedAt }) {
                        await store.refreshForums()
                    }
                    .moodleAutoRefresh(every: store.members.ttl, fetchedAt: { store.membersFetchedAt }) {
                        await store.refreshMembers()
                    }
                    .id(ObjectIdentifier(store))
            }
        }
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
        case .members: "person.2"
        }
    }

    private var title: String {
        switch row.kind {
        case .announcements: String(localized: "feature_announcements")
        case .members: String(localized: "course_detail_members_label")
        }
    }

    private var accessibilityValue: String {
        let count = row.count.formatted()
        return row.hasUnread ? "\(count), \(String(localized: "bulletin_unread_dot_label"))" : count
    }
}
