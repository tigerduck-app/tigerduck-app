#if os(iOS)
import Defaults
import Foundation
import SwiftUI
import Testing
@testable import TigerDuck

private let doneKey = "FlipToLibraryDefaultOffMigration.v1.done"
private let seenKey = "firstTriggerPromptSeen.flipToLibrary"

@Suite(.serialized)
@MainActor
struct FlipToLibraryDefaultOffMigrationTests {
    private static let switchKey = Defaults.Key<Bool>.flipToLibraryEnabled

    private static func withRealKeys(_ body: () -> Void) async {
        await withExclusiveRealDefaults {
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
