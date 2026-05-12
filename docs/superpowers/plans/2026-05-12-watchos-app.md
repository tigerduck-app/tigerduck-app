# watchOS App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a companion watchOS app for TigerDuck mirroring the Android Wear module — three SwiftUI screens (NowNext / Today / Settings) plus a WidgetKit widget for the watch face and Smart Stack, all driven by data pushed from the iPhone over WatchConnectivity.

**Architecture:** Companion-only — the watch never authenticates and never hits the backend. The iPhone owns auth and data; a `WatchSyncCoordinator` on the phone observes `SDCourse` / accent-color / language / login state, serialises to a flat `WatchCourse` DTO, and pushes via `WCSession.updateApplicationContext`. The watch decodes, caches to a shared App Group file, and renders. The widget extension reads the same App Group file — never opens WC, never touches the network.

**Tech Stack:**
- SwiftUI (watchOS 11 minimum), WatchConnectivity, WidgetKit
- App Group `group.tw.smashit.tigerduck.watch`
- XCTest for unit tests; ImageRenderer for widget snapshot tests

**Prerequisites:**
- macOS 15 (Sequoia) or newer
- Xcode 16 or newer (ships watchOS 11 SDK)
- Apple Developer Program team able to register the App Group capability
- Paired iOS + watchOS simulators (`Window → Devices and Simulators → Pair`)
- Branch: `feat/watchos` (already created off `dev`)
- Spec: `docs/superpowers/specs/2026-05-12-watchos-app-design.md` — read it first

**Important constraints:**
- Source files can be created on any platform; everything that adds Xcode targets, builds, runs tests, or installs to simulators requires macOS. Steps that need macOS are flagged with **[MAC-ONLY]**.
- Never bypass git hooks. Never commit with `--no-verify` or `--no-gpg-sign`.
- Per global preference: **do not add `Co-Authored-By: Claude` trailers** to any commit in this plan.

---

## File structure

### Created files

```
swift/Shared/Watch/                       # multi-target membership: TigerDuck + TigerDuckWatch
├── WatchCourse.swift                     # DTO (Codable)
├── WatchSnapshot.swift                   # envelope: courses + accent + syncedAt + loggedIn + lang
├── WatchWireFormat.swift                 # key constants + protocol version
└── NextClassResolver.swift               # pure function: given [WatchCourse]+Date → (current, next)

swift/TigerDuck/Services/Watch/           # phone-only
├── WatchPayloadEncoder.swift             # [SDCourse] → [WatchCourse] → applicationContext dict
└── WatchSyncCoordinator.swift            # WCSession delegate; debounce; respond to syncRequest

swift/TigerDuckWatch/                     # new Watch App target
├── TigerDuckWatchApp.swift               # @main App entry; activates WCSession
├── Info.plist
├── TigerDuckWatch.entitlements           # App Group
├── Assets.xcassets/                      # AppIcon + AccentColor placeholder
├── Services/
│   ├── ScheduleStore.swift               # ObservableObject; WCSession delegate
│   ├── SharedAppGroup.swift              # URL + UserDefaults helpers
│   ├── WatchPayloadDecoder.swift         # dict → WatchSnapshot
│   └── WatchAppLogger.swift              # os.Logger wrapper
├── UI/
│   ├── WatchRootView.swift               # TabView .page root
│   ├── NowNextView.swift
│   ├── TodayView.swift
│   ├── CourseDetailView.swift
│   ├── SettingsView.swift
│   └── WatchTheme.swift                  # accent color + locale modifier
└── PreviewContent/
    └── PreviewSnapshot.swift             # sample WatchSnapshot for #Preview

swift/TigerDuckWatchWidget/               # new Widget Extension target
├── TigerDuckWatchWidgetBundle.swift      # @main WidgetBundle
├── Info.plist
├── TigerDuckWatchWidget.entitlements     # App Group
├── Assets.xcassets/                      # WidgetBackground colour set
├── NextClassWidget.swift                 # Widget config + supportedFamilies
├── NextClassProvider.swift               # TimelineProvider
├── NextClassEntry.swift                  # TimelineEntry struct
└── Views/
    ├── CircularView.swift
    ├── CornerView.swift
    ├── InlineView.swift
    └── RectangularView.swift

swift/TigerDuckWatchTests/                # new XCTest target
├── WatchPayloadCodecTests.swift
├── NextClassResolverTests.swift
└── ScheduleStoreTests.swift

swift/TigerDuckTests/Watch/               # added under existing phone tests
├── WatchPayloadEncoderTests.swift
└── WatchSyncCoordinatorTests.swift

swift/TigerDuckWatchWidgetTests/          # new XCTest target — widget snapshots
└── NextClassWidgetSnapshotTests.swift

localization/source/watch.json            # new shared-translation source file (or merge into existing shared.json)

docs/superpowers/plans/2026-05-12-watchos-app.md  # this file
```

### Modified files

```
swift/TigerDuck/App/TigerDuckApp.swift           # instantiate + hold WatchSyncCoordinator
swift/TigerDuck.xcodeproj/project.pbxproj        # 3 new targets + shared file memberships + scheme
```

---

## Task 1: Verify branch + create directory skeletons

**Files:**
- Create directories: `swift/Shared/Watch/`, `swift/TigerDuck/Services/Watch/`, `swift/TigerDuckWatch/`, `swift/TigerDuckWatchWidget/`, `swift/TigerDuckWatchTests/`, `swift/TigerDuckWatchWidgetTests/`

- [ ] **Step 1: Verify branch and clean tree**

```bash
git rev-parse --abbrev-ref HEAD
git status
```

Expected: `feat/watchos`, working tree clean.

- [ ] **Step 2: Create directory skeleton**

```bash
mkdir -p swift/Shared/Watch
mkdir -p swift/TigerDuck/Services/Watch
mkdir -p swift/TigerDuckWatch/{Services,UI,PreviewContent}
mkdir -p swift/TigerDuckWatchWidget/Views
mkdir -p swift/TigerDuckWatchTests
mkdir -p swift/TigerDuckTests/Watch
mkdir -p swift/TigerDuckWatchWidgetTests
```

- [ ] **Step 3: Add a `.gitkeep` to each new directory so they're committable empty**

```bash
touch swift/Shared/Watch/.gitkeep
touch swift/TigerDuck/Services/Watch/.gitkeep
touch swift/TigerDuckWatch/.gitkeep
touch swift/TigerDuckWatch/Services/.gitkeep
touch swift/TigerDuckWatch/UI/.gitkeep
touch swift/TigerDuckWatch/PreviewContent/.gitkeep
touch swift/TigerDuckWatchWidget/.gitkeep
touch swift/TigerDuckWatchWidget/Views/.gitkeep
touch swift/TigerDuckWatchTests/.gitkeep
touch swift/TigerDuckTests/Watch/.gitkeep
touch swift/TigerDuckWatchWidgetTests/.gitkeep
```

- [ ] **Step 4: Commit**

```bash
git add swift/Shared swift/TigerDuck/Services/Watch swift/TigerDuckWatch swift/TigerDuckWatchWidget swift/TigerDuckWatchTests swift/TigerDuckTests/Watch swift/TigerDuckWatchWidgetTests
git commit -m "chore(watch): scaffold directories for watchOS app + widget"
```

---

## Task 2: Shared `WatchCourse` DTO

**Files:**
- Create: `swift/Shared/Watch/WatchCourse.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// One concrete weekly session of a course on the watch. A class that meets
/// twice a week is serialised as two `WatchCourse` rows — the watch never has
/// to expand multi-weekday schedules itself.
///
/// Wire-format DTO. Decoupled from `SDCourse` so phone-side schema churn does
/// not ripple to the watch unless this struct's fields change.
public struct WatchCourse: Codable, Hashable, Identifiable, Sendable {
    public let id: String         // "<courseNo>-<weekday>-<firstPeriod>"
    public let courseNo: String
    public let name: String
    public let teacher: String
    public let classroom: String
    public let colorHex: String   // "#RRGGBB"
    public let weekday: Int       // 1 = Mon … 7 = Sun (ISO)
    public let startHHmm: String  // first-period start, e.g. "10:20"
    public let endHHmm: String    // last-period end, e.g. "11:10"
    public let periodLabel: String // human-readable e.g. "3-4" or "A"

    public init(
        id: String,
        courseNo: String,
        name: String,
        teacher: String,
        classroom: String,
        colorHex: String,
        weekday: Int,
        startHHmm: String,
        endHHmm: String,
        periodLabel: String
    ) {
        self.id = id
        self.courseNo = courseNo
        self.name = name
        self.teacher = teacher
        self.classroom = classroom
        self.colorHex = colorHex
        self.weekday = weekday
        self.startHHmm = startHHmm
        self.endHHmm = endHHmm
        self.periodLabel = periodLabel
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add swift/Shared/Watch/WatchCourse.swift
git commit -m "feat(watch): add WatchCourse DTO"
```

---

## Task 3: Shared `WatchSnapshot` envelope + `WatchWireFormat` keys

**Files:**
- Create: `swift/Shared/Watch/WatchSnapshot.swift`, `swift/Shared/Watch/WatchWireFormat.swift`

- [ ] **Step 1: Write `WatchWireFormat.swift`**

```swift
import Foundation

/// Key constants for the WatchConnectivity applicationContext payload.
/// Bumping `Self.version` indicates an incompatible payload — receivers
/// SHOULD still attempt to decode but MAY discard if unsupported.
public enum WatchWireFormat {
    public static let version = 1

    public enum Key {
        public static let version    = "v"
        public static let courses    = "courses"
        public static let accentHex  = "accentHex"
        public static let syncedAtMs = "syncedAtMs"
        public static let loggedIn   = "loggedIn"
        public static let languageTag = "languageTag"
    }

    public enum MessageKind {
        public static let syncRequest = "syncRequest"
    }

    public enum MessageKey {
        public static let kind = "kind"
    }
}
```

- [ ] **Step 2: Write `WatchSnapshot.swift`**

```swift
import Foundation

/// Decoded watch-side view of one applicationContext push. Lives in the
/// shared App Group file so the widget can read it without WC.
public struct WatchSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let courses: [WatchCourse]
    public let accentHex: String
    public let syncedAtMs: Int64
    public let loggedIn: Bool
    public let languageTag: String?

    public static let defaultAccentHex = "#FF8800"

    public init(
        version: Int = WatchWireFormat.version,
        courses: [WatchCourse],
        accentHex: String,
        syncedAtMs: Int64,
        loggedIn: Bool,
        languageTag: String?
    ) {
        self.version = version
        self.courses = courses
        self.accentHex = accentHex
        self.syncedAtMs = syncedAtMs
        self.loggedIn = loggedIn
        self.languageTag = languageTag
    }

    public var syncedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(syncedAtMs) / 1000.0)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add swift/Shared/Watch/WatchSnapshot.swift swift/Shared/Watch/WatchWireFormat.swift
git commit -m "feat(watch): add WatchSnapshot envelope and wire-format keys"
```

---

## Task 4: `WatchPayloadCodec` round-trip — failing tests first (TDD)

**Files:**
- Create: `swift/TigerDuckWatch/Services/WatchPayloadDecoder.swift`
- Create: `swift/TigerDuckWatchTests/WatchPayloadCodecTests.swift`

The encoder (phone-side) and decoder (watch-side) operate on `[String: Any]` because that's what WatchConnectivity hands us. Both sides go through this codec, so we test them together.

- [ ] **Step 1: Write the failing test file**

```swift
// swift/TigerDuckWatchTests/WatchPayloadCodecTests.swift
import XCTest
@testable import TigerDuckWatch

final class WatchPayloadCodecTests: XCTestCase {

    private func sampleCourse() -> WatchCourse {
        WatchCourse(
            id: "1142EC1013701-1-3",
            courseNo: "1142EC1013701",
            name: "資料結構",
            teacher: "張教授",
            classroom: "TR-313",
            colorHex: "#FF8800",
            weekday: 1,
            startHHmm: "10:20",
            endHHmm: "11:10",
            periodLabel: "3-4"
        )
    }

    private func sampleSnapshot() -> WatchSnapshot {
        WatchSnapshot(
            courses: [sampleCourse()],
            accentHex: "#FF8800",
            syncedAtMs: 1_747_000_000_000,
            loggedIn: true,
            languageTag: "zh-Hant-TW"
        )
    }

    func test_roundTrip_preservesAllFields() throws {
        let snapshot = sampleSnapshot()
        let dict = try WatchPayloadCodec.encode(snapshot)
        let decoded = try WatchPayloadCodec.decode(dict)
        XCTAssertEqual(snapshot, decoded)
    }

    func test_decode_missingOptionalLanguageTag_succeeds() throws {
        var dict = try WatchPayloadCodec.encode(sampleSnapshot())
        dict.removeValue(forKey: WatchWireFormat.Key.languageTag)
        let decoded = try WatchPayloadCodec.decode(dict)
        XCTAssertNil(decoded.languageTag)
    }

    func test_decode_missingRequiredCourses_throws() {
        var dict = try! WatchPayloadCodec.encode(sampleSnapshot())
        dict.removeValue(forKey: WatchWireFormat.Key.courses)
        XCTAssertThrowsError(try WatchPayloadCodec.decode(dict))
    }

    func test_decode_unknownFutureVersion_stillDecodes() throws {
        var dict = try WatchPayloadCodec.encode(sampleSnapshot())
        dict[WatchWireFormat.Key.version] = 99
        let decoded = try WatchPayloadCodec.decode(dict)
        XCTAssertEqual(decoded.courses.count, 1)
        XCTAssertEqual(decoded.version, 99)
    }
}
```

- [ ] **Step 2: [MAC-ONLY] Run tests to verify they fail**

```bash
xcodebuild test \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuckWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' \
  -only-testing:TigerDuckWatchTests/WatchPayloadCodecTests
```

Expected: FAIL — `WatchPayloadCodec` not yet defined.

> If the `TigerDuckWatch` scheme does not yet exist, this command fails earlier. That's fine — Task 7 (add Xcode targets) creates the scheme. Defer running until then. Treat the test file as the "failing test" artefact for now.

- [ ] **Step 3: Implement `WatchPayloadCodec`**

```swift
// swift/TigerDuckWatch/Services/WatchPayloadDecoder.swift
// Lives in the watch target but is symmetrical: the phone uses the
// same encode/decode logic via multi-target membership.
import Foundation

public enum WatchPayloadCodec {

    public enum Error: Swift.Error, Equatable {
        case missingField(String)
        case wrongType(String)
    }

    /// Encode a snapshot for `WCSession.updateApplicationContext`.
    public static func encode(_ snapshot: WatchSnapshot) throws -> [String: Any] {
        let coursesData = try JSONEncoder().encode(snapshot.courses)
        let coursesArray = try JSONSerialization.jsonObject(with: coursesData) as? [[String: Any]]
        guard let courses = coursesArray else {
            throw Error.wrongType(WatchWireFormat.Key.courses)
        }
        var dict: [String: Any] = [
            WatchWireFormat.Key.version: snapshot.version,
            WatchWireFormat.Key.courses: courses,
            WatchWireFormat.Key.accentHex: snapshot.accentHex,
            WatchWireFormat.Key.syncedAtMs: NSNumber(value: snapshot.syncedAtMs),
            WatchWireFormat.Key.loggedIn: snapshot.loggedIn,
        ]
        if let tag = snapshot.languageTag {
            dict[WatchWireFormat.Key.languageTag] = tag
        }
        return dict
    }

    /// Decode an incoming applicationContext into a `WatchSnapshot`.
    public static func decode(_ dict: [String: Any]) throws -> WatchSnapshot {
        guard let coursesAny = dict[WatchWireFormat.Key.courses] else {
            throw Error.missingField(WatchWireFormat.Key.courses)
        }
        guard let coursesArray = coursesAny as? [[String: Any]] else {
            throw Error.wrongType(WatchWireFormat.Key.courses)
        }
        let coursesData = try JSONSerialization.data(withJSONObject: coursesArray)
        let courses = try JSONDecoder().decode([WatchCourse].self, from: coursesData)

        let version = (dict[WatchWireFormat.Key.version] as? Int) ?? WatchWireFormat.version
        let accent = (dict[WatchWireFormat.Key.accentHex] as? String) ?? WatchSnapshot.defaultAccentHex
        let syncedAtMs = (dict[WatchWireFormat.Key.syncedAtMs] as? NSNumber)?.int64Value
            ?? (dict[WatchWireFormat.Key.syncedAtMs] as? Int64)
            ?? 0
        let loggedIn = (dict[WatchWireFormat.Key.loggedIn] as? Bool) ?? false
        let languageTag = dict[WatchWireFormat.Key.languageTag] as? String

        return WatchSnapshot(
            version: version,
            courses: courses,
            accentHex: accent,
            syncedAtMs: syncedAtMs,
            loggedIn: loggedIn,
            languageTag: languageTag
        )
    }
}
```

- [ ] **Step 4: [MAC-ONLY] Re-run tests; expect PASS**

(Skip if scheme not yet created — verify after Task 7.)

- [ ] **Step 5: Commit**

```bash
git add swift/TigerDuckWatch/Services/WatchPayloadDecoder.swift swift/TigerDuckWatchTests/WatchPayloadCodecTests.swift
git commit -m "feat(watch): add WatchPayloadCodec with round-trip tests"
```

---

## Task 5: `NextClassResolver` — failing tests first (TDD)

**Files:**
- Create: `swift/Shared/Watch/NextClassResolver.swift`
- Create: `swift/TigerDuckWatchTests/NextClassResolverTests.swift`

- [ ] **Step 1: Write the failing test file**

```swift
// swift/TigerDuckWatchTests/NextClassResolverTests.swift
import XCTest
@testable import TigerDuckWatch

final class NextClassResolverTests: XCTestCase {

    private func course(_ id: String, weekday: Int, start: String, end: String) -> WatchCourse {
        WatchCourse(
            id: id, courseNo: id, name: id, teacher: "",
            classroom: "", colorHex: "#FF8800",
            weekday: weekday, startHHmm: start, endHHmm: end, periodLabel: ""
        )
    }

    /// Builds a Date for Mon 2026-05-11 at the given HH:mm in the system calendar.
    private func mondayAt(_ hhmm: String) -> Date {
        let comps = hhmm.split(separator: ":").map(String.init)
        var dc = DateComponents()
        dc.year = 2026; dc.month = 5; dc.day = 11
        dc.hour = Int(comps[0]); dc.minute = Int(comps[1])
        return Calendar(identifier: .iso8601).date(from: dc)!
    }

    func test_beforeFirstClass_currentIsNil_nextIsFirst() {
        let c1 = course("A", weekday: 1, start: "10:20", end: "11:10")
        let c2 = course("B", weekday: 1, start: "13:30", end: "14:20")
        let r = NextClassResolver.resolve(courses: [c1, c2], now: mondayAt("09:00"))
        XCTAssertNil(r.current)
        XCTAssertEqual(r.next?.id, "A")
    }

    func test_duringClass_currentIsThat_nextIsAfter() {
        let c1 = course("A", weekday: 1, start: "10:20", end: "11:10")
        let c2 = course("B", weekday: 1, start: "13:30", end: "14:20")
        let r = NextClassResolver.resolve(courses: [c1, c2], now: mondayAt("10:45"))
        XCTAssertEqual(r.current?.id, "A")
        XCTAssertEqual(r.next?.id, "B")
    }

    func test_betweenClasses_currentIsNil_nextIsLater() {
        let c1 = course("A", weekday: 1, start: "10:20", end: "11:10")
        let c2 = course("B", weekday: 1, start: "13:30", end: "14:20")
        let r = NextClassResolver.resolve(courses: [c1, c2], now: mondayAt("12:00"))
        XCTAssertNil(r.current)
        XCTAssertEqual(r.next?.id, "B")
    }

    func test_afterLastClass_bothNil() {
        let c1 = course("A", weekday: 1, start: "10:20", end: "11:10")
        let r = NextClassResolver.resolve(courses: [c1], now: mondayAt("18:00"))
        XCTAssertNil(r.current)
        XCTAssertNil(r.next)
    }

    func test_emptyCourses_bothNil() {
        let r = NextClassResolver.resolve(courses: [], now: mondayAt("10:00"))
        XCTAssertNil(r.current)
        XCTAssertNil(r.next)
    }

    func test_filtersOutOtherWeekdays() {
        let mon = course("A", weekday: 1, start: "10:20", end: "11:10")
        let tue = course("B", weekday: 2, start: "10:20", end: "11:10")
        let r = NextClassResolver.resolve(courses: [mon, tue], now: mondayAt("09:00"))
        XCTAssertEqual(r.next?.id, "A")
    }

    func test_overlappingSessions_picksEarliestEnd() {
        // Defensive: real data shouldn't overlap, but lock the contract.
        let a = course("A", weekday: 1, start: "10:00", end: "11:00")
        let b = course("B", weekday: 1, start: "10:30", end: "11:30")
        let r = NextClassResolver.resolve(courses: [a, b], now: mondayAt("10:45"))
        XCTAssertEqual(r.current?.id, "A")
        XCTAssertEqual(r.next?.id, "B")
    }
}
```

- [ ] **Step 2: Implement `NextClassResolver`**

```swift
// swift/Shared/Watch/NextClassResolver.swift
import Foundation

public enum NextClassResolver {

    public struct Result: Equatable {
        public let current: WatchCourse?
        public let next: WatchCourse?
    }

    /// Given the watch's full course list and the current instant, return
    /// the class currently in progress (if any) and the next class to start
    /// today (if any). Other weekdays are ignored.
    public static func resolve(courses: [WatchCourse], now: Date) -> Result {
        let cal = Calendar(identifier: .iso8601)
        // ISO weekday: Calendar gives 1=Sun..7=Sat; convert to 1=Mon..7=Sun.
        let raw = cal.component(.weekday, from: now)
        let isoWeekday = ((raw + 5) % 7) + 1

        let hh = cal.component(.hour, from: now)
        let mm = cal.component(.minute, from: now)
        let nowMin = hh * 60 + mm

        let today = courses
            .filter { $0.weekday == isoWeekday }
            .sorted { minutes(of: $0.startHHmm) < minutes(of: $1.startHHmm) }

        let current = today.first { c in
            let s = minutes(of: c.startHHmm)
            let e = minutes(of: c.endHHmm)
            return nowMin >= s && nowMin < e
        }

        let next = today.first { c in
            minutes(of: c.startHHmm) > nowMin
        }

        return Result(current: current, next: next)
    }

    private static func minutes(of hhmm: String) -> Int {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return 0 }
        return h * 60 + m
    }
}
```

- [ ] **Step 3: [MAC-ONLY] Run tests; expect PASS**

```bash
xcodebuild test \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuckWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' \
  -only-testing:TigerDuckWatchTests/NextClassResolverTests
```

(Skip until scheme exists.)

- [ ] **Step 4: Commit**

```bash
git add swift/Shared/Watch/NextClassResolver.swift swift/TigerDuckWatchTests/NextClassResolverTests.swift
git commit -m "feat(watch): add NextClassResolver with edge-case coverage"
```

---

## Task 6: `WatchPayloadEncoder` (phone-side) — failing tests first (TDD)

The encoder takes the phone's existing `SDCourse[]` plus a few preference values and produces a `WatchSnapshot`. Flatten multi-weekday schedules to one `WatchCourse` per weekday session. Resolve per-(weekday, period) classrooms via `SDCourse.classroomMap`. Resolve period IDs to HH:mm using `TimetablePeriod.byId`.

**Files:**
- Create: `swift/TigerDuck/Services/Watch/WatchPayloadEncoder.swift`
- Create: `swift/TigerDuckTests/Watch/WatchPayloadEncoderTests.swift`

- [ ] **Step 1: Write the failing test file**

```swift
// swift/TigerDuckTests/Watch/WatchPayloadEncoderTests.swift
import XCTest
import SwiftData
@testable import TigerDuck

final class WatchPayloadEncoderTests: XCTestCase {

    private func makeCourse(
        no: String = "1142EC1013701",
        name: String = "資料結構",
        instructor: String = "張教授",
        classroom: String = "TR-313",
        schedule: [Int: [String]] = [1: ["3", "4"]],
        classroomMap: [String: String] = [:]
    ) -> SDCourse {
        SDCourse(
            courseNo: no,
            courseName: name,
            instructor: instructor,
            classroom: classroom,
            schedule: schedule,
            classroomMap: classroomMap
        )
    }

    func test_flattensMultiWeekday() {
        let c = makeCourse(schedule: [1: ["3", "4"], 4: ["6", "7"]])
        let snap = WatchPayloadEncoder.encode(
            courses: [c],
            accentHex: "#FF8800",
            syncedAt: Date(timeIntervalSince1970: 1_747_000_000),
            loggedIn: true,
            languageTag: "zh-Hant-TW"
        )
        XCTAssertEqual(snap.courses.count, 2)
        XCTAssertTrue(snap.courses.contains { $0.weekday == 1 && $0.periodLabel == "3-4" })
        XCTAssertTrue(snap.courses.contains { $0.weekday == 4 && $0.periodLabel == "6-7" })
    }

    func test_perWeekdayClassroomOverridesDefault() {
        let c = makeCourse(
            classroom: "TR-313",
            schedule: [1: ["3", "4"]],
            classroomMap: ["1-3": "TR-409", "1-4": "TR-409"]
        )
        let snap = WatchPayloadEncoder.encode(
            courses: [c], accentHex: "#000000",
            syncedAt: Date(), loggedIn: true, languageTag: nil
        )
        XCTAssertEqual(snap.courses.first?.classroom, "TR-409")
    }

    func test_idIsStableAndDeterministic() {
        let c = makeCourse(no: "X1", schedule: [1: ["3", "4"]])
        let a = WatchPayloadEncoder.encode(
            courses: [c], accentHex: "#000",
            syncedAt: Date(), loggedIn: true, languageTag: nil
        )
        let b = WatchPayloadEncoder.encode(
            courses: [c], accentHex: "#000",
            syncedAt: Date(), loggedIn: true, languageTag: nil
        )
        XCTAssertEqual(a.courses.first?.id, b.courses.first?.id)
        XCTAssertEqual(a.courses.first?.id, "X1-1-3")
    }

    func test_resolvesPeriodBellTimes() {
        // Assumes AppConstants.PeriodTimes.mapping["3"] = (start:"10:20", end:"11:10")
        // and ["4"] = (start:"11:20", end:"12:10"). If those constants change,
        // update this assertion to match.
        let c = makeCourse(schedule: [1: ["3", "4"]])
        let snap = WatchPayloadEncoder.encode(
            courses: [c], accentHex: "#000",
            syncedAt: Date(), loggedIn: true, languageTag: nil
        )
        XCTAssertEqual(snap.courses.first?.startHHmm, "10:20")
        XCTAssertEqual(snap.courses.first?.endHHmm, "12:10")
    }

    func test_loggedOut_stillEmitsCachedCourses() {
        let c = makeCourse()
        let snap = WatchPayloadEncoder.encode(
            courses: [c], accentHex: "#000",
            syncedAt: Date(), loggedIn: false, languageTag: nil
        )
        XCTAssertFalse(snap.loggedIn)
        XCTAssertEqual(snap.courses.count, 1)
    }
}
```

- [ ] **Step 2: Implement `WatchPayloadEncoder`**

```swift
// swift/TigerDuck/Services/Watch/WatchPayloadEncoder.swift
import Foundation

/// Phone-side flattener: takes the user's `SDCourse[]` and per-feature
/// preferences and produces a `WatchSnapshot` ready for `WatchPayloadCodec`.
///
/// A course meeting twice a week becomes two `WatchCourse` rows — each
/// row represents one concrete weekday session.
enum WatchPayloadEncoder {

    static func encode(
        courses: [SDCourse],
        accentHex: String,
        syncedAt: Date,
        loggedIn: Bool,
        languageTag: String?
    ) -> WatchSnapshot {
        let watchCourses = courses.flatMap { flatten($0) }
        let syncedAtMs = Int64((syncedAt.timeIntervalSince1970 * 1000).rounded())
        return WatchSnapshot(
            courses: watchCourses,
            accentHex: accentHex,
            syncedAtMs: syncedAtMs,
            loggedIn: loggedIn,
            languageTag: languageTag
        )
    }

    private static func flatten(_ course: SDCourse) -> [WatchCourse] {
        course.schedule.compactMap { weekday, periodIds in
            guard let first = periodIds.first,
                  let last = periodIds.last,
                  let startPeriod = TimetablePeriod.byId[first],
                  let endPeriod = TimetablePeriod.byId[last] else { return nil }

            let classroom = classroomFor(course, weekday: weekday, firstPeriod: first)
                ?? course.classroom
            let label = periodIds.count > 1
                ? "\(first)-\(last)"
                : first

            return WatchCourse(
                id: "\(course.courseNo)-\(weekday)-\(first)",
                courseNo: course.courseNo,
                name: course.courseName,
                teacher: course.instructor,
                classroom: classroom,
                colorHex: courseColorHex(course),
                weekday: weekday,
                startHHmm: startPeriod.startTime,
                endHHmm: endPeriod.endTime,
                periodLabel: label
            )
        }
        .sorted { ($0.weekday, $0.startHHmm) < ($1.weekday, $1.startHHmm) }
    }

    /// Look up the classroom for a specific (weekday, firstPeriod) cell.
    /// Falls back to the course's default classroom if no override is set.
    private static func classroomFor(_ course: SDCourse, weekday: Int, firstPeriod: String) -> String? {
        let key = "\(weekday)-\(firstPeriod)"
        return course.classroomMap[key]
    }

    /// Phone keeps the user's chosen per-course color in a separate store
    /// (currently `AppConstants.CourseColors` / user preference). For v1 we
    /// fall back to the global accent — Task 17 wires the per-course
    /// override into the encoder.
    private static func courseColorHex(_ course: SDCourse) -> String {
        return WatchSnapshot.defaultAccentHex
    }
}
```

> **Note on `courseColorHex`**: full per-course color resolution is deferred to Task 17. Tests at this task verify structural correctness only; the color field is asserted again in Task 17 once the lookup is wired in.

- [ ] **Step 3: [MAC-ONLY] Run tests; expect PASS**

```bash
xcodebuild test \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuck \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:TigerDuckTests/WatchPayloadEncoderTests
```

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuck/Services/Watch/WatchPayloadEncoder.swift swift/TigerDuckTests/Watch/WatchPayloadEncoderTests.swift
git commit -m "feat(watch): add WatchPayloadEncoder flattening SDCourse to WatchCourse sessions"
```

---

## Task 7 **[MAC-ONLY]**: Add Xcode targets for Watch App + Widget + tests

This is the unavoidable manual Xcode-UI step. Open `swift/TigerDuck.xcodeproj` in Xcode and do the following in order. Do not edit `project.pbxproj` by hand — Xcode regenerates the right cross-references.

- [ ] **Step 1: Add Watch App target**

In Xcode:
1. `File → New → Target…`
2. Select **watchOS → App** (the "Watch App for iOS App" template).
3. Configure:
   - Product Name: `TigerDuckWatch`
   - Team: (same as iOS app)
   - Organisation Identifier: `tw.smashit`
   - Bundle Identifier auto-fills to `tw.smashit.tigerduck.watchkitapp`
   - Interface: SwiftUI
   - Language: Swift
   - Include Tests: **yes** (creates `TigerDuckWatchTests`)
   - Companion App: `TigerDuck` (drop-down)
4. Click Finish. Xcode creates the target, scheme, and `WKCompanionAppBundleIdentifier` wiring.

- [ ] **Step 2: Set deployment target**

Project navigator → `TigerDuck` project → `TigerDuckWatch` target → **General** → Minimum Deployments: **watchOS 11.0**.

Repeat for `TigerDuckWatchTests` target.

- [ ] **Step 3: Move Xcode-generated files into the planned layout**

Xcode placed `TigerDuckWatchApp.swift`, `ContentView.swift`, `Assets.xcassets`, `Preview Content/` under `swift/TigerDuckWatch Watch App/` (or similar). In Finder + Xcode, **rename** that folder on disk to `swift/TigerDuckWatch/` and update the Xcode group's file system reference to point at it. Delete the placeholder `ContentView.swift`.

(If Xcode placed sources directly under `swift/TigerDuckWatch/`, skip the rename.)

- [ ] **Step 4: Add App Group capability**

Target `TigerDuckWatch` → **Signing & Capabilities** → `+ Capability` → **App Groups** → `+` → enter `group.tw.smashit.tigerduck.watch`.

Xcode creates `TigerDuckWatch.entitlements`. Move it to `swift/TigerDuckWatch/TigerDuckWatch.entitlements` if not already there.

- [ ] **Step 5: Verify scheme is shared**

Product → Scheme → Manage Schemes → check the **Shared** box for `TigerDuckWatch`. Commit the resulting `xcshareddata/xcschemes/TigerDuckWatch.xcscheme`.

- [ ] **Step 6: Add the existing shared files to the new target**

In Project navigator, select each of the four files under `swift/Shared/Watch/`:
- `WatchCourse.swift`
- `WatchSnapshot.swift`
- `WatchWireFormat.swift`
- `NextClassResolver.swift`

In the right-hand File Inspector → **Target Membership**, check both `TigerDuck` and `TigerDuckWatch`. (The first two and `WatchWireFormat` could be watch-only, but keeping them in both targets lets the phone-side encoder reuse them without import.)

Also add the test file `swift/TigerDuckWatchTests/WatchPayloadCodecTests.swift` to the `TigerDuckWatchTests` target.

- [ ] **Step 7: Commit**

```bash
git add swift/TigerDuck.xcodeproj swift/TigerDuckWatch
git commit -m "chore(watch): add TigerDuckWatch app target (watchOS 11) with App Group"
```

---

## Task 8 **[MAC-ONLY]**: Run the deferred Tasks 4 + 5 + 6 tests

Now that the scheme exists, run the tests we couldn't run before. Fix any failures inline.

- [ ] **Step 1: Run watch tests**

```bash
xcodebuild test \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuckWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)'
```

Expected: `WatchPayloadCodecTests` + `NextClassResolverTests` all pass.

- [ ] **Step 2: Run phone tests**

```bash
xcodebuild test \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuck \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:TigerDuckTests/WatchPayloadEncoderTests
```

Expected: `WatchPayloadEncoderTests` all pass.

- [ ] **Step 3: Commit any test fixes**

```bash
git add -p
git commit -m "fix(watch): align tests with Xcode target wiring"
```

(Skip if no changes.)

---

## Task 9: `SharedAppGroup` helper + `WatchAppLogger`

**Files:**
- Create: `swift/TigerDuckWatch/Services/SharedAppGroup.swift`
- Create: `swift/TigerDuckWatch/Services/WatchAppLogger.swift`

- [ ] **Step 1: Write `SharedAppGroup.swift`**

```swift
import Foundation

/// Single source of truth for App Group identifiers + paths shared between
/// the watch app and the widget. Both targets must declare the App Group
/// `group.tw.smashit.tigerduck.watch` in their entitlements.
enum SharedAppGroup {
    static let identifier = "group.tw.smashit.tigerduck.watch"

    /// Directory inside the App Group container.
    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            fatalError("App Group container missing — entitlement misconfigured")
        }
        return url
    }

    /// File where the most recent decoded snapshot is persisted.
    static var snapshotFileURL: URL {
        containerURL.appendingPathComponent("schedule.json", isDirectory: false)
    }

    /// Shared UserDefaults suite for small watch-side preferences.
    static var defaults: UserDefaults {
        guard let d = UserDefaults(suiteName: identifier) else {
            fatalError("UserDefaults(suiteName:) returned nil for \(identifier)")
        }
        return d
    }
}
```

- [ ] **Step 2: Write `WatchAppLogger.swift`**

```swift
import Foundation
import os

/// Wraps `os.Logger` for the watch app. Mirrors the phone's `AppLogger`
/// surface so call sites read the same way across targets.
enum WatchAppLogger {
    static let app = Logger(subsystem: "tw.smashit.tigerduck.watchkitapp", category: "app")
    static let wc = Logger(subsystem: "tw.smashit.tigerduck.watchkitapp", category: "wc")
    static let widget = Logger(subsystem: "tw.smashit.tigerduck.watchkitapp", category: "widget")
}
```

- [ ] **Step 3: [MAC-ONLY] Add both files to the `TigerDuckWatch` target via Xcode**

(Right-click the `Services` group → Add Files To "TigerDuckWatch" → confirm Target Membership = TigerDuckWatch.)

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWatch/Services/SharedAppGroup.swift swift/TigerDuckWatch/Services/WatchAppLogger.swift swift/TigerDuck.xcodeproj
git commit -m "feat(watch): add SharedAppGroup + WatchAppLogger"
```

---

## Task 10: `ScheduleStore` — WC delegate + persistence (TDD where possible)

The store activates `WCSession`, handles `didReceiveApplicationContext`, persists to the App Group file, publishes `snapshot`, and triggers widget reloads. It also exposes a `requestSync()` action for the SettingsView button and runs a cold-start `maybeRequest` with a 10-minute cooldown.

**Files:**
- Create: `swift/TigerDuckWatch/Services/ScheduleStore.swift`
- Create: `swift/TigerDuckWatchTests/ScheduleStoreTests.swift`

The test isolates the file-persistence and cooldown logic from real `WCSession` so we can unit-test it.

- [ ] **Step 1: Write failing tests**

```swift
// swift/TigerDuckWatchTests/ScheduleStoreTests.swift
import XCTest
import WatchKit
@testable import TigerDuckWatch

final class ScheduleStoreTests: XCTestCase {

    private var tempDir: URL!
    private var snapshotFile: URL!
    private var defaults: UserDefaults!
    private let suiteName = "ScheduleStoreTests"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        snapshotFile = tempDir.appendingPathComponent("schedule.json")
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func sampleSnapshot() -> WatchSnapshot {
        WatchSnapshot(
            courses: [],
            accentHex: "#FF8800",
            syncedAtMs: 1_747_000_000_000,
            loggedIn: true,
            languageTag: nil
        )
    }

    func test_persist_writesDecodableFile() throws {
        let store = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults)
        try store.persist(sampleSnapshot())
        let data = try Data(contentsOf: snapshotFile)
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: data)
        XCTAssertEqual(decoded, sampleSnapshot())
    }

    func test_loadFromDisk_returnsLastWrittenSnapshot() throws {
        let store = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults)
        try store.persist(sampleSnapshot())

        let fresh = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults)
        XCTAssertEqual(fresh.snapshot, sampleSnapshot())
    }

    func test_loadFromDisk_missingFile_snapshotIsNil() {
        let store = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults)
        XCTAssertNil(store.snapshot)
    }

    func test_shouldRequestSync_respectsTenMinuteCooldown() {
        let store = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults)
        let now = Date()
        store.recordSyncRequest(at: now)
        XCTAssertFalse(store.shouldRequestSync(at: now.addingTimeInterval(60)))
        XCTAssertTrue(store.shouldRequestSync(at: now.addingTimeInterval(601)))
    }

    func test_shouldRequestSync_neverRequestedYet_returnsTrue() {
        let store = ScheduleStore(snapshotFileURL: snapshotFile, defaults: defaults)
        XCTAssertTrue(store.shouldRequestSync(at: Date()))
    }
}
```

- [ ] **Step 2: Implement `ScheduleStore`**

```swift
// swift/TigerDuckWatch/Services/ScheduleStore.swift
import Foundation
import WatchConnectivity
import WidgetKit
import Combine

@MainActor
final class ScheduleStore: NSObject, ObservableObject {

    @Published private(set) var snapshot: WatchSnapshot?

    private let snapshotFileURL: URL
    private let defaults: UserDefaults
    private let widgetReloader: () -> Void
    private let cooldown: TimeInterval = 600

    private enum DefaultsKey {
        static let lastSyncRequestEpoch = "lastSyncRequestEpoch"
    }

    init(
        snapshotFileURL: URL = SharedAppGroup.snapshotFileURL,
        defaults: UserDefaults = SharedAppGroup.defaults,
        widgetReloader: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.snapshotFileURL = snapshotFileURL
        self.defaults = defaults
        self.widgetReloader = widgetReloader
        super.init()
        self.snapshot = loadFromDisk()
    }

    // MARK: - WC activation

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Persistence (unit-tested)

    func persist(_ snapshot: WatchSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotFileURL, options: .atomic)
        self.snapshot = snapshot
        widgetReloader()
    }

    private func loadFromDisk() -> WatchSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotFileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: snapshotFileURL)
            return try JSONDecoder().decode(WatchSnapshot.self, from: data)
        } catch {
            WatchAppLogger.wc.error("loadFromDisk decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Sync request (unit-tested)

    func shouldRequestSync(at date: Date = Date()) -> Bool {
        let last = defaults.double(forKey: DefaultsKey.lastSyncRequestEpoch)
        if last == 0 { return true }
        return date.timeIntervalSince1970 - last >= cooldown
    }

    func recordSyncRequest(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: DefaultsKey.lastSyncRequestEpoch)
    }

    func requestSync(force: Bool = false) {
        let now = Date()
        guard force || shouldRequestSync(at: now) else { return }
        recordSyncRequest(at: now)
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(
            [WatchWireFormat.MessageKey.kind: WatchWireFormat.MessageKind.syncRequest],
            replyHandler: nil,
            errorHandler: { error in
                WatchAppLogger.wc.error("sync request failed: \(error.localizedDescription)")
            }
        )
    }
}

// MARK: - WCSessionDelegate

extension ScheduleStore: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        if let error {
            WatchAppLogger.wc.error("activation error: \(error.localizedDescription)")
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            do {
                let snapshot = try WatchPayloadCodec.decode(applicationContext)
                try self.persist(snapshot)
            } catch {
                WatchAppLogger.wc.error("decode failed: \(error.localizedDescription) — keeping prior cache")
            }
        }
    }
}
```

- [ ] **Step 3: [MAC-ONLY] Add `ScheduleStore.swift` and the test file to their respective targets via Xcode**

- [ ] **Step 4: [MAC-ONLY] Run tests**

```bash
xcodebuild test \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuckWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' \
  -only-testing:TigerDuckWatchTests/ScheduleStoreTests
```

Expected: all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add swift/TigerDuckWatch/Services/ScheduleStore.swift swift/TigerDuckWatchTests/ScheduleStoreTests.swift swift/TigerDuck.xcodeproj
git commit -m "feat(watch): add ScheduleStore with WC delegate and 10-min cooldown"
```

---

## Task 11: `WatchTheme` modifier

**Files:**
- Create: `swift/TigerDuckWatch/UI/WatchTheme.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// Root-level modifier that applies the phone-pushed accent colour + locale.
/// Use as `.modifier(WatchTheme(snapshot: store.snapshot))` on the root view.
struct WatchTheme: ViewModifier {
    let snapshot: WatchSnapshot?

    func body(content: Content) -> some View {
        content
            .accentColor(accent)
            .environment(\.locale, locale)
    }

    private var accent: Color {
        let hex = snapshot?.accentHex ?? WatchSnapshot.defaultAccentHex
        return Color(hex: hex) ?? .orange
    }

    private var locale: Locale {
        if let tag = snapshot?.languageTag {
            return Locale(identifier: tag)
        }
        return .current
    }
}

extension Color {
    /// Parse "#RRGGBB" or "#AARRGGBB". Returns nil on malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let n = UInt32(s, radix: 16) else { return nil }
        switch s.count {
        case 6:
            let r = Double((n >> 16) & 0xFF) / 255.0
            let g = Double((n >>  8) & 0xFF) / 255.0
            let b = Double( n        & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
        case 8:
            let a = Double((n >> 24) & 0xFF) / 255.0
            let r = Double((n >> 16) & 0xFF) / 255.0
            let g = Double((n >>  8) & 0xFF) / 255.0
            let b = Double( n        & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 2: [MAC-ONLY] Add to `TigerDuckWatch` target**

- [ ] **Step 3: Commit**

```bash
git add swift/TigerDuckWatch/UI/WatchTheme.swift swift/TigerDuck.xcodeproj
git commit -m "feat(watch): add WatchTheme modifier (accent + locale)"
```

---

## Task 12: `NowNextView`

**Files:**
- Create: `swift/TigerDuckWatch/UI/NowNextView.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

struct NowNextView: View {
    @EnvironmentObject private var store: ScheduleStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let snapshot = store.snapshot, !snapshot.courses.isEmpty {
                    let result = NextClassResolver.resolve(courses: snapshot.courses, now: Date())
                    if let current = result.current {
                        ClassCard(title: String(localized: "watch.now"), course: current)
                    }
                    if let next = result.next {
                        ClassCard(title: String(localized: "watch.next"), course: next)
                    }
                    if result.current == nil && result.next == nil {
                        ContentUnavailableView(
                            String(localized: "watch.no_classes_today"),
                            systemImage: "calendar"
                        )
                    }
                } else if store.snapshot == nil {
                    ContentUnavailableView(
                        String(localized: "watch.empty.never_synced"),
                        systemImage: "iphone.gen3"
                    )
                } else {
                    // Logged out: empty courses array with loggedIn=false
                    ContentUnavailableView(
                        String(localized: "watch.empty.not_logged_in"),
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                }
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("TigerDuck")
    }
}

private struct ClassCard: View {
    let title: String
    let course: WatchCourse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color(hex: course.colorHex) ?? .accentColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(course.startHHmm)–\(course.endHHmm)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !course.classroom.isEmpty {
                        Text(course.classroom)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
    }
}
```

- [ ] **Step 2: [MAC-ONLY] Add to target**

- [ ] **Step 3: Commit**

```bash
git add swift/TigerDuckWatch/UI/NowNextView.swift swift/TigerDuck.xcodeproj
git commit -m "feat(watch): add NowNextView"
```

---

## Task 13: `TodayView` + `CourseDetailView`

**Files:**
- Create: `swift/TigerDuckWatch/UI/TodayView.swift`
- Create: `swift/TigerDuckWatch/UI/CourseDetailView.swift`

- [ ] **Step 1: Write `TodayView.swift`**

```swift
import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: ScheduleStore

    private var todaysCourses: [WatchCourse] {
        guard let snapshot = store.snapshot else { return [] }
        let cal = Calendar(identifier: .iso8601)
        let raw = cal.component(.weekday, from: Date())
        let iso = ((raw + 5) % 7) + 1
        return snapshot.courses
            .filter { $0.weekday == iso }
            .sorted { $0.startHHmm < $1.startHHmm }
    }

    var body: some View {
        Group {
            if todaysCourses.isEmpty {
                ContentUnavailableView(
                    String(localized: "watch.no_classes_today"),
                    systemImage: "calendar"
                )
            } else {
                List(todaysCourses) { course in
                    NavigationLink {
                        CourseDetailView(course: course)
                    } label: {
                        TodayRow(course: course)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "watch.today"))
    }
}

private struct TodayRow: View {
    let course: WatchCourse

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color(hex: course.colorHex) ?? .accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(course.startHHmm)–\(course.endHHmm) · \(course.classroom)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
```

- [ ] **Step 2: Write `CourseDetailView.swift`**

```swift
import SwiftUI

struct CourseDetailView: View {
    let course: WatchCourse

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color(hex: course.colorHex) ?? .accentColor)
                        .frame(width: 4)
                    Text(course.name)
                        .font(.headline)
                }
                LabeledRow(symbol: "clock", text: "\(course.startHHmm)–\(course.endHHmm)")
                if !course.classroom.isEmpty {
                    LabeledRow(symbol: "mappin.and.ellipse", text: course.classroom)
                }
                if !course.teacher.isEmpty {
                    LabeledRow(symbol: "person", text: course.teacher)
                }
                LabeledRow(symbol: "number", text: course.periodLabel)
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle(course.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LabeledRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
    }
}
```

- [ ] **Step 3: [MAC-ONLY] Add both files to the watch target**

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWatch/UI/TodayView.swift swift/TigerDuckWatch/UI/CourseDetailView.swift swift/TigerDuck.xcodeproj
git commit -m "feat(watch): add TodayView and CourseDetailView"
```

---

## Task 14: `SettingsView`

**Files:**
- Create: `swift/TigerDuckWatch/UI/SettingsView.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ScheduleStore

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: store.snapshot?.loggedIn == true
                          ? "person.crop.circle.fill.badge.checkmark"
                          : "person.crop.circle.badge.exclamationmark")
                    Text(loginText)
                        .font(.subheadline)
                }
                HStack {
                    Image(systemName: "calendar.badge.clock")
                    Text(lastSyncedText)
                        .font(.subheadline)
                }
                Button {
                    store.requestSync(force: true)
                } label: {
                    Label(String(localized: "watch.settings.sync_now"),
                          systemImage: "arrow.clockwise")
                }
            }
            Section {
                Text(versionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "watch.settings"))
    }

    private var loginText: String {
        store.snapshot?.loggedIn == true
            ? String(localized: "watch.settings.signed_in")
            : String(localized: "watch.settings.signed_out")
    }

    private var lastSyncedText: String {
        guard let ms = store.snapshot?.syncedAtMs, ms > 0 else {
            return String(localized: "watch.empty.never_synced")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }
}
```

- [ ] **Step 2: [MAC-ONLY] Add to target**

- [ ] **Step 3: Commit**

```bash
git add swift/TigerDuckWatch/UI/SettingsView.swift swift/TigerDuck.xcodeproj
git commit -m "feat(watch): add SettingsView with Sync now action"
```

---

## Task 15: `WatchRootView` + `TigerDuckWatchApp` entry

**Files:**
- Create: `swift/TigerDuckWatch/UI/WatchRootView.swift`
- Modify (or replace Xcode-generated): `swift/TigerDuckWatch/TigerDuckWatchApp.swift`

- [ ] **Step 1: Write `WatchRootView.swift`**

```swift
import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var store: ScheduleStore

    var body: some View {
        TabView {
            NavigationStack { NowNextView() }
            NavigationStack { TodayView() }
            NavigationStack { SettingsView() }
        }
        .tabViewStyle(.page)
        .modifier(WatchTheme(snapshot: store.snapshot))
        .onAppear {
            if store.shouldRequestSync() {
                store.requestSync()
            }
        }
    }
}
```

- [ ] **Step 2: Replace `TigerDuckWatchApp.swift` (Xcode generated a stub) with**

```swift
import SwiftUI

@main
struct TigerDuckWatchApp: App {
    @StateObject private var store: ScheduleStore

    init() {
        let store = ScheduleStore()
        store.activate()
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(store)
        }
    }
}
```

- [ ] **Step 3: [MAC-ONLY] Build the watch app target**

```bash
xcodebuild build \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuckWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)'
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWatch/UI/WatchRootView.swift swift/TigerDuckWatch/TigerDuckWatchApp.swift swift/TigerDuck.xcodeproj
git commit -m "feat(watch): wire WatchRootView TabView and @main entry"
```

---

## Task 16: `WatchSyncCoordinator` (phone-side) — failing tests first (TDD)

The coordinator activates `WCSession` on the phone, observes `SDCourse` changes / accent / language / login state, debounces 500 ms, encodes via `WatchPayloadEncoder`, and pushes via `updateApplicationContext`. It also handles incoming `syncRequest` messages.

Testing strategy: inject the encoder + a stub session so we can assert on what was pushed. `WCSession` doesn't conform to a protocol, so we wrap it.

**Files:**
- Create: `swift/TigerDuck/Services/Watch/WatchSyncCoordinator.swift`
- Create: `swift/TigerDuckTests/Watch/WatchSyncCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// swift/TigerDuckTests/Watch/WatchSyncCoordinatorTests.swift
import XCTest
@testable import TigerDuck

final class WatchSyncCoordinatorTests: XCTestCase {

    final class StubSession: WatchSessionPushing {
        var pushedContexts: [[String: Any]] = []
        var isPaired = true
        var isWatchAppInstalled = true
        func updateApplicationContext(_ context: [String: Any]) throws {
            pushedContexts.append(context)
        }
    }

    func test_push_encodesAndForwards() async throws {
        let session = StubSession()
        let coord = WatchSyncCoordinator(session: session)
        coord.push(
            courses: [],
            accentHex: "#FF8800",
            loggedIn: true,
            languageTag: "zh-Hant-TW"
        )
        // Coordinator pushes synchronously when called directly.
        XCTAssertEqual(session.pushedContexts.count, 1)
        let dict = session.pushedContexts[0]
        XCTAssertEqual(dict[WatchWireFormat.Key.accentHex] as? String, "#FF8800")
        XCTAssertEqual(dict[WatchWireFormat.Key.loggedIn] as? Bool, true)
    }

    func test_push_skipsWhenWatchNotInstalled() {
        let session = StubSession()
        session.isWatchAppInstalled = false
        let coord = WatchSyncCoordinator(session: session)
        coord.push(courses: [], accentHex: "#000", loggedIn: false, languageTag: nil)
        XCTAssertTrue(session.pushedContexts.isEmpty)
    }

    func test_debounce_coalescesBurstWithin500ms() async throws {
        let session = StubSession()
        let coord = WatchSyncCoordinator(session: session)
        coord.scheduleDebouncedPush(courses: [], accentHex: "#A", loggedIn: true, languageTag: nil)
        coord.scheduleDebouncedPush(courses: [], accentHex: "#B", loggedIn: true, languageTag: nil)
        coord.scheduleDebouncedPush(courses: [], accentHex: "#C", loggedIn: true, languageTag: nil)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(session.pushedContexts.count, 1)
        XCTAssertEqual(session.pushedContexts[0][WatchWireFormat.Key.accentHex] as? String, "#C")
    }
}
```

- [ ] **Step 2: Implement `WatchSyncCoordinator`**

```swift
// swift/TigerDuck/Services/Watch/WatchSyncCoordinator.swift
import Foundation
import WatchConnectivity
import Combine

/// Narrow protocol over WCSession so we can stub it in tests.
protocol WatchSessionPushing: AnyObject {
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    func updateApplicationContext(_ context: [String: Any]) throws
}

extension WCSession: WatchSessionPushing {}

@MainActor
final class WatchSyncCoordinator: NSObject {

    private let session: WatchSessionPushing
    private var debounceTask: Task<Void, Never>?
    private var pendingPayload: PendingPayload?
    private let debounceInterval: TimeInterval = 0.5

    private struct PendingPayload {
        let courses: [SDCourse]
        let accentHex: String
        let loggedIn: Bool
        let languageTag: String?
    }

    init(session: WatchSessionPushing = WCSession.default) {
        self.session = session
        super.init()
    }

    func activate() {
        guard let wcSession = session as? WCSession else { return }
        wcSession.delegate = self
        wcSession.activate()
    }

    /// Push immediately (used in tests). Production code uses
    /// `scheduleDebouncedPush(...)` to coalesce bursts.
    func push(courses: [SDCourse], accentHex: String, loggedIn: Bool, languageTag: String?) {
        guard session.isPaired, session.isWatchAppInstalled else { return }
        let snapshot = WatchPayloadEncoder.encode(
            courses: courses, accentHex: accentHex,
            syncedAt: Date(), loggedIn: loggedIn, languageTag: languageTag
        )
        do {
            let dict = try WatchPayloadCodec.encode(snapshot)
            try session.updateApplicationContext(dict)
        } catch {
            AppLogger.network.error("watch context push failed: \(error.localizedDescription)")
        }
    }

    func scheduleDebouncedPush(courses: [SDCourse], accentHex: String, loggedIn: Bool, languageTag: String?) {
        pendingPayload = PendingPayload(
            courses: courses, accentHex: accentHex, loggedIn: loggedIn, languageTag: languageTag
        )
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.debounceInterval ?? 0.5) * 1_000_000_000))
            guard !Task.isCancelled, let self, let p = self.pendingPayload else { return }
            self.pendingPayload = nil
            self.push(courses: p.courses, accentHex: p.accentHex,
                      loggedIn: p.loggedIn, languageTag: p.languageTag)
        }
    }
}

// MARK: - WCSessionDelegate (production only; ignored when session is a stub)

extension WatchSyncCoordinator: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        if let error {
            AppLogger.network.error("phone WC activation: \(error.localizedDescription)")
        }
    }

    // iOS-only delegate methods required by the protocol
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {}

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        guard let kind = message[WatchWireFormat.MessageKey.kind] as? String,
              kind == WatchWireFormat.MessageKind.syncRequest else { return }
        Task { @MainActor in
            // Subscribers in Task 17 will hook into this to re-emit current state.
            NotificationCenter.default.post(name: .watchSyncRequested, object: nil)
        }
    }
}

extension Notification.Name {
    static let watchSyncRequested = Notification.Name("watchSyncRequested")
}
```

- [ ] **Step 3: [MAC-ONLY] Add files to targets and run tests**

```bash
xcodebuild test \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuck \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:TigerDuckTests/WatchSyncCoordinatorTests
```

Expected: 3/3 pass.

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuck/Services/Watch/WatchSyncCoordinator.swift swift/TigerDuckTests/Watch/WatchSyncCoordinatorTests.swift swift/TigerDuck.xcodeproj
git commit -m "feat(watch): add WatchSyncCoordinator with debouncing + sync-request handling"
```

---

## Task 17: Wire `WatchSyncCoordinator` into `TigerDuckApp`

**Files:**
- Modify: `swift/TigerDuck/App/TigerDuckApp.swift`

- [ ] **Step 1: Inspect the existing file**

```bash
sed -n '1,40p' swift/TigerDuck/App/TigerDuckApp.swift
```

Identify the existing `@main` struct and its `init()` / `body` shape. Add the coordinator alongside whatever other singletons live there (push coordinator, etc).

- [ ] **Step 2: Add the coordinator instance**

Inside the `TigerDuckApp` struct:

```swift
@StateObject private var watchSync: WatchSyncCoordinator = {
    let coord = WatchSyncCoordinator()
    coord.activate()
    return coord
}()
```

- [ ] **Step 3: Wire observers**

In the App's `init()` or a startup task, subscribe to the existing change emitters. Adapt the call sites below to the project's actual reactive plumbing — search for where `SDCourse` changes are already broadcast (`grep -nr "objectWillChange\|courseDidChange\|SDCourse" swift/TigerDuck`):

```swift
// In TigerDuckApp init or .onAppear of root view:
let center = NotificationCenter.default
let pushOnce: () -> Void = { [weak self] in
    guard let self else { return }
    let snapshot = currentSDCourses()           // existing fetch helper
    let accent = AccentColorStore.shared.hex    // existing pref store
    let logged = AuthService.shared.isLoggedIn  // existing auth flag
    let lang = LocaleSettings.shared.languageTag // existing locale store
    self.watchSync.scheduleDebouncedPush(
        courses: snapshot, accentHex: accent, loggedIn: logged, languageTag: lang
    )
}

center.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: .main) { _ in pushOnce() }
center.addObserver(forName: .accentColorChanged,           object: nil, queue: .main) { _ in pushOnce() }
center.addObserver(forName: .authStateChanged,             object: nil, queue: .main) { _ in pushOnce() }
center.addObserver(forName: .localeSettingChanged,         object: nil, queue: .main) { _ in pushOnce() }
center.addObserver(forName: .watchSyncRequested,           object: nil, queue: .main) { _ in pushOnce() }
```

> If any of those notification names don't exist in the codebase, audit the relevant module and either reuse the existing publisher or add a new `Notification.Name` constant. Don't invent emitters that aren't already there — track each one down. Update `pushOnce`'s helper calls (`AccentColorStore.shared.hex`, etc.) to match real APIs.

- [ ] **Step 4: Update `WatchPayloadEncoder.courseColorHex` to use the real per-course color store**

Locate the phone's per-course color preference (search: `grep -nr "courseColor\|colorForCourse" swift/TigerDuck/Models swift/TigerDuck/Services swift/TigerDuck/Features`). Replace the placeholder body in `WatchPayloadEncoder.courseColorHex(_:)`:

```swift
private static func courseColorHex(_ course: SDCourse) -> String {
    CourseColorStore.shared.hex(for: course.courseNo)
        ?? WatchSnapshot.defaultAccentHex
}
```

(Adjust to whatever the real API is named.)

Add a regression test in `WatchPayloadEncoderTests.swift`:

```swift
func test_perCourseColorOverridesAccent() {
    CourseColorStore.shared.set(hex: "#00FFAA", for: "X1")
    let c = makeCourse(no: "X1")
    let snap = WatchPayloadEncoder.encode(
        courses: [c], accentHex: "#FF8800",
        syncedAt: Date(), loggedIn: true, languageTag: nil
    )
    XCTAssertEqual(snap.courses.first?.colorHex, "#00FFAA")
}
```

- [ ] **Step 5: [MAC-ONLY] Build phone app + run all phone tests**

```bash
xcodebuild test \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuck \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:TigerDuckTests/WatchPayloadEncoderTests \
  -only-testing:TigerDuckTests/WatchSyncCoordinatorTests
```

Expected: all pass. Build the iOS target succeeds.

- [ ] **Step 6: Commit**

```bash
git add swift/TigerDuck/App/TigerDuckApp.swift swift/TigerDuck/Services/Watch/WatchPayloadEncoder.swift swift/TigerDuckTests/Watch/WatchPayloadEncoderTests.swift
git commit -m "feat(watch): wire WatchSyncCoordinator + per-course color into TigerDuckApp"
```

---

## Task 18 **[MAC-ONLY]**: Add Widget Extension target

- [ ] **Step 1: Add the target via Xcode**

`File → New → Target… → watchOS → Widget Extension`. Configure:
- Product Name: `TigerDuckWatchWidget`
- Embed in Application: `TigerDuckWatch` (the watch app, not the iOS app)
- Include Configuration App Intent: **no**
- Language: Swift

Xcode places source files under `swift/TigerDuckWatchWidget/`. Set Minimum Deployments → watchOS 11.0.

- [ ] **Step 2: Add App Group capability**

Signing & Capabilities → `+ Capability` → App Groups → check `group.tw.smashit.tigerduck.watch`.

- [ ] **Step 3: Add shared files**

Add to target membership of `TigerDuckWatchWidget`:
- `swift/Shared/Watch/WatchCourse.swift`
- `swift/Shared/Watch/WatchSnapshot.swift`
- `swift/Shared/Watch/WatchWireFormat.swift`
- `swift/Shared/Watch/NextClassResolver.swift`
- `swift/TigerDuckWatch/Services/SharedAppGroup.swift`
- `swift/TigerDuckWatch/UI/WatchTheme.swift` (for `Color(hex:)`)

- [ ] **Step 4: Delete the placeholder files Xcode generated**

Remove the Xcode-default `TigerDuckWatchWidget.swift` / `TigerDuckWatchWidgetBundle.swift` stubs. We'll rewrite them in Task 19.

- [ ] **Step 5: Verify shared scheme + commit**

Mark the auto-created `TigerDuckWatchWidget` scheme as shared.

```bash
git add swift/TigerDuckWatchWidget swift/TigerDuck.xcodeproj
git commit -m "chore(watch): add TigerDuckWatchWidget extension target with App Group"
```

---

## Task 19: `NextClassEntry` + `NextClassProvider` (TimelineProvider)

**Files:**
- Create: `swift/TigerDuckWatchWidget/NextClassEntry.swift`
- Create: `swift/TigerDuckWatchWidget/NextClassProvider.swift`

- [ ] **Step 1: Write `NextClassEntry.swift`**

```swift
import WidgetKit
import Foundation

struct NextClassEntry: TimelineEntry {
    let date: Date
    let current: WatchCourse?
    let next: WatchCourse?
    let accentHex: String
    let relevance: TimelineEntryRelevance?
}
```

- [ ] **Step 2: Write `NextClassProvider.swift`**

```swift
import WidgetKit
import Foundation

struct NextClassProvider: TimelineProvider {

    func placeholder(in context: Context) -> NextClassEntry {
        NextClassEntry(
            date: Date(),
            current: nil,
            next: Self.sampleCourse(),
            accentHex: WatchSnapshot.defaultAccentHex,
            relevance: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NextClassEntry) -> Void) {
        let snapshot = loadSnapshot()
        let r = NextClassResolver.resolve(courses: snapshot?.courses ?? [], now: Date())
        completion(NextClassEntry(
            date: Date(),
            current: r.current,
            next: r.next,
            accentHex: snapshot?.accentHex ?? WatchSnapshot.defaultAccentHex,
            relevance: relevance(for: r, now: Date())
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextClassEntry>) -> Void) {
        let snapshot = loadSnapshot()
        let accent = snapshot?.accentHex ?? WatchSnapshot.defaultAccentHex
        let courses = snapshot?.courses ?? []

        var entries: [NextClassEntry] = []
        let now = Date()
        let cal = Calendar(identifier: .iso8601)
        let raw = cal.component(.weekday, from: now)
        let iso = ((raw + 5) % 7) + 1
        let today = courses.filter { $0.weekday == iso }

        // Boundary times in chronological order: each class start + each class end.
        var boundaries: [Date] = [now]
        for c in today {
            if let s = combine(hhmm: c.startHHmm, with: now), s > now { boundaries.append(s) }
            if let e = combine(hhmm: c.endHHmm, with: now), e > now { boundaries.append(e) }
        }
        // De-dup and sort
        let unique = Array(Set(boundaries)).sorted()

        for ts in unique {
            let r = NextClassResolver.resolve(courses: courses, now: ts)
            entries.append(NextClassEntry(
                date: ts,
                current: r.current,
                next: r.next,
                accentHex: accent,
                relevance: relevance(for: r, now: ts)
            ))
        }

        // Reload tomorrow at 04:00 local
        let reloadAt = cal.nextDate(
            after: now,
            matching: DateComponents(hour: 4, minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(6 * 3600)

        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    // MARK: - Helpers

    private func loadSnapshot() -> WatchSnapshot? {
        let url = SharedAppGroup.snapshotFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(WatchSnapshot.self, from: data)
        } catch {
            WatchAppLogger.widget.error("widget loadSnapshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func combine(hhmm: String, with anchor: Date) -> Date? {
        let cal = Calendar(identifier: .iso8601)
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        var dc = cal.dateComponents([.year, .month, .day], from: anchor)
        dc.hour = h; dc.minute = m
        return cal.date(from: dc)
    }

    private func relevance(for r: NextClassResolver.Result, now: Date) -> TimelineEntryRelevance? {
        guard let next = r.next, let start = combine(hhmm: next.startHHmm, with: now) else {
            return TimelineEntryRelevance(score: 30, duration: 0)
        }
        let minutesUntil = start.timeIntervalSince(now) / 60
        if minutesUntil <= 30 {
            return TimelineEntryRelevance(score: 90, duration: minutesUntil * 60)
        }
        return TimelineEntryRelevance(score: 30, duration: 0)
    }

    static func sampleCourse() -> WatchCourse {
        WatchCourse(
            id: "sample-1-3",
            courseNo: "SAMPLE",
            name: "資料結構",
            teacher: "張教授",
            classroom: "D101",
            colorHex: WatchSnapshot.defaultAccentHex,
            weekday: 1,
            startHHmm: "10:20",
            endHHmm: "11:10",
            periodLabel: "3-4"
        )
    }
}
```

> `WatchAppLogger` lives in the watch app target. If the widget target can't access it, duplicate the minimal `os.Logger` wrapper inline in the widget. Multi-target membership on `WatchAppLogger.swift` is fine — pick whichever is cleaner.

- [ ] **Step 3: [MAC-ONLY] Add to widget target, build**

```bash
xcodebuild build \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuckWatchWidget \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)'
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWatchWidget swift/TigerDuck.xcodeproj
git commit -m "feat(watch): add NextClassProvider with boundary-based timeline + relevance"
```

---

## Task 20: Widget family views

**Files:**
- Create: `swift/TigerDuckWatchWidget/Views/CircularView.swift`
- Create: `swift/TigerDuckWatchWidget/Views/CornerView.swift`
- Create: `swift/TigerDuckWatchWidget/Views/InlineView.swift`
- Create: `swift/TigerDuckWatchWidget/Views/RectangularView.swift`

- [ ] **Step 1: Write `RectangularView.swift`**

```swift
import SwiftUI

struct RectangularView: View {
    let entry: NextClassEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline)
                .font(.headline)
                .lineLimit(1)
                .widgetAccentable()
            Text(subhead)
                .font(.subheadline)
                .lineLimit(1)
            if let room = displayRoom {
                Text(room)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var displayCourse: WatchCourse? { entry.next ?? entry.current }
    private var headline: String { displayCourse?.name ?? String(localized: "watch.no_classes_today") }
    private var subhead: String {
        guard let c = displayCourse else { return "—" }
        return "\(c.startHHmm)–\(c.endHHmm)"
    }
    private var displayRoom: String? {
        guard let c = displayCourse, !c.classroom.isEmpty else { return nil }
        return c.classroom
    }
}
```

- [ ] **Step 2: Write `CircularView.swift`**

```swift
import SwiftUI

struct CircularView: View {
    let entry: NextClassEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Text(monogram)
                .font(.headline)
                .widgetAccentable()
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var monogram: String {
        guard let course = entry.next ?? entry.current else { return "—" }
        let name = course.name
        if name.isEmpty { return "?" }
        return String(name.prefix(2))
    }
}
```

- [ ] **Step 3: Write `InlineView.swift`**

```swift
import SwiftUI

struct InlineView: View {
    let entry: NextClassEntry

    var body: some View {
        Text(text)
            .containerBackground(.fill.tertiary, for: .widget)
    }

    private var text: String {
        if let c = entry.current {
            return "\(c.name) · \(c.endHHmm)"
        } else if let n = entry.next {
            return "\(n.name) · \(n.startHHmm)"
        } else {
            return String(localized: "watch.no_classes_today")
        }
    }
}
```

- [ ] **Step 4: Write `CornerView.swift`**

```swift
import SwiftUI

struct CornerView: View {
    let entry: NextClassEntry

    var body: some View {
        Text(label)
            .widgetCurvesContent()
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetLabel {
                Text(timeText)
            }
    }

    private var label: String {
        (entry.next ?? entry.current)?.name ?? "—"
    }
    private var timeText: String {
        if let c = entry.current { return c.endHHmm }
        if let n = entry.next { return n.startHHmm }
        return ""
    }
}
```

- [ ] **Step 5: [MAC-ONLY] Add all four files to the widget target via Xcode**

- [ ] **Step 6: Commit**

```bash
git add swift/TigerDuckWatchWidget/Views swift/TigerDuck.xcodeproj
git commit -m "feat(watch): add widget family views for all four complication shapes"
```

---

## Task 21: `NextClassWidget` configuration + `TigerDuckWatchWidgetBundle`

**Files:**
- Create: `swift/TigerDuckWatchWidget/NextClassWidget.swift`
- Create: `swift/TigerDuckWatchWidget/TigerDuckWatchWidgetBundle.swift`

- [ ] **Step 1: Write `NextClassWidget.swift`**

```swift
import SwiftUI
import WidgetKit

struct NextClassWidget: Widget {
    let kind: String = "NextClassWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextClassProvider()) { entry in
            NextClassWidgetEntryView(entry: entry)
                .modifier(WatchTheme(snapshot: nil)) // accent passed in entry; locale uses system
        }
        .configurationDisplayName(String(localized: "watch.widget.next_class"))
        .description(String(localized: "watch.widget.next_class.description"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct NextClassWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: NextClassEntry

    var body: some View {
        switch family {
        case .accessoryCircular:    CircularView(entry: entry)
        case .accessoryRectangular: RectangularView(entry: entry)
        case .accessoryInline:      InlineView(entry: entry)
        case .accessoryCorner:      CornerView(entry: entry)
        default:                    EmptyView()
        }
    }
}
```

- [ ] **Step 2: Write `TigerDuckWatchWidgetBundle.swift`**

```swift
import SwiftUI
import WidgetKit

@main
struct TigerDuckWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextClassWidget()
    }
}
```

- [ ] **Step 3: [MAC-ONLY] Add to target, build**

```bash
xcodebuild build \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuckWatchWidget \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)'
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWatchWidget swift/TigerDuck.xcodeproj
git commit -m "feat(watch): wire NextClassWidget StaticConfiguration + WidgetBundle"
```

---

## Task 22: Localization keys

The shared `app-translation` submodule is the source of truth for all strings. Add the watch-specific keys there so iOS and Android stay in sync (the Wear module already has some of these).

**Files:**
- Modify: `localization/source/shared.json` (or whatever file the submodule already uses for watch strings; check first)
- Modify (regenerated): platform-specific output under `localization/generated/ios/`

- [ ] **Step 1: Discover where shared strings live**

```bash
ls localization/source 2>/dev/null || git submodule update --init localization
ls localization/source
grep -rl "watch_not_found\|watch.now\|watch.next" localization/source ~/StudioProjects/tigerduck-app-android/localization 2>/dev/null
```

Identify the JSON file owning the `watch.*` keys. If none exists, create `localization/source/watch.json` and register it with the generator (consult `localization/README.md` or the submodule's instructions).

- [ ] **Step 2: Add the keys**

Add the following keys (use existing Wear keys as the canonical source; copy their `zh-Hant-TW` + `en` values verbatim where they exist):

```
watch.now
watch.next
watch.today
watch.settings
watch.no_classes_today
watch.empty.never_synced
watch.empty.not_logged_in
watch.empty.course_not_found
watch.settings.sync_now
watch.settings.signed_in
watch.settings.signed_out
watch.widget.next_class
watch.widget.next_class.description
```

For any key Wear lacks, draft values in `zh-Hant-TW` and `en` only; treat other locales as TBD (the submodule's normal translation flow handles propagation).

- [ ] **Step 3: Regenerate**

Run the localization submodule's generator (the project's localization README documents the command, typically `python3 tools/localization/sync_localizations.py` or `make localizations`). Verify new keys appear in `localization/generated/ios/<lang>.lproj/Localizable.strings`.

- [ ] **Step 4: [MAC-ONLY] Add the generated `.strings` files to both watch targets**

In Xcode, the generated `Localizable.strings` files should already have target membership for `TigerDuck`. Add membership for `TigerDuckWatch` and `TigerDuckWatchWidget` so `String(localized:)` calls resolve.

- [ ] **Step 5: [MAC-ONLY] Build all three targets**

```bash
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck             -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuckWatch         -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)'
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuckWatchWidget   -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)'
```

Expected: all three succeed.

- [ ] **Step 6: Commit**

```bash
git add localization swift/TigerDuck.xcodeproj
git commit -m "feat(watch): add watch.* localization keys and wire generated strings to watch targets"
```

---

## Task 23: Widget snapshot tests

**Files:**
- Create: `swift/TigerDuckWatchWidgetTests/NextClassWidgetSnapshotTests.swift`

- [ ] **Step 1: [MAC-ONLY] Add the test target**

In Xcode: `File → New → Target… → watchOS Unit Testing Bundle`. Name: `TigerDuckWatchWidgetTests`. Host application: `TigerDuckWatchWidget`. Add multi-target membership for `WatchCourse.swift`, `WatchSnapshot.swift`, `NextClassResolver.swift`, the four view files, and `NextClassEntry.swift`.

- [ ] **Step 2: Write the snapshot test file**

```swift
import XCTest
import SwiftUI
@testable import TigerDuckWatchWidget

final class NextClassWidgetSnapshotTests: XCTestCase {

    private func sampleEntry(now: Bool = true, next: Bool = true) -> NextClassEntry {
        NextClassEntry(
            date: Date(),
            current: now ? sampleCourse(name: "現在") : nil,
            next: next ? sampleCourse(name: "下一堂") : nil,
            accentHex: "#FF8800",
            relevance: nil
        )
    }

    private func sampleCourse(name: String) -> WatchCourse {
        WatchCourse(
            id: "x-1-3", courseNo: "X",
            name: name, teacher: "T",
            classroom: "TR-313", colorHex: "#FF8800",
            weekday: 1, startHHmm: "10:20", endHHmm: "11:10",
            periodLabel: "3-4"
        )
    }

    private func render<V: View>(_ view: V) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: 200, height: 80))
        return renderer.cgImage
    }

    func test_rectangularRendersNonNil() {
        XCTAssertNotNil(render(RectangularView(entry: sampleEntry())))
    }

    func test_circularRendersNonNil() {
        XCTAssertNotNil(render(CircularView(entry: sampleEntry())))
    }

    func test_inlineRendersNonNil() {
        XCTAssertNotNil(render(InlineView(entry: sampleEntry())))
    }

    func test_cornerRendersNonNil() {
        XCTAssertNotNil(render(CornerView(entry: sampleEntry())))
    }

    func test_emptyState_rendersWithoutCrashing() {
        XCTAssertNotNil(render(RectangularView(entry: sampleEntry(now: false, next: false))))
    }
}
```

> These are "does it render" smoke tests — pixel-comparison snapshots add maintenance burden without commensurate value at v1. If a regression slips through, upgrade to PNG-comparison snapshots later.

- [ ] **Step 3: [MAC-ONLY] Run**

```bash
xcodebuild test \
  -project swift/TigerDuck.xcodeproj \
  -scheme TigerDuckWatchWidget \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)'
```

Expected: 5/5 pass.

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWatchWidgetTests swift/TigerDuck.xcodeproj
git commit -m "test(watch): add widget render smoke tests for all four families"
```

---

## Task 24 **[MAC-ONLY]**: Manual end-to-end test plan

This is verification, not implementation — but it's required before claiming the task is done. Record results inline below the checkboxes.

- [ ] **Step 1: Pair simulators**

`Xcode → Window → Devices and Simulators → Simulators tab → +`. Create an `iPhone 16` + `Apple Watch Series 10` pair if not already present.

- [ ] **Step 2: Build + run the watch scheme** (which auto-builds + installs the phone app too)

`Scheme: TigerDuckWatch` → Run.

- [ ] **Step 3: Smoke flow**

1. Sign in on the phone app.
2. Within ~5 s, the watch's NowNext should populate.
3. Swipe to Today — verify rows match.
4. Tap a row — verify CourseDetail.
5. Swipe to Settings — verify "Last synced X sec ago" + login state.
6. Tap "Sync now" — verify the timestamp resets to "0 sec ago".

- [ ] **Step 4: Force-quit watch, verify widget**

Long-press the watch home button to force-quit `TigerDuckWatch`. Add the rectangular widget to the watch face (Customize → tap a complication slot → select TigerDuck NextClass). Verify the widget still shows the next class — it should, since it reads from the cached App Group file.

- [ ] **Step 5: Airplane-mode resilience**

Turn airplane mode on for the phone simulator. Tap "Sync now" on the watch. Expected: no crash; cached data remains visible. (`Sync now`-triggered failures surface as a brief inline error in v1; auto-sync failures stay silent.)

- [ ] **Step 6: Accent + locale propagation**

Change the phone's accent color (in the iOS app's settings). Within a few seconds, the watch should pick it up — accent visible in cards' coloured stripes, in `Button` tints, and on the next widget timeline reload.

Change the phone's UI language. Re-open the watch app — strings should render in the new language. The widget will catch up at its next reload.

- [ ] **Step 7: Document any defects found**

If anything in steps 3–6 fails, file follow-up tasks. Do not mark task 24 complete with known failing checks — better to fix them inline before PR.

- [ ] **Step 8: Commit any inline fixes**

```bash
git add -p
git commit -m "fix(watch): address issues found in manual test pass"
```

(Skip if no fixes.)

---

## Task 25: Open PR

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/watchos
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --base dev --title "feat(watch): add watchOS companion app + Smart Stack widget" --body "$(cat <<'EOF'
## Summary

- New `TigerDuckWatch` watchOS 11 companion app — NowNext / Today / Settings, all driven by data pushed from the phone over `WCSession.updateApplicationContext`.
- New `TigerDuckWatchWidget` extension — single `NextClassWidget` supporting `.accessoryCircular`, `.accessoryRectangular`, `.accessoryInline`, `.accessoryCorner`, with relevance scoring for Smart Stack surfacing within 30 min of class start.
- New phone-side `WatchSyncCoordinator` debounces change emissions and pushes a flat `WatchCourse` DTO; mirrors the Wear module's wire-format philosophy.
- Companion-only — no SSO on watch, no Keychain on watch, no backend access from watch. Mirrors Wear's `standalone=false`.
- Spec: `docs/superpowers/specs/2026-05-12-watchos-app-design.md`.
- Plan: `docs/superpowers/plans/2026-05-12-watchos-app.md`.

## Test plan

- [ ] `xcodebuild test -scheme TigerDuck`            — all phone tests pass
- [ ] `xcodebuild test -scheme TigerDuckWatch`        — all watch tests pass
- [ ] `xcodebuild test -scheme TigerDuckWatchWidget`  — widget render smoke tests pass
- [ ] Manual: paired simulator end-to-end smoke (see plan §24)
- [ ] Manual: force-quit watch app, widget still renders from cached file
- [ ] Manual: airplane-mode "Sync now" failure is graceful
- [ ] Manual: accent + locale propagation from phone → watch (+ next widget reload)
EOF
)"
```

- [ ] **Step 3: Return the PR URL to the user**

---

## Self-review

Run through this checklist against the spec before declaring the plan ready.

### Spec coverage

| Spec section | Plan task |
|---|---|
| §1 Goals | Whole plan |
| §2 In scope | Tasks 7–24 |
| §2 Out of scope | Not implemented (correct) |
| §3 Targets, identifiers, entitlements | Tasks 7, 18 |
| §4 WatchConnectivity data flow — transport | Tasks 10, 16 |
| §4 Wire format | Tasks 2, 3, 4 |
| §4 Phone-side lifecycle | Tasks 16, 17 |
| §4 Watch-side lifecycle | Tasks 10, 15 |
| §5 Navigation shape (TabView .page + NavigationStack) | Task 15 |
| §5 Screens (NowNext, Today, CourseDetail, Settings) | Tasks 12, 13, 14 |
| §5 State (ScheduleStore) + 10-min cooldown | Task 10 |
| §5 Theming + locale | Task 11 |
| §5 Digital crown contract | Tasks 12 (ScrollView), 13 (List), 14 (List) |
| §6 NextClassWidget + 4 families | Tasks 19, 20, 21 |
| §6 Timeline boundary computation | Task 19 |
| §6 Relevance scoring | Task 19 |
| §6 Preview snapshots | Task 19 (sampleCourse) |
| §6 Refresh discipline | Task 10 (widgetReloader), Task 19 (no WC in widget) |
| §7 HIG conformance (native components, SF Symbols, .containerBackground) | Tasks 12–14, 20 |
| §8 Localization | Task 22 |
| §9 Error & edge cases | Tasks 12 (empty states), 10 (decode failure preserves cache) |
| §10 Testing strategy | Tasks 4, 5, 6, 10, 16, 23 + manual §24 |

No gaps.

### Placeholder scan

- No "TBD", "TODO", or "implement later" in code blocks (the one "TBD" mention in §22 step 2 refers to translation status, not the plan).
- One "deferred" item: per-course color resolution in `WatchPayloadEncoder.courseColorHex` — Task 6 ships a placeholder, Task 17 replaces it with a real lookup + regression test. That's a real two-step implementation, not a placeholder gap.
- One conditional in Task 17: "If any of those notification names don't exist". The plan tells the engineer how to handle it (`grep`, reuse-or-add) rather than papering it over.
- One "(Adjust to whatever the real API is named)" in Task 17 step 4 — this is a real ambiguity that the spec didn't fully resolve. The plan is honest about it and tells the engineer how to discover the right name. Acceptable.

### Type consistency

- `WatchCourse` field set is identical across Tasks 2, 4, 6, 12, 13, 14, 19, 20, 23 — verified.
- `WatchSnapshot` fields consistent across Tasks 3, 4, 10, 19, 23.
- `ScheduleStore` API (`persist`, `shouldRequestSync`, `recordSyncRequest`, `requestSync`, `snapshot`) consistent between Task 10 and consumers in Tasks 12–15.
- `WatchSyncCoordinator` API (`activate`, `push`, `scheduleDebouncedPush`) consistent between Task 16 and Task 17.
- `SharedAppGroup.snapshotFileURL` used identically in Tasks 9, 10, 19.
- `WatchWireFormat.Key.*` constants used consistently.

No type/name drift detected.
