import Defaults
import Foundation

/// A TigerSync switch. The raw value is what `Defaults` stores and what the backend's device row
/// calls the switch, as `sync_<raw value>`.
nonisolated enum SyncCategory: String, CaseIterable, Sendable, Defaults.Serializable {
    case courses
    case courseColors = "course_colors"
    case courseNames = "course_names"
    case assignments
}

nonisolated extension Set<SyncCategory> {
    var logged: [String] { map(\.rawValue).sorted() }
}
