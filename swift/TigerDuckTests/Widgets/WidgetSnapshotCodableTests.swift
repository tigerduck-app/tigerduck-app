import Foundation
import Testing
@testable import TigerDuck

struct WidgetSnapshotCodableTests {
    // Anchor class so Bundle(for:) can locate the test bundle.
    // Swift Testing structs cannot themselves be Bundle anchors.
    private final class FixtureBundleAnchor {}

    @Test func roundTrip_preservesAllFields() throws {
        let snapshot = WidgetSnapshot(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isLoggedIn: true,
            accentColorHex: 0x007AFF,
            courses: [
                SnapshotCourse(
                    courseNo: "EC1013701",
                    displayName: "資料結構",
                    classroom: "TR-313",
                    schedule: [1: ["B", "C"], 3: ["D"]],
                    colorHex: 0xFF6B6B
                ),
            ],
            periodTimes: ["B": PeriodTime(start: "09:10", end: "10:00"),
                          "C": PeriodTime(start: "10:20", end: "11:10"),
                          "D": PeriodTime(start: "11:20", end: "12:10")],
            periodOrder: ["A", "B", "C", "D"],
            activeWeekdays: [1, 3, 5],
            activePeriodIds: ["B", "C", "D"]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        #expect(decoded.version == snapshot.version)
        #expect(decoded.isLoggedIn == snapshot.isLoggedIn)
        #expect(decoded.accentColorHex == snapshot.accentColorHex)
        #expect(decoded.courses.count == 1)
        #expect(decoded.courses[0].displayName == "資料結構")
        #expect(decoded.courses[0].schedule[1] == ["B", "C"])
        #expect(decoded.periodTimes["B"]?.start == "09:10")
        #expect(decoded.activeWeekdays == [1, 3, 5])
    }

    @Test func decodesFrozenV1Fixture() throws {
        let data = try Self.loadFixtureData(name: "WidgetSnapshot-v1", ext: "json")
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(snapshot.version == 1)
        #expect(!snapshot.courses.isEmpty)
    }

    /// Tries the test bundle first (works under Xcode when the fixture is added
    /// as a Copy Bundle Resources entry on the test target), then falls back to
    /// repo-relative paths for `swift test` / direct CLI runs.
    private static func loadFixtureData(name: String, ext: String) throws -> Data {
        let bundle = Bundle(for: FixtureBundleAnchor.self)
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext) {
            return try Data(contentsOf: url)
        }
        let cwdCandidates = [
            "swift/TigerDuckTests/Widgets/Fixtures/\(name).\(ext)",
            "TigerDuckTests/Widgets/Fixtures/\(name).\(ext)",
            "../TigerDuckTests/Widgets/Fixtures/\(name).\(ext)",
        ]
        for path in cwdCandidates where FileManager.default.fileExists(atPath: path) {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        throw NSError(
            domain: "WidgetSnapshotCodableTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Fixture \(name).\(ext) not found in test bundle (subdirectory=Fixtures or top-level) nor at CWD-relative paths. " +
                "Verify the fixture is added to TigerDuckTests target's Copy Bundle Resources phase."]
        )
    }
}
