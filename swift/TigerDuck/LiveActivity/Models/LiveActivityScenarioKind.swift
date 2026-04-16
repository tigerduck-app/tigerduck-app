import Foundation

/// Three scenarios that may drive the single active Live Activity.
/// Priority is encoded on the case order: inClass > classPreparing > assignmentUrgent.
nonisolated enum LiveActivityScenarioKind: String, Codable, Sendable, CaseIterable {
    case inClass
    case classPreparing
    case assignmentUrgent

    /// Lower number = higher priority.
    var priority: Int {
        switch self {
        case .inClass: return 0
        case .classPreparing: return 1
        case .assignmentUrgent: return 2
        }
    }
}
