import Foundation

/// The `club_subscriptions` settings document's sync, where a push and a pull are one step: the
/// device's copy and the server's are merged value by value (`ClubSubscriptionsDocument.merged`),
/// and the result is written back when it differs from what the server holds.
/// See docs/decisions/0030-club-subscriptions-document.md.
nonisolated enum ClubSubscriptionsSync {
    static let namespace = "club_subscriptions"

    enum SyncError: Error, Equatable {
        case conflictNotResolved
    }

    /// The document the server holds once the merge is on it, or nil when `mayWrite` turned false
    /// before a write. `stored` is a snapshot's copy, or nil to read the server's. A 409 is merged
    /// once more with the newer copy it carries.
    static func sync(
        local: ClubSubscriptionsDocument,
        client: SettingsDocumentClient,
        stored: SettingsDocument?,
        mayWrite: () -> Bool
    ) async throws -> ClubSubscriptionsDocument? {
        var current = if let stored { stored } else { try await client.read(namespace: namespace) }
        for _ in 0...1 {
            var existing: [String: Any] = [:]
            var mode = SettingsWriteMode.create
            var server = ClubSubscriptionsDocument()
            if case .stored(let document, let revision) = current {
                existing = SettingsDocument.object(from: document)
                mode = .replace(revision: revision)
                server = ClubSubscriptionsDocument(json: document)
            }
            let merged = ClubSubscriptionsDocument.merged(local: local, server: server)
            if merged == server { return merged }
            guard mayWrite() else { return nil }
            let written = SettingsDocument.merging(SettingsDocument.object(from: merged.json()), into: existing)
            let body = try JSONSerialization.data(withJSONObject: written, options: [.sortedKeys])
            switch try await client.write(namespace: namespace, document: body, mode: mode) {
            case .written:
                return merged
            case .conflict(let document, let revision):
                current = .stored(document: document, revision: revision)
            }
        }
        throw SyncError.conflictNotResolved
    }
}
