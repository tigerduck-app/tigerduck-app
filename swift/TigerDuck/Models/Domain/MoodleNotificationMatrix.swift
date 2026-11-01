import Foundation

/// The student's Moodle notification preferences, as Moodle's "Notification preferences" page
/// shows them. Every name is the server's, in the language the request asked for.
nonisolated struct MoodleNotificationMatrix: Equatable, Sendable {
    /// A delivery method, which Moodle calls a processor.
    struct Method: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
    }

    struct Component: Equatable, Sendable, Identifiable {
        let name: String
        var preferences: [Preference]

        var id: String { preferences.first?.key ?? name }
    }

    struct Preference: Equatable, Sendable, Identifiable {
        let key: String
        let name: String
        /// Every processor of the row in the server's order, the hidden methods too.
        let processors: [String]
        var enabled: Set<String>
        let locked: Set<String>

        var id: String { key }

        func setting(_ method: String, on: Bool) -> Preference {
            var changed = self
            if on { changed.enabled.insert(method) } else { changed.enabled.remove(method) }
            return changed
        }
    }

    let methods: [Method]
    var components: [Component]
    /// Moodle's "Disable notifications", the account's `emailstop`.
    let disablesAll: Bool

    func replacing(_ preference: Preference) -> MoodleNotificationMatrix {
        var changed = self
        changed.components = components.map { component in
            var component = component
            component.preferences = component.preferences.map { $0.key == preference.key ? preference : $0 }
            return component
        }
        return changed
    }
}
