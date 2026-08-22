#if os(macOS)
import SwiftUI
import AppKit

/// Mac analogue of the iPhone `UpcomingAssignmentsView`.
///
/// Same data + same DataCache writes (archive / locally-complete / undo),
/// but the swipe gesture is replaced with a right-click context menu —
/// the natural Mac equivalent — plus a hover toolbar with the same
/// actions for trackpad users who'd rather not right-click. The
/// segmented filter (Incomplete / All / Ignored) on top mirrors the
/// iPhone picker so muscle memory carries across.
struct MacAssignmentsList: View {
    /// In-memory course roster so the secondary line on each row reflects
    /// the user's rename and the canonical NTUST course code (same contract
    /// as the iPhone `UpcomingAssignmentsView`). Without this, the row falls
    /// back to the cached `assignment.courseName`.
    var courses: [SDCourse] = []

    @Environment(AppState.self) private var appState

    private var courseByNo: [String: SDCourse] {
        Dictionary(courses.map { ($0.courseNo, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        // TimelineView so "due in 2h" labels and the past/present
        // partition for the "All" tab tick on real wall time. AppClock
        // is what gets read inside — same contract as iPhone — so a
        // debug clock override flows through to both.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            content(now: AppClock.now())
        }
    }

    private func content(now: Date) -> some View {
        let store = AssignmentStore.shared
        let filter = store.filter
        let visible = store.visibleAssignments(filter: filter, now: now)

        return VStack(alignment: .leading, spacing: 12) {
            Picker(String(localized: "desktop_assignment_filter_label"), selection: Binding(
                get: { store.filter },
                set: { store.filter = $0 }
            )) {
                ForEach(AssignmentFilter.allCases, id: \.self) { f in
                    Text(f.displayName).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if visible.isEmpty {
                emptyState(for: filter)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(visible, id: \.assignmentId) { assignment in
                        row(assignment, now: now)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ assignment: SDAssignment, now: Date) -> some View {
        let status = assignment.status(now: now)
        Button {
            openInBrowser(assignment)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                statusDot(for: status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(assignment.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(assignment.courseLineLabel(matching: courseByNo[assignment.courseNo]))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    if let label = status.badgeLabel {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(status.tint)
                    }
                    Text(timeLabel(for: assignment, now: now))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(timeColor(status: status))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                .fill(.background.tertiary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .contextMenu {
            menuItems(for: assignment, status: status)
        }
    }

    @ViewBuilder
    private func menuItems(for assignment: SDAssignment, status: AssignmentStatus) -> some View {
        if assignment.moodleOpenURL != nil {
            Button {
                openInBrowser(assignment)
            } label: {
                Label(String(localized: "desktop_action_open_in_moodle"), systemImage: "arrow.up.right.square")
            }
            Divider()
        }

        switch status {
        case .pending, .overdueAcceptable, .overdueRejected:
            Button {
                AssignmentStore.shared.markComplete(assignment)
                appState.syncAssignmentOverride(moodleId: assignment.assignmentId, status: "locally_completed")
            } label: {
                Label(String(localized: "desktop_assignment_mark_complete"), systemImage: "checkmark.circle.fill")
            }
            Button {
                AssignmentStore.shared.archive(assignment)
                appState.syncAssignmentOverride(moodleId: assignment.assignmentId, status: "archived")
            } label: {
                Label(String(localized: "assignment_ignore"), systemImage: "archivebox.fill")
            }

        case .locallyCompleted:
            Button {
                AssignmentStore.shared.undoComplete(assignment)
                appState.syncAssignmentOverride(moodleId: assignment.assignmentId, status: "none")
            } label: {
                Label(String(localized: "assignment_mark_complete_undo"), systemImage: "arrow.uturn.backward")
            }

        case .archived:
            Button {
                AssignmentStore.shared.unarchive(assignment)
                appState.syncAssignmentOverride(moodleId: assignment.assignmentId, status: "none")
            } label: {
                Label(String(localized: "assignment_ignore_undo"), systemImage: "arrow.uturn.backward")
            }

        case .submitted, .submittedLate:
            EmptyView()
        }
    }

    // MARK: - Pieces

    private func statusDot(for status: AssignmentStatus) -> some View {
        Circle()
            .fill(status.tint)
            .frame(width: 8, height: 8)
    }

    private func timeLabel(for assignment: SDAssignment, now: Date) -> String {
        if appState.showAbsoluteAssignmentTime || assignment.dueDate < now {
            return assignment.dueDate.absoluteTimeString
        }
        return assignment.dueDate.relativeTimeString(from: now)
    }

    private func timeColor(status: AssignmentStatus) -> Color {
        switch status {
        case .overdueAcceptable, .overdueRejected, .archived, .locallyCompleted:
            return .badgeRed
        case .pending, .submitted, .submittedLate:
            return .secondary
        }
    }

    private func openInBrowser(_ assignment: SDAssignment) {
        guard let url = assignment.moodleOpenURL else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func emptyState(for filter: AssignmentFilter) -> some View {
        let message: String = switch filter {
        case .incomplete: "All caught up — no outstanding assignments."
        case .all: "No assignments cached yet."
        case .ignored: "Nothing ignored."
        }
        VStack(spacing: 8) {
            Image(systemName: filter == .incomplete ? "checkmark.circle" : "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                .fill(.background.tertiary)
        )
    }
}

/// Shared in-memory store backed by `DataCache`.
///
/// `MacHomeView` re-derives `assignments` per render from this store so
/// archive / complete actions taken from a context menu show up
/// immediately — the store invalidates AppState's observation token by
/// calling `appState.bumpDataVersion()` after each mutation (which is
/// what the iOS HomeViewModel does indirectly via `withAnimation` +
/// `recomputeUpcomingAssignments`).
@MainActor
@Observable
final class AssignmentStore {
    static let shared = AssignmentStore()

    var filter: AssignmentFilter = .incomplete
    private(set) var version: Int = 0

    private init() {}

    /// Returns the assignments matching `filter`, ordered the way the
    /// iPhone home page orders them: incomplete sorted by due date,
    /// archived list sorted reverse-chronological, all-tab partitioned
    /// past-vs-future like the iPhone view does.
    func visibleAssignments(filter: AssignmentFilter, now: Date) -> [SDAssignment] {
        // Touch `version` so SwiftUI's body re-runs when a mutation
        // bumps it. Without this read, archive / complete from the
        // context menu would update the cache but not the visible list
        // until the next AppState data notification.
        _ = version
        let all = DataCache.shared.loadAssignments()
        switch filter {
        case .incomplete:
            return all
                .filter { !$0.isCompleted && !$0.isArchived && !$0.isLocallyCompleted }
                .sorted { $0.dueDate < $1.dueDate }
        case .all:
            return all.partitionedByDueDate(now: now)
        case .ignored:
            return all
                .filter { $0.isArchived }
                .sorted { $0.dueDate > $1.dueDate }
        }
    }

    func archive(_ assignment: SDAssignment) {
        DataCache.shared.addArchivedAssignmentId(assignment.assignmentId)
        bump()
    }

    func unarchive(_ assignment: SDAssignment) {
        DataCache.shared.removeArchivedAssignmentId(assignment.assignmentId)
        bump()
    }

    func markComplete(_ assignment: SDAssignment) {
        DataCache.shared.addLocallyCompletedAssignmentId(assignment.assignmentId)
        bump()
    }

    func undoComplete(_ assignment: SDAssignment) {
        DataCache.shared.removeLocallyCompletedAssignmentId(assignment.assignmentId)
        bump()
    }

    private func bump() {
        version &+= 1
    }
}
#endif
