import Testing
import Foundation
@testable import TigerDuck

struct ClockOverrideTests {
    @Test func roundTripsThroughJSON() throws {
        let original = ClockOverride(
            instant: Date(timeIntervalSince1970: 1_700_000_000),
            frozen: true,
            savedAtReal: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClockOverride.self, from: data)
        #expect(decoded == original)
    }

    @Test func equatableHonorsAllFields() {
        let a = ClockOverride(
            instant: Date(timeIntervalSince1970: 1),
            frozen: true,
            savedAtReal: Date(timeIntervalSince1970: 2)
        )
        let b = ClockOverride(
            instant: Date(timeIntervalSince1970: 1),
            frozen: true,
            savedAtReal: Date(timeIntervalSince1970: 2)
        )
        let c = ClockOverride(
            instant: Date(timeIntervalSince1970: 1),
            frozen: false,
            savedAtReal: Date(timeIntervalSince1970: 2)
        )
        #expect(a == b)
        #expect(a != c)
    }
}
