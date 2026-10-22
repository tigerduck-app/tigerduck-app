import Foundation

nonisolated enum LiveActivityScenarioKind: String, Codable, Sendable, CaseIterable {
    case inClass
    case classPreparing
    case assignmentUrgent

    var priority: Int {
        switch self {
        case .inClass: return 0
        case .classPreparing: return 1
        case .assignmentUrgent: return 2
        }
    }
}
