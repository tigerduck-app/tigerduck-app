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
}
