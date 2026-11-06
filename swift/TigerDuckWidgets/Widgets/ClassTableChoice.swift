import AppIntents
import WidgetKit

struct ClassTableEntity: AppEntity {
    static let ownID = "own"

    let id: String
    let name: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("widget_class_table_choice")
    )
    static let defaultQuery = ClassTableQuery()

    static var own: ClassTableEntity {
        ClassTableEntity(id: ownID, name: String(localized: "widget_class_table_own"))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ClassTableQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ClassTableEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ClassTableEntity] {
        [.own] + WidgetSnapshotStore().readPeople().map { ClassTableEntity(id: $0.id, name: $0.name) }
    }

    func defaultResult() async -> ClassTableEntity? {
        .own
    }
}

struct ChooseClassTableIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget_class_table_choose"

    @Parameter(title: LocalizedStringResource("widget_class_table_choice"))
    var classTable: ClassTableEntity?

    /// Nil for the user's own table, which a widget placed before it could be configured also shows.
    var personID: String? {
        classTable?.id == ClassTableEntity.ownID ? nil : classTable?.id
    }
}
