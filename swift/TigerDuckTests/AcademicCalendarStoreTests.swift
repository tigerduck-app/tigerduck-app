import Defaults
import Foundation
import Testing

@testable import TigerDuck

/// Ways the calendar could end up describing a school the app is not talking
/// to any more, or a holiday preference the user did not choose.
@MainActor
@Suite("Academic calendar store")
struct AcademicCalendarStoreTests {

    private static func day(_ text: String) -> Date {
        AcademicCalendar.day(from: text)!
    }

    // MARK: - Endpoint changes

    @Test("changing the endpoint drops the previous backend's calendar and ETag")
    func endpointChangeForgetsCalendar() {
        let savedCache = Defaults[.academicCalendarCache]
        let savedTag = Defaults[.academicCalendarETag]
        defer {
            Defaults[.academicCalendarCache] = savedCache
            Defaults[.academicCalendarETag] = savedTag
        }

        let calendar = AcademicCalendar(
            revision: 7,
            terms: [],
            holidays: [
                Holiday(
                    id: 1,
                    nameZh: "中秋節",
                    nameEn: "Mid-Autumn Festival",
                    start: Self.day("2026-09-25"),
                    end: Self.day("2026-09-25")
                )
            ]
        )
        Defaults[.academicCalendarCache] = try! JSONEncoder().encode(calendar)
        // Opaque, and nothing in it says which backend issued it — which is
        // the whole reason it cannot be carried across an endpoint change.
        Defaults[.academicCalendarETag] = "W/\"rev-7\""

        let store = AcademicCalendarStore()
        #expect(store.calendar.revision == 7)

        store.forgetCachedCalendar()

        #expect(store.calendar == .empty)
        #expect(Defaults[.academicCalendarETag].isEmpty)
        #expect(Defaults[.academicCalendarCache].isEmpty)
    }

    // MARK: - Holiday overrides

    /// Both holiday keys, restored afterwards, and cleared going in so one
    /// test's leftovers cannot decide another's outcome.
    private static func withCleanHolidayDefaults(_ body: () -> Void) {
        let savedOverrides = Defaults[.holidayNotifyOverrides]
        let savedAwaiting = Defaults[.holidayOverridesAwaitingUpload]
        defer {
            Defaults[.holidayNotifyOverrides] = savedOverrides
            Defaults[.holidayOverridesAwaitingUpload] = savedAwaiting
        }
        Defaults[.holidayNotifyOverrides] = []
        Defaults[.holidayOverridesAwaitingUpload] = []
        body()
    }

    @Test("a sync snapshot arriving mid-upload does not overwrite the local set")
    func syncedOverridesDeferToPendingUpload() {
        Self.withCleanHolidayDefaults {
            let store = AcademicCalendarStore()
            store.applySyncedOverrides([1, 2], fetchedAt: Date())
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 2])

            // The user taps holiday 9 on, and its upload is still in flight.
            // The snapshot below was fetched *after* the tap, so its timestamp
            // is no help — only the pending count knows the server has not
            // heard yet.
            store.setNotify(true, forHoliday: 9)
            store.beginHolidayUpload()
            store.applySyncedOverrides([1, 2], fetchedAt: Date().addingTimeInterval(1))
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 2, 9])

            // Once it lands, the server is the authority again.
            store.endHolidayUpload()
            store.applySyncedOverrides([1, 2, 9], fetchedAt: Date().addingTimeInterval(1))
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 2, 9])
        }
    }

    @Test("a snapshot older than the local edit is ignored even once the upload lands")
    func staleSnapshotIgnoredAfterUpload() {
        Self.withCleanHolidayDefaults {
            let store = AcademicCalendarStore()
            let fetchedBeforeTap = Date()
            store.applySyncedOverrides([1], fetchedAt: fetchedBeforeTap)
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1])

            store.setNotify(true, forHoliday: 9)
            store.beginHolidayUpload()
            store.endHolidayUpload()

            // The upload has landed, so the pending count is zero — but this
            // response left the server before the tap and cannot know about it.
            store.applySyncedOverrides([1], fetchedAt: fetchedBeforeTap)
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 9])
        }
    }

    @Test("a toggle the server never acknowledged outlives the sync snapshot")
    func unacknowledgedToggleSurvivesSync() {
        Self.withCleanHolidayDefaults {
            let store = AcademicCalendarStore()
            store.applySyncedOverrides([1, 5], fetchedAt: Date())
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 5])

            // 9 turned on and 5 turned off, both uploads failed, so neither
            // is acknowledged and the server still reports the old set.
            store.setNotify(true, forHoliday: 9)
            store.setHolidayAcknowledged(false, holidayID: 9)
            store.setNotify(false, forHoliday: 5)
            store.setHolidayAcknowledged(false, holidayID: 5)

            store.applySyncedOverrides([1, 5], fetchedAt: Date().addingTimeInterval(1))
            // Both local edits stand, in both directions, and holiday 1 —
            // which this device never touched — still comes from the server.
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 9])

            // Once the retry lands, the server's word wins again.
            store.setHolidayAcknowledged(true, holidayID: 9)
            store.setHolidayAcknowledged(true, holidayID: 5)
            store.applySyncedOverrides([1, 5], fetchedAt: Date().addingTimeInterval(2))
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 5])
        }
    }

    @Test("the pending count never goes negative")
    func pendingCountFloors() {
        Self.withCleanHolidayDefaults {
            let store = AcademicCalendarStore()
            store.endHolidayUpload()
            store.endHolidayUpload()
            // Still applying: an unbalanced end must not latch the guard on
            // and leave the device ignoring the server forever.
            store.applySyncedOverrides([4], fetchedAt: Date())
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [4])
        }
    }

    // MARK: - Multi-day holidays

    @Test("every day of a multi-day holiday suppresses classes")
    func multiDayHolidaySuppressesThroughout() {
        let calendar = AcademicCalendar(
            revision: 1,
            terms: [],
            holidays: [
                Holiday(
                    id: 3,
                    nameZh: "春節",
                    nameEn: "Lunar New Year",
                    start: Self.day("2027-02-05"),
                    end: Self.day("2027-02-09")
                )
            ]
        )
        for date in ["2027-02-05", "2027-02-07", "2027-02-09"] {
            #expect(calendar.suppressesClasses(on: Self.day(date), optedIn: []))
        }
        #expect(!calendar.suppressesClasses(on: Self.day("2027-02-10"), optedIn: []))
        // Opting in is per holiday, not per day: the whole span goes loud.
        #expect(!calendar.suppressesClasses(on: Self.day("2027-02-07"), optedIn: [3]))
    }
}
