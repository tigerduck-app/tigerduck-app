import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct WidgetNextClassTests {
    private typealias Fixtures = WidgetFixtures

    private func state(at hour: Int, _ minute: Int) -> (WidgetDerivedState, WidgetDerivedState.NextInfo?) {
        let now = Fixtures.wednesday(hour, minute)
        let snapshot = Fixtures.snapshot()
        let derived = WidgetTimelineDerivation.derive(snapshot: snapshot, at: now)
        return (derived, WidgetTimelineDerivation.upNext(snapshot: snapshot, at: now, after: derived))
    }

    @Test func duringAClassTheNextOneComesWithIt() throws {
        let (derived, upNext) = state(at: 11, 32)
        guard case .ongoing(let infos) = derived else { Issue.record("\(derived)"); return }
        #expect(infos.map(\.course.displayName) == ["資料結構與演算法"])
        let next = try #require(upNext)
        #expect(next.course.displayName == "計算機網路概論")
        #expect(next.classroom == "IB-505")
        #expect((next.startTime, next.endTime) == ("13:20", "15:10"))
    }

    @Test func betweenClassesTheNextOneLeadsAndTheOneAfterFollows() throws {
        let (derived, upNext) = state(at: 12, 40)
        guard case .nextToday(let info) = derived else { Issue.record("\(derived)"); return }
        #expect(info.course.displayName == "計算機網路概論")
        #expect((info.startTime, info.endTime) == ("13:20", "15:10"))
        #expect(upNext?.course.displayName == "體育－羽球")
        #expect(upNext?.startTime == "15:30")
    }

    @Test func theDaysLastClassHasNothingAfterIt() {
        #expect(state(at: 16, 40).1 == nil)
        #expect(state(at: 16, 0).1?.course.displayName == "通識：科技、社會與永續發展導論")
    }

    @Test func tomorrowsFirstClassComesAlone() {
        let (derived, upNext) = state(at: 18, 0)
        guard case .tomorrowFirst(let info) = derived else { Issue.record("\(derived)"); return }
        #expect(info.course.displayName == "線性代數")
        #expect(upNext == nil)
    }
}
