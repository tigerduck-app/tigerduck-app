// Runs on the real keys, which are the migration's whole job, inside `withExclusiveRealDefaults`.
// Each key is restored as present or absent, as the migration reads an absent key as never set.
#if os(iOS)
import Defaults
import Foundation
import SwiftUI
import Testing
@testable import TigerDuck

private let doneKey = "FlipToLibraryDefaultOffMigration.v1.done"
private let seenKey = "firstTriggerPromptSeen.flipToLibrary"

/// 2.5.0 turns flip-to-library off by default. A user who kept it at 2.4's first-flip prompt never
/// stored it and keeps it on; one who chose either way is not asked again
/// (https://github.com/tigerduck-app/tigerduck-app/issues/434).
@Suite(.serialized)
@MainActor
struct FlipToLibraryDefaultOffMigrationTests {
    private static let switchKey = Defaults.Key<Bool>.flipToLibraryEnabled

    private static func withRealKeys(_ body: () -> Void) async {
        await withExclusiveRealDefaults {
            // The done and seen flags are in the standard suite; the switch is in its key's suite.
            let stores = [(UserDefaults.standard, doneKey), (UserDefaults.standard, seenKey), (switchKey.suite, switchKey.name)]
            let saved = stores.map { store, key in (store, key, Self.storedValue(store, key)) }
            defer {
                for (store, key, value) in saved {
                    if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
                }
            }
            for (store, key) in stores { store.removeObject(forKey: key) }
            body()
        }
    }

    /// What a key holds in its suite's own domain. `object(forKey:)` would also return the default
    /// `Defaults` registers for the switch, which the restore would then write as a stored value.
    private static func storedValue(_ store: UserDefaults, _ key: String) -> Any? {
        guard let domain = Bundle.main.bundleIdentifier else { return nil }
        return store.persistentDomain(forName: domain)?[key]
    }

    @Test func aSwitchSetInSettingsAnswersTheQuestion() async {
        await Self.withRealKeys {
            var enabled = false
            let toggle = LibrarySettingsView.flipSwitch(Binding(get: { enabled }, set: { enabled = $0 }), signedIn: true)

            toggle.wrappedValue = true
            toggle.wrappedValue = false

            #expect(FirstTriggerPromptCenter.shared.hasSeen(.flipToLibrary))
        }
    }

    @Test func aGestureKeptAtTheFirstFlipStaysOn() async {
        await Self.withRealKeys {
            FirstTriggerPromptCenter.shared.markSeen(.flipToLibrary)

            #expect(FlipToLibraryDefaultOffMigration.runIfNeeded())

            #expect(Defaults[.flipToLibraryEnabled])
        }
    }

    @Test func aSwitchSetInSettingsKeepsItsValueAndIsNotAskedAbout() async {
        await Self.withRealKeys {
            Defaults[.flipToLibraryEnabled] = false

            #expect(!FlipToLibraryDefaultOffMigration.runIfNeeded())

            #expect(!Defaults[.flipToLibraryEnabled])
            #expect(FirstTriggerPromptCenter.shared.hasSeen(.flipToLibrary))
        }
    }

    @Test func aUserWhoNeverFlippedIsAskedLater() async {
        await Self.withRealKeys {
            #expect(!FlipToLibraryDefaultOffMigration.runIfNeeded())

            #expect(!Defaults[.flipToLibraryEnabled])
            #expect(!FirstTriggerPromptCenter.shared.hasSeen(.flipToLibrary))
            #expect(!FlipToLibraryDefaultOffMigration.runIfNeeded())
        }
    }
}
#endif
