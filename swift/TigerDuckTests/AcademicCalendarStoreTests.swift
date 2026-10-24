import Defaults
import Foundation
import Testing

@testable import TigerDuck

@MainActor
@Suite("Academic calendar store")
struct AcademicCalendarStoreTests {

    private static func day(_ text: String) -> Date {
        AcademicCalendar.day(from: text)!
    }

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
        Defaults[.academicCalendarETag] = "W/\"rev-7\""

        let store = AcademicCalendarStore()
        #expect(store.calendar.revision == 7)

        store.forgetCachedCalendar()

        #expect(store.calendar == .empty)
        #expect(Defaults[.academicCalendarETag].isEmpty)
        #expect(Defaults[.academicCalendarCache].isEmpty)
    }

    @Test("the cached calendar follows each newly stored calendar")
    func cachedFollowsStoredData() throws {
        let savedCache = Defaults[.academicCalendarCache]
        defer { Defaults[.academicCalendarCache] = savedCache }

        let first = AcademicCalendar(revision: 1, terms: [], holidays: [])
        let second = AcademicCalendar(
            revision: 2,
            terms: [SemesterTerm(code: "1151", start: Self.day("2026-09-07"), end: Self.day("2027-01-17"))],
            holidays: []
        )
        Defaults[.academicCalendarCache] = try JSONEncoder().encode(first)
        #expect(AcademicCalendar.cached == first)
        #expect(AcademicCalendar.cached == first)

        Defaults[.academicCalendarCache] = try JSONEncoder().encode(second)
        #expect(AcademicCalendar.cached == second)

        Defaults[.academicCalendarCache] = Data()
        #expect(AcademicCalendar.cached == .empty)
    }

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

            store.setNotify(true, forHoliday: 9)
            store.beginHolidayUpload()
            store.applySyncedOverrides([1, 2], fetchedAt: Date().addingTimeInterval(1))
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 2, 9])

            store.endHolidayUpload()
            store.applySyncedOverrides([1, 2, 9], fetchedAt: Date().addingTimeInterval(1))
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 2, 9])
        }
    }

    @Test("a snapshot that matches the local set reports no change, so the sync posts none")
    func unchangedSnapshotReportsNoChange() {
        Self.withCleanHolidayDefaults {
            let store = AcademicCalendarStore()
            #expect(store.applySyncedOverrides([1, 2], fetchedAt: Date()))
            #expect(!store.applySyncedOverrides([2, 1], fetchedAt: Date().addingTimeInterval(1)))
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 2])
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

            store.setNotify(true, forHoliday: 9)
            store.setHolidayAcknowledged(false, holidayID: 9)
            store.setNotify(false, forHoliday: 5)
            store.setHolidayAcknowledged(false, holidayID: 5)

            store.applySyncedOverrides([1, 5], fetchedAt: Date().addingTimeInterval(1))
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 9])

            store.setHolidayAcknowledged(true, holidayID: 9)
            store.setHolidayAcknowledged(true, holidayID: 5)
            store.applySyncedOverrides([1, 5], fetchedAt: Date().addingTimeInterval(2))
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 5])
        }
    }

    @Test("logging out leaves no holiday state for the next account")
    func forgetHolidayOverridesClearsBothSets() {
        Self.withCleanHolidayDefaults {
            let store = AcademicCalendarStore()
            store.setNotify(true, forHoliday: 9)
            store.setHolidayAcknowledged(false, holidayID: 9)
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [9])
            #expect(store.unacknowledgedHolidayIDs == [9])

            store.forgetHolidayOverrides()

            #expect(Defaults[.holidayNotifyOverrides].isEmpty)
            #expect(store.unacknowledgedHolidayIDs.isEmpty)
            store.applySyncedOverrides([2], fetchedAt: Date.distantPast.addingTimeInterval(1))
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [2])
        }
    }

    @Test("the pending count never goes negative")
    func pendingCountFloors() {
        Self.withCleanHolidayDefaults {
            let store = AcademicCalendarStore()
            store.endHolidayUpload()
            store.endHolidayUpload()
            store.applySyncedOverrides([4], fetchedAt: Date())
            #expect(Set(Defaults[.holidayNotifyOverrides]) == [4])
        }
    }

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
        #expect(!calendar.suppressesClasses(on: Self.day("2027-02-07"), optedIn: [3]))
    }
}
