import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ViewMemoTests {
    @Test func buildsOncePerKey() {
        let memo = ViewMemo<Int, String>()
        var builds = 0
        let build: () -> String = {
            builds += 1
            return "built \(builds)"
        }

        #expect(memo.value(for: 1, build: build) == "built 1")
        #expect(memo.value(for: 1, build: build) == "built 1")
        #expect(builds == 1)

        #expect(memo.value(for: 2, build: build) == "built 2")
        #expect(memo.value(for: 1, build: build) == "built 3")
        #expect(builds == 3)
    }
}
