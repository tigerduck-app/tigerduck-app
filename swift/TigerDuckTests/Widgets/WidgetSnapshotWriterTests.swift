import Foundation
import Testing
@testable import TigerDuck

/// Only the app writes the widget snapshot, so whatever it carries must reach it through an
/// event the writer observes; otherwise the widgets show the old value until the app is next
/// brought to the foreground.
@MainActor
struct WidgetSnapshotWriterTests {
    private struct NoReload: WidgetReloadCoordinator.Reloader {
        func reloadAllTimelines() {}
    }

    @MainActor
    private final class Accent {
        var hex = 0x007AFF
    }

    @Test func anAccentChangeRewritesTheSnapshot() async throws {
        let suite = "WidgetSnapshotWriterTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(appGroupIdentifier: suite)
        let accent = Accent()
        let writer = WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { accent.hex },
            store: store,
            coordinator: WidgetReloadCoordinator(reloader: NoReload())
        )
        writer.regenerate()
        #expect(store.readSnapshot()?.accentColorHex == 0x007AFF)

        accent.hex = 0xFF2D55
        NotificationCenter.default.post(name: AppConstants.accentColorDidChange, object: nil)

        try await waitUntil { store.readSnapshot()?.accentColorHex == 0xFF2D55 }
        withExtendedLifetime(writer) {}
    }

    /// Every return to the app and every data change regenerates, and most change nothing a
    /// widget shows; rewriting and reloading anyway would spend the widgets' reload budget.
    @Test func anUnchangedSnapshotIsNeitherRewrittenNorReloaded() throws {
        let suite = "WidgetSnapshotWriterTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(appGroupIdentifier: suite)
        let coordinator = WidgetReloadCoordinator(reloader: NoReload())
        let writer = WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { 0x007AFF },
            store: store,
            coordinator: coordinator
        )
        writer.regenerate()
        let written = try #require(store.readSnapshot())
        let reload = try #require(coordinator.pendingTask)

        writer.regenerate()

        #expect(store.readSnapshot()?.generatedAt == written.generatedAt)
        #expect(coordinator.pendingTask == reload)
        withExtendedLifetime(writer) {}
    }

    /// The widgets draw their own text in the new language, so a locale change reloads them
    /// although the snapshot holds nothing that changed.
    @Test func aLocaleChangeReloadsAnUnchangedSnapshot() async throws {
        let suite = "WidgetSnapshotWriterTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(appGroupIdentifier: suite)
        let coordinator = WidgetReloadCoordinator(reloader: NoReload())
        let writer = WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { 0x007AFF },
            store: store,
            coordinator: coordinator
        )
        writer.regenerate()
        let reload = try #require(coordinator.pendingTask)

        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)

        try await waitUntil { coordinator.pendingTask != reload }
        withExtendedLifetime(writer) {}
    }
}
