import SwiftUI

nonisolated extension MoodleMember {
    var name: String { MoodlePersonName.displayName(fullName) }
    var studentId: String? { idNumber ?? MoodlePersonName.studentId(fullName) }
}

extension MoodlePage {
    static func participants(courseId: Int) -> MoodlePage { MoodlePage(path: "/user/index.php?id=\(courseId)") }
    static func profile(userId: Int, courseId: Int) -> MoodlePage {
        MoodlePage(path: "/user/view.php?id=\(userId)&course=\(courseId)")
    }
}

nonisolated struct MoodleMemberSection: Identifiable, Equatable {
    /// In the order the sections come. A role the app does not know goes after the assistants,
    /// under Moodle's name for it, ordered by Moodle's own sort order.
    enum Placement: Hashable, Comparable {
        case instructors
        case assistants
        case other(sortOrder: Int, name: String)
        case auditors
        case students

        init(_ role: MoodleMember.Role) {
            switch role.shortName {
            case "editingteacher": self = .instructors
            case "teacher": self = .assistants
            case "auditor_student": self = .auditors
            case "student": self = .students
            default: self = .other(sortOrder: role.sortOrder, name: role.name.isEmpty ? role.shortName : role.name)
            }
        }

        /// A person with several roles shows once, in the first section of them. One with none is
        /// listed with the students, as Moodle counts every enrolled person a participant.
        init(_ member: MoodleMember) {
            self = member.roles.map(Placement.init).min() ?? .students
        }

        var title: String {
            switch self {
            case .instructors: String(localized: "course_detail_instructor_label")
            case .assistants: String(localized: "course_members_tas")
            case .other(_, let name): name
            case .auditors: String(localized: "course_members_auditors")
            case .students: String(localized: "course_members_students")
            }
        }

        /// Staff by name; auditors and students by student ID, as a class list runs.
        fileprivate var listsByStudentId: Bool {
            self == .auditors || self == .students
        }
    }

    let placement: Placement
    let members: [MoodleMember]

    var id: Placement { placement }

    /// The search runs here, never on Moodle, over what a row shows.
    static func sections(of members: [MoodleMember], matching query: String = "") -> [MoodleMemberSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = needle.isEmpty ? members : members.filter { $0.matches(needle) }
        return Dictionary(grouping: shown, by: Placement.init)
            .sorted { $0.key < $1.key }
            .map { placement, people in
                MoodleMemberSection(placement: placement, members: people.sorted(by: placement.listsByStudentId ? byStudentId : byName))
            }
    }

    private static func byName(_ lhs: MoodleMember, _ rhs: MoodleMember) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    /// A person without a student ID comes after those with one.
    private static func byStudentId(_ lhs: MoodleMember, _ rhs: MoodleMember) -> Bool {
        switch (lhs.studentId, rhs.studentId) {
        case let (left?, right?) where left != right: left.localizedStandardCompare(right) == .orderedAscending
        case (.some, .none): true
        case (.none, .some): false
        default: byName(lhs, rhs)
        }
    }
}

private nonisolated extension MoodleMember {
    func matches(_ needle: String) -> Bool {
        [name, studentId, department].contains { $0?.localizedStandardContains(needle) == true }
    }
}

/// The people of a course the account can see, in sections by role. The search, hidden until the
/// list is pulled down, matches here and asks Moodle nothing.
struct MoodleMembersView: View {
    let store: MoodleCourseStore
    let policy: VisualStylePolicy
    let open: (MoodleCourseRoute) -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    #if os(iOS)
    @State private var isSearchRevealed = false
    #endif

    /// What the list shows. A copy fetched before stays up through a failed refresh, and a list
    /// that empties shows nothing rather than an empty state.
    enum Content {
        /// Nothing fetched yet: the first fetch's spinner, or its error and a retry.
        case firstLoad(failure: (any Error)?)
        case sections([MoodleMemberSection])
        case noMatches(query: String)

        init(list: MoodleMemberList?, isRefreshing: Bool, failure: (any Error)?, query: String) {
            guard let list else {
                self = .firstLoad(failure: isRefreshing ? nil : failure)
                return
            }
            let sections = MoodleMemberSection.sections(of: list.members, matching: query)
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            self = sections.isEmpty && !needle.isEmpty ? .noMatches(query: needle) : .sections(sections)
        }

        /// Whether a list has been fetched, so the search has something to match.
        var hasList: Bool {
            if case .firstLoad = self { false } else { true }
        }
    }

    var body: some View {
        let content = Content(
            list: store.members.value, isRefreshing: store.members.isRefreshing,
            failure: store.members.failure, query: query
        )
        List {
            // Above the switch, so a query that moves the list between its cases keeps the field,
            // and the keyboard with it.
            if content.hasList { searchRow }
            switch content {
            case .firstLoad(let failure):
                MoodleFirstLoadView(failure: failure, retry: { await store.refreshMembers() })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            case .sections(let sections):
                ForEach(sections) { section in
                    MoodleMemberSectionView(store: store, section: section, policy: policy) { member in
                        open(.member(member))
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowInsets)
                }
            case .noMatches(let needle):
                ContentUnavailableView.search(text: needle)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        #if os(iOS)
        .pullToRevealSearch(isRevealed: $isSearchRevealed, isActive: isSearchFocused || !query.isEmpty)
        #endif
        .refreshable { await store.refreshMembers() }
        .moodleRefreshFailureNote(store.members)
        .moodleListChrome(
            title: String(localized: "course_detail_members_label"),
            page: .participants(courseId: store.courseId),
            refresh: { await store.refreshMembers() }
        )
        .moodleAutoRefresh(every: store.members.ttl, fetchedAt: { store.membersFetchedAt }) {
            await store.refreshMembers()
        }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(
            top: TigerDuckTheme.Spacing.xs,
            leading: TigerDuckTheme.Spacing.lg,
            bottom: TigerDuckTheme.Spacing.xs,
            trailing: TigerDuckTheme.Spacing.lg
        )
    }

    /// Hidden until the list is pulled down on iOS. The Mac has no pull, so the field stays.
    @ViewBuilder
    private var searchRow: some View {
        #if os(iOS)
        let isShown = isSearchRevealed || !query.isEmpty
        #else
        let isShown = true
        #endif
        if isShown {
            searchField
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(rowInsets)
        }
    }

    private var searchField: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)
            TextField(String(localized: "action_search"), text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.search)
                .focused($isSearchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "action_clear_text"))
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.md)
        .padding(.vertical, TigerDuckTheme.Spacing.sm)
        .background(Capsule().fill(.fill.tertiary))
    }
}

private struct MoodleMemberSectionView: View {
    let store: MoodleCourseStore
    let section: MoodleMemberSection
    let policy: VisualStylePolicy
    let open: (MoodleMember) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack {
                Text(section.placement.title)
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text(section.members.count, format: .number)
                    .font(.footnote)
                    .monospacedDigit()
            }
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, TigerDuckTheme.Spacing.xs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(section.placement.title)
            .accessibilityValue(section.members.count.formatted())
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(section.members.enumerated()), id: \.element.id) { index, member in
                    if index > 0 {
                        Divider().padding(.leading, MoodleMemberRow.textInset)
                    }
                    Button { open(member) } label: {
                        MoodleMemberRow(member: member, picture: member.pictureURL.flatMap { store.pictures[$0] })
                    }
                    .buttonStyle(.plain)
                    .task(id: member.pictureURL) { await store.loadPicture(of: member) }
                }
            }
            .presetCard(policy: policy)
        }
        .padding(.top, TigerDuckTheme.Spacing.sm)
    }
}

/// A person in the members list: picture, name, and student ID and department, the ID whole and
/// the department cut short when the line runs out.
struct MoodleMemberRow: View {
    let member: MoodleMember
    let picture: CGImage?

    /// The line between rows starts under the text, not under the picture.
    static let textInset: CGFloat = TigerDuckTheme.Spacing.lg + avatarSize + TigerDuckTheme.Spacing.md
    private static let avatarSize: CGFloat = 36

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            MoodleAvatar(name: member.name, size: Self.avatarSize, picture: picture)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if member.studentId != nil || member.department != nil {
                    subline
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.textSecondary.opacity(0.5))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.vertical, TigerDuckTheme.Spacing.sm)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(member.name)
        .accessibilityValue([member.studentId, member.department].compactMap(\.self).joined(separator: ", "))
    }

    private var subline: some View {
        HStack(spacing: 0) {
            if let studentId = member.studentId {
                Text(studentId)
                    .monospacedDigit()
                    .fixedSize()
                    .layoutPriority(1)
            }
            if let department = member.department {
                Text(member.studentId == nil ? department : " · \(department)")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(TigerDuckTheme.Typography.caption)
        .foregroundStyle(Color.textSecondary)
    }
}
