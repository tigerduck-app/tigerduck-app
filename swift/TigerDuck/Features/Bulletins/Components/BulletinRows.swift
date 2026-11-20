import SwiftUI

struct BulletinRows: View {
    let viewModel: BulletinsViewModel
    let taxonomy: BulletinTaxonomyStore
    let readState: BulletinReadStateStore
    let unreadOnly: Bool
    @Binding var detailingBulletin: BulletinAPI.BulletinSummary?

    @Environment(AppEnvironment.self) private var app

    var body: some View {
        if viewModel.items.isEmpty {
            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView().padding(.vertical, 60)
                .centeredListRow()
            case .failed(let message):
                LoadFailureView(title: String(localized: "bulletin_load_failed_title"), message: message) {
                    Task { await viewModel.refresh() }
                }
                .centeredListRow()
            case .loaded:
                EmptyStateView(
                    icon: "tray",
                    title: String(localized: "bulletin_no_bulletins_title"),
                    message: String(localized: "bulletin_no_bulletins_message")
                )
                .frame(height: 200)
                .centeredListRow()
            }
        } else if displayedItems.isEmpty {
            EmptyStateView(
                icon: unreadOnly ? "envelope.open" : "tray",
                title: unreadOnly
                    ? String(localized: "bulletin_no_unread_title")
                    : String(localized: "bulletin_no_bulletins_title"),
                message: viewModel.hasActiveFilter || unreadOnly
                    ? String(localized: "bulletin_no_match_message")
                    : String(localized: "bulletin_no_bulletins_message")
            )
            .frame(height: 200)
            .centeredListRow()
        } else {
            ForEach(displayedItems) { bulletin in
                // A plain Button, not a NavigationLink, keeps the tap highlight without
                // the trailing chevron.
                Button {
                    detailingBulletin = bulletin
                } label: {
                    BulletinCardView(
                        bulletin: bulletin,
                        taxonomy: taxonomy,
                        isRead: readState.isRead(bulletin.id)
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: TigerDuckTheme.Spacing.xs,
                    leading: TigerDuckTheme.Spacing.lg,
                    bottom: TigerDuckTheme.Spacing.xs,
                    trailing: TigerDuckTheme.Spacing.lg
                ))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        readState.toggleRead(bulletin.id)
                    } label: {
                        Label(
                            readState.isRead(bulletin.id)
                                ? String(localized: "bulletin_mark_as_unread_action")
                                : String(localized: "bulletin_mark_as_read_action"),
                            systemImage: readState.isRead(bulletin.id)
                                ? "envelope.badge"
                                : "envelope.open"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .tint(app.preferences.accentColor)
                }
                .task {
                    await viewModel.loadMoreIfNeeded(triggeredBy: bulletin)
                }
            }

            if viewModel.isPaginating {
                ProgressView().padding(.vertical, TigerDuckTheme.Spacing.md)
                .centeredListRow()
            }
        }
    }

    private var displayedItems: [BulletinAPI.BulletinSummary] {
        if unreadOnly {
            return viewModel.filteredItems.filter { !readState.isRead($0.id) }
        }
        return viewModel.filteredItems
    }
}
