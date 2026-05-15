import Foundation
import Testing
@testable import TigerDuck

struct WidgetSnapshotCodableTests {
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
        // Fixture loading via Bundle is awkward in Swift Testing without a class
        // owning the Bundle. Read directly from disk via the working directory
        // (xcodebuild runs from the project root). This is fragile to test
        // working-directory changes but mirrors the plan's fallback path.
        let candidatePaths = [
            "swift/TigerDuckTests/Widgets/Fixtures/WidgetSnapshot-v1.json",
            "TigerDuckTests/Widgets/Fixtures/WidgetSnapshot-v1.json",
            "../TigerDuckTests/Widgets/Fixtures/WidgetSnapshot-v1.json",
        ]
        var data: Data?
        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
                break
            }
        }
        // If working directory tricks fail, also try Bundle.module / Bundle(for:)
        if data == nil {
            // Intentionally let this throw with a clear file-not-found if needed;
            // the user will add the fixture to the TigerDuckTests target's
            // resources in Xcode and rerun.
            throw NSError(domain: "WidgetSnapshotCodableTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Fixture not found in any candidate path; ensure WidgetSnapshot-v1.json is added to TigerDuckTests target as a resource."])
        }

        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data!)
        #expect(snapshot.version == 1)
        #expect(!snapshot.courses.isEmpty)
    }
}
