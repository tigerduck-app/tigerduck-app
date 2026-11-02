import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ClubSubscriptionsTests {
    private static func reset() {
        Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
    }

    private static func clock(_ start: TimeInterval = 1_793_620_800) -> () -> Date {
        var now = start
        return {
            now += 60
            return Date(timeIntervalSince1970: now)
        }
    }

    @Test("a change is saved for its sign-in, marked unsent and handed to the sync")
    func changesAreSavedAndSent() async {
        await withExclusiveRealDefaults {
            Self.reset()
            defer { Self.reset() }
            let store = ClubSubscriptions(now: Self.clock())
            var sent = 0
            store.onChange = { sent += 1 }

            store.subscribe(93, for: testSignIn)
            store.subscribe(33, for: testSignIn)
            store.subscribe(33, for: testSignIn)
            store.move(fromOffsets: [1], toOffset: 0, for: testSignIn)
            store.setColor(0x123456, of: 93, for: testSignIn)

            #expect(sent == 4)
            #expect(store.hasUnsentChanges)
            #expect(store.subscribedIDs == [33, 93])
            #expect(store.color(of: 93) == 0x123456)
            #expect(store.color(of: 33) == 0xC0392B)
            #expect(store.color(of: 41) == 0x1ABC9C)
            #expect(ClubSubscriptions(now: Self.clock()).document == store.document)
        }
    }

    @Test("a change for a sign-in that ended writes nothing and sends nothing")
    func endedSignInWritesNothing() async {
        await withExclusiveRealDefaults {
            Self.reset()
            defer { Self.reset() }
            let store = ClubSubscriptions(now: Self.clock())
            var sent = 0
            store.onChange = { sent += 1 }

            store.subscribe(93, for: endedTestSignIn)
            store.adopt(ClubSubscriptionsDocument(clubs: [41: .init(subscribed: .init(value: true, at: .init(Date())))]), for: endedTestSignIn)

            #expect(sent == 0)
            #expect(!store.hasSubscriptions)
            #expect(!store.hasUnsentChanges)
            #expect(Defaults[.clubSubscriptions] == nil)
        }
    }

    @Test("adopting the server's copy keeps a change made since, and clears the mark only once nothing is left")
    func adoptKeepsLaterChanges() async {
        await withExclusiveRealDefaults {
            Self.reset()
            defer { Self.reset() }
            let store = ClubSubscriptions(now: Self.clock())
            store.subscribe(93, for: testSignIn)
            let sent = store.document
            store.subscribe(33, for: testSignIn)

            store.adopt(sent, for: testSignIn)
            #expect(store.subscribedIDs == [93, 33])
            #expect(store.hasUnsentChanges)

            store.adopt(store.document, for: testSignIn)
            #expect(!store.hasUnsentChanges)
        }
    }

    @Test("signing out forgets the subscriptions, their colors and the unsent mark")
    func signOutForgets() async {
        await withExclusiveRealDefaults {
            Self.reset()
            defer { Self.reset() }
            ClubSubscriptions.shared.subscribe(93, for: AccountSession.school.signIns.currentSignIn)
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }

            ClubSubscriptions.forgetAccount(in: AccountStorage(folders: CacheFolders(root: root)))

            #expect(Defaults[.clubSubscriptions] == nil)
            #expect(!Defaults[.clubSubscriptionsPushPending])
            #expect(ClubSubscriptions.shared.document == ClubSubscriptionsDocument())
            #expect(SignOutPlan.schoolStores.contains { ObjectIdentifier($0) == ObjectIdentifier(ClubSubscriptions.self) })
        }
    }
}
