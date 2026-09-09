import Defaults
import Foundation
import Testing

@testable import TigerDuck

/// Two ways the calendar could end up describing a school it is not talking
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

    @Test("a sync snapshot arriving mid-upload does not overwrite the local set")
    func syncedOverridesDeferToPendingUpload() {
        let saved = Defaults[.holidayNotifyOverrides]
        defer { Defaults[.holidayNotifyOverrides] = saved }

        let store = AcademicCalendarStore()
        store.applySyncedOverrides([1, 2])
        #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 2])

        // The user taps holiday 9 on. Its upload is in flight when a sync
        // response fetched *before* the tap arrives carrying the old set.
        store.setNotify(true, forHoliday: 9)
        store.beginHolidayUpload()
        store.applySyncedOverrides([1, 2])
        #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 2, 9])

        // Once it lands, the server is the authority again.
        store.endHolidayUpload()
        store.applySyncedOverrides([1, 2, 9])
        #expect(Set(Defaults[.holidayNotifyOverrides]) == [1, 2, 9])
    }

    @Test("the pending count never goes negative")
    func pendingCountFloors() {
        let saved = Defaults[.holidayNotifyOverrides]
        defer { Defaults[.holidayNotifyOverrides] = saved }

        let store = AcademicCalendarStore()
        store.endHolidayUpload()
        store.endHolidayUpload()
        // Still applying: an unbalanced end must not latch the guard on and
        // leave the device ignoring the server forever.
        store.applySyncedOverrides([4])
        #expect(Set(Defaults[.holidayNotifyOverrides]) == [4])
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
