import Defaults
import SwiftUI

struct HomeBrowsePage: View {
    let viewModel: HomeViewModel
    let sections: [HomeSection]
    let scrollAnchor: HomeScrollAnchor
    let onEdit: () -> Void
    let onFeatureTap: (AppFeature) -> Void
    let onOpenAssignment: (AssignmentStore.Assignment) -> Void

    @Environment(AppEnvironment.self) private var app

    var body: some View {
        List {
            HomeTitleBar(onEdit: onEdit)
                .homeListRow(top: TigerDuckTheme.Spacing.md)

            if let reauthError = app.authService.reauthErrorMessage {
                NTUSTReauthErrorBanner(
                    message: reauthError,
                    onRetry: {
                        app.authService.clearReauthError()
                        app.router.presentNTUSTLogin()
                    },
                    onDismiss: { app.authService.clearReauthError() }
                )
                    .homeListRow(top: TigerDuckTheme.Spacing.lg)
            }

            ForEach(sections) { section in
                if section.type == .upcomingAssignments {
                    homeSection(section, asListRows: true)
                } else {
                    homeSection(section)
                        .homeScrollAnchor(section.id, in: scrollAnchor)
                        .homeListRow(top: TigerDuckTheme.Spacing.lg)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.bottom, TigerDuckTheme.Spacing.xxl, for: .scrollContent)
        .homeScrollTop(in: scrollAnchor)
        .animation(
            UpcomingAssignmentsView.listChangeAnimation,
            value: viewModel.assignments.upcoming.map(\.assignmentId)
        )
        .refreshable {
            viewModel.triggerRefresh(authService: app.authService)
            Task { await SchoolRefresh.courseChanges() }
            if Defaults[.cloudSyncEnabled] {
                Task { await app.fullSync.sync() }
            }
        }
    }

    private func homeSection(_ section: HomeSection, asListRows: Bool = false) -> some View {
        HomeSectionView(
            section: section,
            viewModel: viewModel,
            app: app,
            asListRows: asListRows,
            scrollAnchor: scrollAnchor,
            onFeatureTap: onFeatureTap,
            onOpenAssignment: onOpenAssignment
        )
    }
}
