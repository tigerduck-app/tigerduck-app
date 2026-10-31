import SwiftUI

/// One Home section: the time slider, the assignment list with its filter, or a grid of shortcuts.
struct HomeSectionView: View {
    let section: HomeSection
    let viewModel: HomeViewModel
    let app: AppEnvironment
    var asListRows = false
    let scrollAnchor: HomeScrollAnchor
    var onFeatureTap: ((AppFeature) -> Void)? = nil
    var onOpenAssignment: (AssignmentStore.Assignment) -> Void = { _ in }

    private var filterPicker: some View {
        Picker("", selection: Bindable(viewModel).assignments.filter) {
            ForEach(viewModel.assignments.availableFilters, id: \.self) { filter in
                Text(filter.displayName).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    private var assignmentAccess: NTUSTProtectedAccessState {
        NTUSTProtectedAccessState(signedIn: app.authService.hasStoredCredentials, isEmpty: viewModel.assignments.upcoming.isEmpty)
    }

    @ViewBuilder
    private var assignmentPlaceholder: some View {
        if assignmentAccess == .loginRequired {
            LoginRequiredView(
                layout: .section,
                title: String(localized: "common_not_signed_in"),
                message: String(localized: "home_assignments_sign_in_required_message"),
                onPrimary: { app.router.presentNTUSTLogin() }
            )
        } else {
            EmptyStateView(
                icon: "checkmark.circle",
                title: String(localized: "home_assignments_all_good"),
                message: assignmentEmptyMessage
            )
        }
    }

    private var assignmentList: some View {
        UpcomingAssignmentsView(
            assignments: viewModel.assignments.upcoming,
            courses: viewModel.allCourses,
            filter: viewModel.assignments.filter,
            showAbsoluteTime: app.preferences.showAbsoluteAssignmentTime,
            asListRows: asListRows,
            scrollAnchor: scrollAnchor,
            scrollSectionID: section.id,
            onArchive: {
                viewModel.archiveAssignment($0)
                app.edits.syncAssignmentOverride(moodleId: $0.assignmentId, status: "archived")
            },
            onMarkComplete: {
                viewModel.markAssignmentAsLocallyCompleted($0)
                app.edits.syncAssignmentOverride(moodleId: $0.assignmentId, status: "locally_completed")
            },
            onUnarchive: {
                viewModel.unarchiveAssignment($0)
                app.edits.syncAssignmentOverride(moodleId: $0.assignmentId, status: "none")
            },
            onUndoComplete: {
                viewModel.undoLocallyCompleted($0)
                app.edits.syncAssignmentOverride(moodleId: $0.assignmentId, status: "none")
            },
            onOpen: onOpenAssignment
        )
    }

    private var assignmentEmptyMessage: String {
        switch viewModel.assignments.filter {
        case .incomplete:
            return String(localized: "home_assignments_none_incomplete")
        case .all:
            return String(localized: "home_assignments_none")
        case .ignored:
            return String(localized: "home_assignments_no_ignored")
        }
    }

    var body: some View {
        if asListRows {
            SectionHeader(title: section.title)
                .homeScrollAnchor(section.id, in: scrollAnchor)
                .homeListRow(top: TigerDuckTheme.Spacing.lg)
            filterPicker
                .homeScrollRow(section.id, in: scrollAnchor)
                .homeListRow(top: TigerDuckTheme.Spacing.sm)
            if assignmentAccess == .content {
                assignmentList
            } else {
                assignmentPlaceholder
                    .homeScrollRow(section.id, in: scrollAnchor)
                    .homeListRow(top: TigerDuckTheme.Spacing.sm)
            }
        } else {
            stackedBody
        }
    }

    private var stackedBody: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            if section.type != .todayCourses {
                SectionHeader(title: section.title)
            }

            switch section.type {
            case .todayCourses:
                TimeSliderSection(
                    courses: viewModel.allCourses,
                    onSelectCourse: { slot in
                        viewModel.sheets.selectedCourseSlot = slot
                        viewModel.sheets.selectedCourse = slot.course(in: viewModel.allCourses)
                    }
                )
            case .upcomingAssignments:
                filterPicker
                if assignmentAccess == .content {
                    assignmentList
                } else {
                    assignmentPlaceholder
                }
            case .quickWidgets, .custom:
                WidgetGridView(
                    widgets: Binding(
                        get: {
                            viewModel.layout.sections.first(where: { $0.id == section.id })?.widgets ?? []
                        },
                        set: { newWidgets in
                            if let idx = viewModel.layout.sections.firstIndex(where: { $0.id == section.id }) {
                                viewModel.layout.sections[idx].widgets = newWidgets
                            }
                        }
                    ),
                    isEditing: false,
                    dragContainerID: section.id,
                    onTap: { feature in
                        onFeatureTap?(feature)
                    }
                )
            }
        }
    }
}

extension View {
    func homeListRow(top: CGFloat, bottom: CGFloat = 0, horizontal: CGFloat = 0) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: horizontal, bottom: bottom, trailing: horizontal))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
