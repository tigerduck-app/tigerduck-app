import SwiftUI

nonisolated extension MoodleMember {
    var name: String { MoodlePersonName.displayName(fullName) }
    var studentId: String? { idNumber ?? MoodlePersonName.studentId(fullName) }
    var department: NTUSTDepartment? { NTUSTDepartment(studentId: studentId) }
}

nonisolated enum NTUSTDepartment: String {
    case im = "01", et = "02", me = "03", tx = "04", ct = "05", ch = "06"
    case ee = "07", ba = "08", dt = "10", ad = "13", cs = "15", hc = "30"

    init?(studentId: String?) {
        guard let match = studentId?.wholeMatch(of: /[Bb][0-9]{3}([0-9]{2})[0-9]{3}/) else { return nil }
        self.init(rawValue: String(match.1))
    }

    var name: String {
        switch self {
        case .im: String(localized: "course_member_department_im")
        case .et: String(localized: "course_member_department_et")
        case .me: String(localized: "course_member_department_me")
        case .tx: String(localized: "course_member_department_tx")
        case .ct: String(localized: "course_member_department_ct")
        case .ch: String(localized: "course_member_department_ch")
        case .ee: String(localized: "course_member_department_ee")
        case .ba: String(localized: "course_member_department_ba")
        case .dt: String(localized: "course_member_department_dt")
        case .ad: String(localized: "course_member_department_ad")
        case .cs: String(localized: "course_member_department_cs")
        case .hc: String(localized: "course_member_department_hc")
        }
    }

    var shortName: String {
        switch self {
        case .im: String(localized: "course_member_department_im_short")
        case .et: String(localized: "course_member_department_et_short")
        case .me: String(localized: "course_member_department_me_short")
        case .tx: String(localized: "course_member_department_tx_short")
        case .ct: String(localized: "course_member_department_ct_short")
        case .ch: String(localized: "course_member_department_ch_short")
        case .ee: String(localized: "course_member_department_ee_short")
        case .ba: String(localized: "course_member_department_ba_short")
        case .dt: String(localized: "course_member_department_dt_short")
        case .ad: String(localized: "course_member_department_ad_short")
        case .cs: String(localized: "course_member_department_cs_short")
        case .hc: String(localized: "course_member_department_hc_short")
        }
    }
}

extension MoodlePage {
    static func participants(courseId: Int) -> MoodlePage { MoodlePage(path: "/user/index.php?id=\(courseId)") }
    static func profile(userId: Int, courseId: Int) -> MoodlePage {
        MoodlePage(path: "/user/view.php?id=\(userId)&course=\(courseId)")
    }
}

nonisolated struct MoodleMemberSection: Identifiable, Equatable {
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

        fileprivate var listsByStudentId: Bool {
            self == .auditors || self == .students
        }
    }

    let placement: Placement
    let members: [MoodleMember]

    var id: Placement { placement }

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
        [name, studentId, department?.shortName].contains { $0?.localizedStandardContains(needle) == true }
    }
}

struct MoodleMembersView: View {
    let store: MoodleCourseStore
    let policy: VisualStylePolicy
    let open: (MoodleCourseRoute) -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    #if os(iOS)
    @State private var isSearchRevealed = false
    #endif

    enum Content {
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
        .moodleRefreshFailureNote(store.members, hasContent: store.members.value != nil)
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

struct MoodleMemberRow: View {
    let member: MoodleMember
    let picture: CGImage?

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
                if let studentId = member.studentId {
                    subline(studentId)
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
        .accessibilityValue([member.studentId, department].compactMap(\.self).joined(separator: ", "))
    }

    private var department: String? { member.department?.shortName }

    private func subline(_ studentId: String) -> some View {
        HStack(spacing: 0) {
            Text(studentId)
                .monospacedDigit()
                .fixedSize()
                .layoutPriority(1)
            if let department {
                Text(verbatim: " · \(department)")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(TigerDuckTheme.Typography.caption)
        .foregroundStyle(Color.textSecondary)
    }
}
