import SwiftUI

/// The course detail's Moodle section, under its incomplete assignments: a header with the
/// status dot, then one card with a row for each kind of data the course has on Moodle. A row
/// shows only once its data has something in it, and the section only once it has a row. The
/// rows bring the gap above them and the course detail adds no spacing of its own, so with none
/// the section adds nothing to the sheet.
struct MoodleCourseSection: View {
    let store: MoodleCourseStore
    let policy: VisualStylePolicy

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = store.sectionRows
        // The rows come and go inside this stack, whose animation fades in the rows a fetch brings.
        // On the course detail's stack, the key would change as the store arrives and animate the
        // sheet's first layout, sliding the content in from a corner.
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
            if !rows.isEmpty {
                Divider().background(Color.textSecondary)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.top, TigerDuckTheme.Spacing.lg)
                header
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
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
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: rows)
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

    /// A course with one forum besides its announcements opens that forum's discussions at once.
    static func route(for kind: MoodleSectionRow.Kind, in store: MoodleCourseStore) -> MoodleCourseRoute {
        switch kind {
        case .announcements:
            return .announcements
        case .materials:
            return .materials
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
    /// Keeps the section's data fresh while the course detail shows, rows or none: the first
    /// fetch is what brings the rows.
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
                    .id(ObjectIdentifier(store))
            }
        }
    }
}

/// One row of the Moodle section: the kind's icon and name, its unread dot and its count.
struct MoodleSectionRowView: View {
    let row: MoodleSectionRow

    var body: some View {
        MoodleCountRow(icon: icon, title: title, count: row.count, hasUnread: row.hasUnread)
    }

    private var icon: String {
        switch row.kind {
        case .announcements: "megaphone"
        case .materials: "folder"
        case .members: "person.2"
        case .forums: "bubble.left.and.bubble.right"
        }
    }

    private var title: String {
        switch row.kind {
        case .announcements: String(localized: "feature_announcements")
        case .materials: String(localized: "course_detail_files_label")
        case .members: String(localized: "course_detail_members_label")
        case .forums: String(localized: "course_detail_forums_label")
        }
    }
}

/// A row that opens a Moodle list: an icon, a name with an optional line under it, then an unread
/// dot, a count and a chevron, which stay on the right however the name wraps.
struct MoodleCountRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let count: Int
    let hasUnread: Bool

    /// The line between rows starts under the text, not under the icon.
    static let textInset: CGFloat = TigerDuckTheme.Spacing.lg + iconWidth + TigerDuckTheme.Spacing.md
    private static let iconWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: icon)
                .font(TigerDuckTheme.Typography.body)
                // The widest icon, the forums' two bubbles, fills the column at this size and
                // would run into the name past it.
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
