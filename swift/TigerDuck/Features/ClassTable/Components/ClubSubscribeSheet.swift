import SwiftUI

struct ClubSubscribeSheet: View {
    /// The sign-in the sheet opened in, which its changes are saved for.
    let signIn: SignIn
    var directory: ClubDirectory = .shared
    var subscriptions: ClubSubscriptions = .shared

    @State private var searchText = ""
    @State private var isLoading = false
    @State private var colorTarget: ClassTableEditor.ClubColorTarget?
    @FocusState private var searchFocused: Bool

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            let matches = query.isEmpty ? [] : directory.search(query)
            List {
                if showsMaintenance {
                    EmptyStateView(
                        icon: "wrench.and.screwdriver",
                        title: String(localized: "class_table_club_maintenance_title"),
                        message: String(localized: "class_table_club_maintenance_message")
                    )
                    .padding(.vertical, TigerDuckTheme.Spacing.xxl)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if directory.clubs.isEmpty {
                    SearchSheetStatus(
                        searching: isLoading ? String(localized: "class_table_club_searching") : nil,
                        failure: isLoading ? nil : failureText
                    )
                }
                if query.isEmpty {
                    subscribedSection
                    allSection
                } else {
                    ForEach(matches) { clubRow($0) }
                }
            }
            .overlay {
                if !query.isEmpty, matches.isEmpty, !directory.clubs.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchSheetChrome(
                title: String(localized: "class_table_subscribe_clubs"),
                prompt: String(localized: "class_table_club_search_prompt"),
                text: $searchText,
                focused: $searchFocused
            )
        }
        .presentationBackground(Color.backgroundPrimary)
        .clubColorSheet($colorTarget, signIn: signIn, subscriptions: subscriptions)
        .task {
            isLoading = directory.clubs.isEmpty
            await directory.refresh()
            isLoading = false
        }
    }

    private var showsMaintenance: Bool {
        directory.clubs.isEmpty && !isLoading && directory.isUnderMaintenance
    }

    private var failureText: String? {
        directory.failure.map { String(format: String(localized: "class_table_club_search_failed"), $0.localizedDescription) }
    }

    @ViewBuilder
    private var subscribedSection: some View {
        let subscribed = subscriptions.subscribedIDs.compactMap(directory.club)
        if !subscribed.isEmpty {
            Section(String(localized: "class_table_club_section_subscribed")) {
                ForEach(subscribed) { club in
                    let name = directory.displayName(of: club)
                    HStack(spacing: TigerDuckTheme.Spacing.md) {
                        Button {
                            colorTarget = .init(id: club.id, name: name)
                        } label: {
                            ColorSquare(color: Color(hex: UInt(subscriptions.color(of: club.id))), side: 22)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(format: String(localized: "a11y_class_table_club_color"), name))
                        ClubNameLabel(name: name, tagline: club.tagline)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            subscriptions.unsubscribe(club.id, for: signIn)
                        } label: {
                            Text(String(localized: "class_table_club_unsubscribe_action"))
                        }
                    }
                }
                .onMove { source, destination in
                    let move = Self.move(
                        source, to: destination, shown: subscribed.map(\.id), order: subscriptions.subscribedIDs
                    )
                    subscriptions.move(fromOffsets: move.source, toOffset: move.destination, for: signIn)
                }
            }
        }
    }

    @ViewBuilder
    private var allSection: some View {
        if !directory.clubs.isEmpty {
            Section(String(localized: "class_table_club_section_all")) {
                ForEach(directory.clubs) { clubRow($0) }
            }
        }
    }

    private func clubRow(_ club: ClubDirectory.Club) -> some View {
        let subscribed = subscriptions.isSubscribed(club.id)
        let mark: AddCourseRowMark = subscribed ? .addedHere : .notAdded
        return Button {
            if subscribed {
                subscriptions.unsubscribe(club.id, for: signIn)
            } else {
                subscriptions.subscribe(club.id, for: signIn)
            }
        } label: {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                ClubNameLabel(name: directory.displayName(of: club), tagline: club.tagline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: mark.symbol)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(subscribed ? .isSelected : [])
        .accessibilityHint(String(localized: subscribed ? "class_table_club_unsubscribe_action" : "class_table_club_subscribe_action"))
    }

    /// The list hides a subscribed club the directory no longer has, so a move's offsets in the
    /// `shown` IDs are mapped onto the subscriptions' own `order`.
    static func move(
        _ source: IndexSet, to destination: Int, shown: [Int], order: [Int]
    ) -> (source: IndexSet, destination: Int) {
        let from = IndexSet(source.compactMap { order.firstIndex(of: shown[$0]) })
        let to = shown.indices.contains(destination) ? order.firstIndex(of: shown[destination]) ?? order.count : order.count
        return (from, to)
    }
}

private struct ClubNameLabel: View {
    let name: String
    let tagline: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
            if let tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

extension View {
    func clubColorSheet(
        _ target: Binding<ClassTableEditor.ClubColorTarget?>, signIn: SignIn, subscriptions: ClubSubscriptions = .shared
    ) -> some View {
        modifier(ClubColorSheet(target: target, signIn: signIn, subscriptions: subscriptions))
    }
}

private struct ClubColorSheet: ViewModifier {
    @Binding var target: ClassTableEditor.ClubColorTarget?
    let signIn: SignIn
    let subscriptions: ClubSubscriptions

    func body(content: Content) -> some View {
        content.sheet(item: $target) { club in
            ColorPickerSheet(
                name: club.name,
                detail: nil,
                labels: ColorPickerSheet.Labels(
                    title: String(localized: "class_table_club_color_picker_title"),
                    custom: String(localized: "class_table_club_color_custom_label"),
                    customBadge: String(localized: "class_table_club_color_custom_badge"),
                    swatch: String(localized: "a11y_class_table_club_color_swatch")
                ),
                appliedHex: { subscriptions.color(of: club.id) },
                signIn: signIn,
                onSelect: { subscriptions.setColor($0, of: club.id, for: signIn) }
            )
            .presentationDetents([.medium, .large])
        }
    }
}
