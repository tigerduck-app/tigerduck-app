import Defaults
import Foundation

struct HomeAssignmentList {
    var all: [AssignmentStore.Assignment] = []

    var filter: AssignmentFilter = AssignmentFilter(rawValue: Defaults[.homeAssignmentFilter]) ?? .incomplete {
        didSet {
            guard filter != oldValue else { return }
            Defaults[.homeAssignmentFilter] = filter.rawValue
            recompute()
        }
    }

    private(set) var upcoming: [AssignmentStore.Assignment] = []

    var availableFilters: [AssignmentFilter] {
        AssignmentFilter.visibleFilters(hasIgnored: all.hasIgnored())
    }

    mutating func recompute() {
        if !availableFilters.contains(filter) {
            filter = .all
        }

        switch filter {
        case .incomplete:
            upcoming = all.upcomingSorted()
        case .all:
            upcoming = all.allCandidates()
        case .ignored:
            upcoming = all.ignoredSorted()
        }
    }

    func unfinished(for courseNo: String) -> [AssignmentStore.Assignment] {
        all.unfinished(for: courseNo).sorted { $0.dueDate < $1.dueDate }
    }

    mutating func archive(_ assignment: AssignmentStore.Assignment) {
        guard let idx = all.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        all[idx].isArchived = true
        AssignmentStore.shared.apply(.setArchived(id: assignment.assignmentId, true), for: AccountSession.school.currentSignIn)
        if all[idx].isLocallyCompleted {
            all[idx].isLocallyCompleted = false
            AssignmentStore.shared.apply(.setLocallyCompleted(id: assignment.assignmentId, false), for: AccountSession.school.currentSignIn)
        }
        recompute()
    }

    mutating func unarchive(_ assignment: AssignmentStore.Assignment) {
        guard let idx = all.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        all[idx].isArchived = false
        AssignmentStore.shared.apply(.setArchived(id: assignment.assignmentId, false), for: AccountSession.school.currentSignIn)
        recompute()
    }

    mutating func markCompleted(_ assignment: AssignmentStore.Assignment) {
        guard let idx = all.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        all[idx].isLocallyCompleted = true
        AssignmentStore.shared.apply(.setLocallyCompleted(id: assignment.assignmentId, true), for: AccountSession.school.currentSignIn)
        if all[idx].isArchived {
            all[idx].isArchived = false
            AssignmentStore.shared.apply(.setArchived(id: assignment.assignmentId, false), for: AccountSession.school.currentSignIn)
        }
        recompute()
    }

    mutating func undoCompleted(_ assignment: AssignmentStore.Assignment) {
        guard let idx = all.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        all[idx].isLocallyCompleted = false
        AssignmentStore.shared.apply(.setLocallyCompleted(id: assignment.assignmentId, false), for: AccountSession.school.currentSignIn)
        recompute()
    }
}
