// Which stored bottom bars `LibraryTabAddMigration` pins Library on. iPhone/iPad-only like the
// migration; the test target also builds for macOS. `doneKey` mirrors the migration's private
// flag literal.
#if os(iOS)
import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "LibraryTabAddMigration.v1.done"
private let libraryOptInKey = "libraryFeatureEnabled"

@MainActor
struct LibraryTabAddMigrationTests {
    private static func withRealMigrationKeys(_ body: () throws -> Void) async throws {
        try await withExclusiveRealDefaults {
            let names = [doneKey, libraryOptInKey, Defaults.Keys.configuredTabsData.name]
            let saved = names.map { UserDefaults.standard.object(forKey: $0) }
            defer {
                for (name, value) in zip(names, saved) {
                    if let value {
                        UserDefaults.standard.set(value, forKey: name)
                    } else {
                        UserDefaults.standard.removeObject(forKey: name)
                    }
                }
            }
            names.forEach(UserDefaults.standard.removeObject(forKey:))
            for name in names {
                try #require(
                    UserDefaults.standard.object(forKey: name) == nil,
                    "\(name) is still set by a lower defaults domain on this device"
                )
            }
            try body()
        }
    }

    private static func storeBar(_ tabs: [String]) throws {
        Defaults[.configuredTabsData] = try JSONEncoder().encode(tabs)
    }

    private static var storedBar: [AppFeature]? {
        AppState.decodeConfiguredTabs(Defaults[.configuredTabsData])
    }

    @Test func aBarWithRoomGetsLibraryLeftOfMoreOnce() async throws {
        try await Self.withRealMigrationKeys {
            try Self.storeBar(["home", "classTable", "calendar"])

            #expect(LibraryTabAddMigration.runIfNeeded())
            #expect(Self.storedBar == [.home, .classTable, .calendar, .library])
            #expect(UserDefaults.standard.bool(forKey: doneKey))

            // Once done, a bar changed afterwards stays as the user left it.
            try Self.storeBar(["home", "gpa"])
            #expect(!LibraryTabAddMigration.runIfNeeded())
            #expect(Self.storedBar == [.home, .gpa])
        }
    }

    /// Turning the library on pinned it, so a bar without it is one the user changed since.
    @Test func aBarOfAUserWhoHadTheLibraryOnStays() async throws {
        try await Self.withRealMigrationKeys {
            try Self.storeBar(["home", "gpa"])
            UserDefaults.standard.set(true, forKey: libraryOptInKey)

            #expect(!LibraryTabAddMigration.runIfNeeded())
            #expect(Self.storedBar == [.home, .gpa])
            #expect(UserDefaults.standard.object(forKey: libraryOptInKey) == nil)
        }
    }

    @Test func theOldSwitchIsDeletedWhenItWasOff() async throws {
        try await Self.withRealMigrationKeys {
            try Self.storeBar(["home", "gpa"])
            UserDefaults.standard.set(false, forKey: libraryOptInKey)

            #expect(LibraryTabAddMigration.runIfNeeded())
            #expect(Self.storedBar == [.home, .gpa, .library])
            #expect(UserDefaults.standard.object(forKey: libraryOptInKey) == nil)
        }
    }

    /// A bar never changed is not stored, and the default it reads already has Library.
    @Test func anUntouchedBarStoresNothing() async throws {
        try await Self.withRealMigrationKeys {
            #expect(!LibraryTabAddMigration.runIfNeeded())
            #expect(Defaults[.configuredTabsData] == nil)
            #expect(UserDefaults.standard.bool(forKey: doneKey))
            #expect(AppFeature.defaultTabs.last == .library)
        }
    }

    @Test func aFullBarOrOneWithLibraryStays() {
        #expect(LibraryTabAddMigration.tabsAddingLibrary(to: [.home, .classTable, .schoolMail, .gpa]) == nil)
        #expect(LibraryTabAddMigration.tabsAddingLibrary(to: [.library, .home]) == nil)
        #expect(LibraryTabAddMigration.tabsAddingLibrary(to: [.home, .gpa]) == [.home, .gpa, .library])
    }
}
#endif
