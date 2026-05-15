# iOS Widgets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Library / Next Class / Today / Week / Accessory widgets for TigerDuck iOS that follow system theme, system language, in-app class-table design, and live course names (custom + abbreviation toggle).

**Architecture:** New WidgetKit extension target `TigerDuckWidgets` reads a `WidgetSnapshot` from the existing `group.org.ntust.app.TigerDuck` App Group. The host app owns a `WidgetSnapshotWriter` that observes course-store / pref / locale changes, rebuilds the snapshot via a pure `WidgetSnapshotBuilder`, and calls `WidgetCenter.reloadAllTimelines()` through a debounce coordinator. Every widget view derives ongoing/next/tomorrow state at each timeline entry's `Date` using a pure `WidgetTimelineDerivation` function — the snapshot itself is timeless. Strict system theme via `@Environment(\.colorScheme)`; localization via existing submodule symlinks extended to the widget target.

**Tech Stack:** Swift 6 / SwiftUI / WidgetKit (iOS 18.0), Swift Testing framework, SwiftData (existing course store), App Groups.

**Spec:** `docs/superpowers/specs/2026-05-12-ios-widgets-design.md`

**Important repo policies:**

- **Never stage or commit `swift/TigerDuck.xcodeproj/project.pbxproj` or `.xcscheme`.** All Xcode target/scheme/capability changes are documented in the "Manual Xcode Setup" section at the top of this plan — the user performs them in Xcode. Your `git add` commands list only source files, never `.xcodeproj/` paths.
- **Never commit `docs/superpowers/`.** This plan file lives there; do not stage it.
- **Never add `Co-Authored-By` trailers to commit messages.**
- **Never use `git add -A` or `git add .`** — always list explicit file paths.

**Recommended PR breakpoints** (the plan executes top-to-bottom but the user may pause for review at any of these):

- After Task 13 — snapshot infrastructure + URL routing + Library Shortcut working end-to-end (minimum viable PR)
- After Task 18 — Library + NextClass widgets live
- After Task 22 — Library + NextClass + Today + Week widgets live
- After Task 25 — Accessory bundle complete (full v1)

---

## Manual Xcode Setup (User performs in Xcode — NOT automated)

Before starting Task 1, the user completes these steps. They cannot be done from source code because they modify `project.pbxproj` and entitlements files that are out of repo policy.

1. **New target:** File → New → Target → "Widget Extension". Name: `TigerDuckWidgets`. Bundle ID: `org.ntust.app.TigerDuck1.TigerDuckWidgets`. Include Configuration Intent: NO. Embed in: `TigerDuck`. Minimum iOS Deployment: 18.0.
2. **App Group capability** on `TigerDuckWidgets` target → Signing & Capabilities → + Capability → App Groups → check `group.org.ntust.app.TigerDuck`. (Should already exist as a group from the Live Activity extension. Create it if not.)
3. **App Group capability** on `TigerDuck` target — verify `group.org.ntust.app.TigerDuck` is checked. Add it locally if absent.
4. **URL Type** on `TigerDuck` target → Info tab → URL Types → +. Identifier: `org.ntust.app.TigerDuck.widgetLinks`, URL Schemes: `tigerduck`.
5. **TigerDuckWidgets in xcscheme:** Edit Scheme → Build → ensure `TigerDuckWidgets` is in the build list (it's added automatically when you embed the extension, but verify).
6. **Folder structure:** delete the auto-generated `TigerDuckWidgets/TigerDuckWidgets.swift` file Xcode created. The plan's first task replaces it with the proper bundle file.
7. Set signing team on `TigerDuckWidgets` to match the main app.

After completing these, run a clean build (`Cmd-Shift-K` then `Cmd-B`) — it should compile with the auto-generated placeholder widget. Then proceed to Task 1.

---

## File Structure

**New files (committed to repo):**

```
swift/TigerDuckWidgets/                                   ← Extension target sources
├── TigerDuckWidgetsBundle.swift                          ← @main entry
├── Snapshot/
│   └── WidgetSnapshotStore.swift                         ← Read-side facade
├── Theme/
│   └── WidgetPalette.swift
├── Logic/
│   └── WidgetTimelineDerivation.swift                    ← Pure: snapshot + Date → DerivedState
├── Widgets/
│   ├── LibraryShortcutWidget.swift
│   ├── NextClassWidget.swift
│   ├── TodayWidget.swift
│   ├── WeekWidget.swift
│   └── AccessoryWidget.swift
├── Views/
│   ├── LibraryShortcutView.swift
│   ├── NextClassView.swift
│   ├── TodayListView.swift
│   ├── WeekGridView.swift
│   └── AccessoryViews.swift
└── Resources/                                            ← .lproj symlinks here

swift/TigerDuck/Widgets/                                  ← App-side widget plumbing
├── WidgetSnapshot.swift                                  ← Shared Codable contract (both targets)
├── WidgetSnapshotBuilder.swift                           ← Pure builder
├── WidgetSnapshotWriter.swift                            ← Observer + write-side facade
└── WidgetReloadCoordinator.swift                         ← Debounce + WidgetCenter call

swift/TigerDuck/App/
└── WidgetURLRouter.swift                                 ← tigerduck:// URL parser

swift/TigerDuckTests/Widgets/
├── WidgetSnapshotCodableTests.swift
├── WidgetSnapshotBuilderTests.swift
├── WidgetTimelineDerivationTests.swift
├── WidgetURLRouterTests.swift
├── WidgetReloadCoordinatorTests.swift
└── WidgetLocalizationKeysTests.swift

swift/TigerDuckTests/Widgets/Fixtures/
└── WidgetSnapshot-v1.json                                ← Frozen schema fixture
```

**Modified files (committed to repo):**

```
tools/localization/sync_localizations.py                  ← Add widget extension symlinks
swift/TigerDuck/App/AppState.swift                        ← +openFromWidget, +pendingWidgetDestination
swift/TigerDuck/TigerDuckApp.swift                        ← +.onOpenURL handler
swift/TigerDuck/App/AppConstants.swift                    ← +UserDefaultsKeys.widgetSnapshot (if needed for key constant)
```

**User-managed (NOT committed by you):**

```
swift/TigerDuck.xcodeproj/project.pbxproj
swift/TigerDuck.xcodeproj/xcshareddata/xcschemes/TigerDuck.xcscheme
swift/TigerDuck/TigerDuck.entitlements
swift/TigerDuckLiveActivityExtension.entitlements
swift/TigerDuckWidgets/TigerDuckWidgets.entitlements      ← New, but user-managed
```

---

## Phase 0 — Localization sync extension

### Task 1: Extend `sync_localizations.py` to also symlink into the widgets target

**Files:**
- Modify: `tools/localization/sync_localizations.py`

- [ ] **Step 1: Read the current script**

```bash
cat tools/localization/sync_localizations.py
```

Understand the existing logic: it creates `swift/TigerDuck/<lang>.lproj` symlinks pointing to `../../localization/generated/apple/<lang>.lproj`. We're adding a second target directory `swift/TigerDuckWidgets/Resources/<lang>.lproj` pointing to `../../../localization/generated/apple/<lang>.lproj` (one extra `..` because Resources is nested one level deeper).

- [ ] **Step 2: Modify the script**

Locate the top-level constants block (around line 35). After:

```python
TIGERDUCK_DIR = ROOT / "swift" / "TigerDuck"

LEGACY_PARENT_SYMLINK = TIGERDUCK_DIR / "Localization"
LPROJ_TARGET_PREFIX = Path("..") / ".." / "localization" / "generated" / "apple"
```

Add:

```python
TIGERDUCK_WIDGETS_DIR = ROOT / "swift" / "TigerDuckWidgets" / "Resources"
WIDGETS_LPROJ_TARGET_PREFIX = Path("..") / ".." / ".." / "localization" / "generated" / "apple"
```

Then locate the function that creates the per-language symlinks (likely named `link_lproj_dirs` or similar — search for the loop that iterates over `GENERATED_APPLE_DIR.iterdir()`). After it creates the link in `TIGERDUCK_DIR`, add a parallel block that creates a link in `TIGERDUCK_WIDGETS_DIR` using `WIDGETS_LPROJ_TARGET_PREFIX`. Use `TIGERDUCK_WIDGETS_DIR.mkdir(parents=True, exist_ok=True)` once before the loop.

Sandbox handling: the existing script has special logic for Xcode-sandboxed runs (skipping `iterdir()` on the synchronized-group directory). Apply the same logic to the widgets directory — if `is_xcode_build()`, skip the stale-link cleanup pass but still create the new symlinks.

- [ ] **Step 3: Run the script manually and verify**

```bash
python3 tools/localization/sync_localizations.py
ls -la swift/TigerDuckWidgets/Resources/ | head -10
```

Expected: ~67 `<lang>.lproj` symlinks present, each pointing to a relative path under `../../../localization/generated/apple/`. Resolve one to verify:

```bash
readlink swift/TigerDuckWidgets/Resources/en.lproj
# Expected output: ../../../localization/generated/apple/en.lproj

ls swift/TigerDuckWidgets/Resources/en.lproj/Localizable.strings
# Expected: file exists, follows the symlink
```

- [ ] **Step 4: Commit**

```bash
git add tools/localization/sync_localizations.py
git commit -m "feat(widgets): extend localization sync to widget extension target"
```

Note: the new `swift/TigerDuckWidgets/Resources/` symlinks themselves should NOT be in git (they'll be regenerated on every machine). Verify `git status` shows no untracked files in `swift/TigerDuckWidgets/Resources/` after the script run; if it does, add a line to `.gitignore`:

```
swift/TigerDuckWidgets/Resources/*.lproj
```

and include `.gitignore` in the commit. The existing iOS-side `.lproj` dirs aren't tracked either — check `git check-ignore swift/TigerDuck/en.lproj` returns 0; mirror the pattern.

---

## Phase 1 — Snapshot contract

### Task 2: Define `WidgetSnapshot` Codable types (TDD)

**Files:**
- Create: `swift/TigerDuck/Widgets/WidgetSnapshot.swift`
- Create: `swift/TigerDuckTests/Widgets/WidgetSnapshotCodableTests.swift`
- Create: `swift/TigerDuckTests/Widgets/Fixtures/WidgetSnapshot-v1.json`

**Xcode target memberships (user adds manually after file creation):** `WidgetSnapshot.swift` belongs to BOTH `TigerDuck` and `TigerDuckWidgets` targets. The test file belongs to `TigerDuckTests` only.

- [ ] **Step 1: Write the failing test**

`swift/TigerDuckTests/Widgets/WidgetSnapshotCodableTests.swift`:

```swift
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
        let url = Bundle(for: type(of: self as AnyObject)).url(
            forResource: "WidgetSnapshot-v1",
            withExtension: "json",
            subdirectory: "Fixtures"
        )
        // If that fails because Swift Testing struct lookup is different, fall back:
        let fallbackPath = "swift/TigerDuckTests/Widgets/Fixtures/WidgetSnapshot-v1.json"
        let data: Data
        if let u = url { data = try Data(contentsOf: u) }
        else { data = try Data(contentsOf: URL(fileURLWithPath: fallbackPath)) }

        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(snapshot.version == 1)
        #expect(!snapshot.courses.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Build target `TigerDuckTests` in Xcode (or via `xcodebuild test -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 15'`). Expected: compile error — `WidgetSnapshot` undefined.

- [ ] **Step 3: Create the snapshot file**

`swift/TigerDuck/Widgets/WidgetSnapshot.swift`:

```swift
import Foundation

struct WidgetSnapshot: Codable, Equatable {
    let version: Int
    let generatedAt: Date
    let isLoggedIn: Bool
    let accentColorHex: UInt32
    let courses: [SnapshotCourse]
    let periodTimes: [String: PeriodTime]
    let periodOrder: [String]
    let activeWeekdays: [Int]
    let activePeriodIds: [String]

    static let currentVersion = 1
    static let storeKey = "Widget-snapshot-v1"
    static let appGroupIdentifier = "group.org.ntust.app.TigerDuck"
}

struct SnapshotCourse: Codable, Equatable {
    let courseNo: String
    let displayName: String
    let classroom: String
    let schedule: [Int: [String]]
    let colorHex: UInt32
}

struct PeriodTime: Codable, Equatable {
    let start: String   // "HH:mm"
    let end: String     // "HH:mm"
}
```

Note: `schedule: [Int: [String]]` decodes correctly from JSON when keys are stringified ints. Swift's JSONDecoder handles `[Int: [String]]` natively as long as Codable uses standard dictionary encoding (it serializes Int keys as JSON strings). This is fine.

- [ ] **Step 4: Create the fixture**

`swift/TigerDuckTests/Widgets/Fixtures/WidgetSnapshot-v1.json`:

```json
{
  "version": 1,
  "generatedAt": 1700000000,
  "isLoggedIn": true,
  "accentColorHex": 32_191,
  "courses": [
    {
      "courseNo": "EC1013701",
      "displayName": "Data Structures",
      "classroom": "TR-313",
      "schedule": { "1": ["B", "C"], "3": ["D"] },
      "colorHex": 16_733_525
    }
  ],
  "periodTimes": {
    "B": { "start": "09:10", "end": "10:00" },
    "C": { "start": "10:20", "end": "11:10" },
    "D": { "start": "11:20", "end": "12:10" }
  },
  "periodOrder": ["A", "B", "C", "D"],
  "activeWeekdays": [1, 3, 5],
  "activePeriodIds": ["B", "C", "D"]
}
```

(Numbers above are not actually JSON-legal with underscores — strip them: `32191` and `16733525`. Format as decimals.)

Correct fixture:

```json
{
  "version": 1,
  "generatedAt": 1700000000,
  "isLoggedIn": true,
  "accentColorHex": 32191,
  "courses": [
    {
      "courseNo": "EC1013701",
      "displayName": "Data Structures",
      "classroom": "TR-313",
      "schedule": { "1": ["B", "C"], "3": ["D"] },
      "colorHex": 16733525
    }
  ],
  "periodTimes": {
    "B": { "start": "09:10", "end": "10:00" },
    "C": { "start": "10:20", "end": "11:10" },
    "D": { "start": "11:20", "end": "12:10" }
  },
  "periodOrder": ["A", "B", "C", "D"],
  "activeWeekdays": [1, 3, 5],
  "activePeriodIds": ["B", "C", "D"]
}
```

- [ ] **Step 5: User adds files to targets in Xcode**

Tell the user: drag `WidgetSnapshot.swift` into the Xcode project navigator. In File Inspector, check BOTH `TigerDuck` AND `TigerDuckWidgets` under "Target Membership." Drag `WidgetSnapshot-v1.json` to `TigerDuckTests/Widgets/Fixtures/` group; check `TigerDuckTests` only; also tick "Copy items if needed" if Xcode asks.

- [ ] **Step 6: Run tests, verify they pass**

In Xcode: Cmd-U. Or:

```bash
xcodebuild test -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:TigerDuckTests/WidgetSnapshotCodableTests
```

Expected: both tests pass.

- [ ] **Step 7: Commit**

```bash
git add swift/TigerDuck/Widgets/WidgetSnapshot.swift \
        swift/TigerDuckTests/Widgets/WidgetSnapshotCodableTests.swift \
        swift/TigerDuckTests/Widgets/Fixtures/WidgetSnapshot-v1.json
git commit -m "feat(widgets): define WidgetSnapshot Codable contract"
```

---

### Task 3: `WidgetSnapshotBuilder` (pure function, TDD)

**Files:**
- Create: `swift/TigerDuck/Widgets/WidgetSnapshotBuilder.swift`
- Create: `swift/TigerDuckTests/Widgets/WidgetSnapshotBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

`swift/TigerDuckTests/Widgets/WidgetSnapshotBuilderTests.swift`:

```swift
import Foundation
import Testing
@testable import TigerDuck

struct WidgetSnapshotBuilderTests {
    @Test func builds_emptyState_whenNotLoggedIn() {
        let input = WidgetSnapshotBuilder.Input(
            courses: [],
            customNames: [:],
            isLoggedIn: false,
            accentColorHex: 0x007AFF,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        #expect(snapshot.isLoggedIn == false)
        #expect(snapshot.courses.isEmpty)
        #expect(snapshot.version == WidgetSnapshot.currentVersion)
    }

    @Test func resolvesDisplayName_customNameWins() {
        let course = SDCourse.fixture(
            courseNo: "EC1013701",
            courseName: "資料結構與演算法",
            classroom: "TR-313",
            schedule: [1: ["B"]]
        )
        let input = WidgetSnapshotBuilder.Input(
            courses: [course],
            customNames: ["EC1013701": "DS"],
            isLoggedIn: true,
            accentColorHex: 0x007AFF,
            now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        #expect(snapshot.courses.first?.displayName == "DS")
    }

    @Test func resolvesDisplayName_fallsBackToCourseName() {
        let course = SDCourse.fixture(
            courseNo: "EC1013701",
            courseName: "Data Structures",
            classroom: "TR-313",
            schedule: [1: ["B"]]
        )
        let input = WidgetSnapshotBuilder.Input(
            courses: [course],
            customNames: [:],
            isLoggedIn: true,
            accentColorHex: 0x007AFF,
            now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        #expect(snapshot.courses.first?.displayName == "Data Structures")
    }

    @Test func activeWeekdays_includesWeekendOnlyIfScheduled() {
        let weekdayOnly = SDCourse.fixture(courseNo: "A", courseName: "A", classroom: "",
                                           schedule: [1: ["B"], 3: ["C"]])
        let withSaturday = SDCourse.fixture(courseNo: "B", courseName: "B", classroom: "",
                                            schedule: [6: ["B"]])
        let input = WidgetSnapshotBuilder.Input(
            courses: [weekdayOnly, withSaturday],
            customNames: [:], isLoggedIn: true, accentColorHex: 0, now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        #expect(snapshot.activeWeekdays == [1, 2, 3, 4, 5, 6])
    }

    @Test func activePeriodIds_inChronologicalOrder() {
        let course = SDCourse.fixture(
            courseNo: "A", courseName: "A", classroom: "",
            schedule: [1: ["D", "B"], 2: ["C"]]
        )
        let input = WidgetSnapshotBuilder.Input(
            courses: [course], customNames: [:], isLoggedIn: true,
            accentColorHex: 0, now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        // Default visible periods come from AppConstants.Periods.defaultVisible;
        // expect at minimum the course's used periods appear in chronological order.
        let usedPositions = ["B", "C", "D"].map { snapshot.activePeriodIds.firstIndex(of: $0)! }
        #expect(usedPositions == usedPositions.sorted())
    }
}

extension SDCourse {
    /// Convenience test factory — adapt to whatever SDCourse's actual init is.
    /// (See SDCourse.swift for the real signature. This fixture is for tests only.)
    static func fixture(
        courseNo: String,
        courseName: String,
        classroom: String,
        schedule: [Int: [String]]
    ) -> SDCourse {
        // Implementation note: SDCourse is a SwiftData @Model. Use the existing
        // designated initializer. If SDCourse stores `schedule` as a different
        // shape (e.g. encoded JSON string), encode here. Refer to SDCourse.swift.
        let c = SDCourse(courseNo: courseNo, courseName: courseName,
                         classroom: classroom)
        c.scheduleMap = schedule
        return c
    }
}
```

Note: `SDCourse.fixture` needs to match the actual `SDCourse` initializer. Read `swift/TigerDuck/Models/SwiftData/SDCourse.swift` first; if its init takes different params or `schedule` is stored as encoded JSON, adapt. The fallback is to construct the snapshot input around whatever shape `SDCourse` natively supports.

- [ ] **Step 2: Run test, verify fail**

```bash
xcodebuild test -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:TigerDuckTests/WidgetSnapshotBuilderTests
```

Expected: compile error — `WidgetSnapshotBuilder` undefined.

- [ ] **Step 3: Create the builder**

`swift/TigerDuck/Widgets/WidgetSnapshotBuilder.swift`:

```swift
import Foundation

enum WidgetSnapshotBuilder {
    struct Input {
        let courses: [SDCourse]                      // canonical merged list
        let customNames: [String: String]            // courseNo → user-set name
        let isLoggedIn: Bool
        let accentColorHex: UInt32
        let now: Date
    }

    static func build(_ input: Input) -> WidgetSnapshot {
        let snapshotCourses = input.courses.map { course in
            SnapshotCourse(
                courseNo: course.courseNo,
                displayName: resolveDisplayName(course: course, customNames: input.customNames),
                classroom: course.classroom,
                schedule: course.scheduleMap,
                colorHex: resolveColorHex(course: course)
            )
        }

        return WidgetSnapshot(
            version: WidgetSnapshot.currentVersion,
            generatedAt: input.now,
            isLoggedIn: input.isLoggedIn,
            accentColorHex: input.accentColorHex,
            courses: snapshotCourses,
            periodTimes: buildPeriodTimes(),
            periodOrder: AppConstants.Periods.chronologicalOrder,
            activeWeekdays: computeActiveWeekdays(input.courses),
            activePeriodIds: computeActivePeriodIds(input.courses)
        )
    }

    private static func resolveDisplayName(
        course: SDCourse,
        customNames: [String: String]
    ) -> String {
        if let custom = customNames[course.courseNo], !custom.isEmpty {
            return custom
        }
        // NameAbbrService is already applied to course.courseName at the
        // app-state layer when the abbreviation toggle changes; we just
        // read whatever the canonical course name currently is.
        return course.courseName
    }

    private static func resolveColorHex(course: SDCourse) -> UInt32 {
        // Prefer customColorHex; fall back to deterministic palette pick.
        if let hex = course.customColorHex,
           let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) {
            return value
        }
        return hashPaletteColor(course.courseNo)
    }

    private static func hashPaletteColor(_ courseNo: String) -> UInt32 {
        // Deterministic per-course color. The exact palette lives in
        // Theme/Color+Extensions.swift; this mirrors that selection so the
        // widget matches the in-app card colors.
        let hash = courseNo.reduce(0) { acc, c in (acc &* 31 &+ Int(c.asciiValue ?? 0)) & 0x7FFFFFFF }
        let palette: [UInt32] = [
            0xFF6B6B, 0x4ECDC4, 0xFFE66D, 0x95E1D3, 0xF38181,
            0xAA96DA, 0xFCBAD3, 0xA8D8EA, 0xFFAAA5, 0xFFD3B6,
        ]
        return palette[hash % palette.count]
    }

    private static func buildPeriodTimes() -> [String: PeriodTime] {
        var dict: [String: PeriodTime] = [:]
        for periodId in AppConstants.Periods.chronologicalOrder {
            if let pair = AppConstants.PeriodTimes.mapping[periodId] {
                dict[periodId] = PeriodTime(start: pair.start, end: pair.end)
            }
        }
        return dict
    }

    private static func computeActiveWeekdays(_ courses: [SDCourse]) -> [Int] {
        var weekdays = Set([1, 2, 3, 4, 5])
        for course in courses {
            for day in course.scheduleMap.keys {
                if day == 6 || day == 7 { weekdays.insert(day) }
            }
        }
        return weekdays.sorted()
    }

    private static func computeActivePeriodIds(_ courses: [SDCourse]) -> [String] {
        var ids = Set(AppConstants.Periods.defaultVisible)
        for course in courses {
            for periods in course.scheduleMap.values {
                ids.formUnion(periods)
            }
        }
        return AppConstants.Periods.chronologicalOrder.filter { ids.contains($0) }
    }
}
```

If `AppConstants.PeriodTimes.mapping` is `[String: (String, String)]` not a struct with `.start/.end`, adapt:

```swift
let pair = AppConstants.PeriodTimes.mapping[periodId]
dict[periodId] = PeriodTime(start: pair.0, end: pair.1)
```

Read `swift/TigerDuck/App/AppConstants.swift` before writing this — the exact shape may differ. Adapt `course.scheduleMap` to whatever SDCourse exposes; if it's stored as encoded JSON, decode here. If `course.customColorHex` doesn't exist, drop that branch.

- [ ] **Step 4: User adds file to TigerDuck target only**

Same as Task 2 step 5, but only check `TigerDuck` (not the widget target — builder lives in app side).

- [ ] **Step 5: Run tests, verify pass**

Same xcodebuild command as Step 2. Expected: 5 tests pass.

If any test fails because `SDCourse.fixture` doesn't compile cleanly with your actual SDCourse init — fix it inline. The fixture exists only to feed the builder; its shape doesn't matter as long as the test exercises the resolution logic.

- [ ] **Step 6: Commit**

```bash
git add swift/TigerDuck/Widgets/WidgetSnapshotBuilder.swift \
        swift/TigerDuckTests/Widgets/WidgetSnapshotBuilderTests.swift
git commit -m "feat(widgets): pure builder for WidgetSnapshot from app state"
```

---

### Task 4: `WidgetSnapshotStore` (read + write facade)

**Files:**
- Create: `swift/TigerDuckWidgets/Snapshot/WidgetSnapshotStore.swift`

Add to BOTH targets (`TigerDuck` and `TigerDuckWidgets`) — the same file serves as the read side for the extension and write side for the app. Single source of truth keeps the suiteName + key + encoder/decoder consistent.

- [ ] **Step 1: Create the store**

`swift/TigerDuckWidgets/Snapshot/WidgetSnapshotStore.swift`:

```swift
import Foundation
import os

/// Persists the latest `WidgetSnapshot` so the widget extension can read what
/// the app writes via a shared App Group. Mirrors the SharedSnapshotStore
/// pattern from the Live Activity extension.
nonisolated final class WidgetSnapshotStore {
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Widget")

    init(appGroupIdentifier: String = WidgetSnapshot.appGroupIdentifier) {
        if let suite = UserDefaults(suiteName: appGroupIdentifier) {
            self.defaults = suite
        } else {
            assertionFailure(
                "App Group suite '\(appGroupIdentifier)' unavailable — verify `com.apple.security.application-groups` is populated in BOTH the TigerDuck app AND TigerDuckWidgets extension entitlements and that the App Group capability is enabled on each target."
            )
            self.defaults = .standard
            logger.error("App Group suite '\(appGroupIdentifier, privacy: .public)' unavailable — widget will not see app-side snapshots")
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        self.decoder = dec
    }

    func readSnapshot() -> WidgetSnapshot? {
        guard let data = defaults.data(forKey: WidgetSnapshot.storeKey) else { return nil }
        do {
            let snapshot = try decoder.decode(WidgetSnapshot.self, from: data)
            guard snapshot.version == WidgetSnapshot.currentVersion else {
                logger.notice("widget snapshot version \(snapshot.version) does not match expected \(WidgetSnapshot.currentVersion); treating as missing")
                return nil
            }
            return snapshot
        } catch {
            logger.error("widget snapshot decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func writeSnapshot(_ snapshot: WidgetSnapshot?) {
        guard let snapshot else {
            defaults.removeObject(forKey: WidgetSnapshot.storeKey)
            return
        }
        do {
            let data = try encoder.encode(snapshot)
            defaults.set(data, forKey: WidgetSnapshot.storeKey)
        } catch {
            logger.error("widget snapshot encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

The `dateEncodingStrategy = .secondsSince1970` matches the fixture in Task 2 (which uses `"generatedAt": 1700000000`).

- [ ] **Step 2: User adds file to both targets**

Tell user: drag `swift/TigerDuckWidgets/Snapshot/WidgetSnapshotStore.swift` into the Xcode navigator. In File Inspector, check BOTH `TigerDuck` AND `TigerDuckWidgets`.

- [ ] **Step 3: Build to verify it compiles**

```bash
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: BUILD SUCCEEDED. The store has no consumers yet but must compile.

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWidgets/Snapshot/WidgetSnapshotStore.swift
git commit -m "feat(widgets): App Group store for WidgetSnapshot"
```

---

### Task 5: `WidgetReloadCoordinator` (debounce, TDD)

**Files:**
- Create: `swift/TigerDuck/Widgets/WidgetReloadCoordinator.swift`
- Create: `swift/TigerDuckTests/Widgets/WidgetReloadCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

`swift/TigerDuckTests/Widgets/WidgetReloadCoordinatorTests.swift`:

```swift
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WidgetReloadCoordinatorTests {
    final class FakeReloader: WidgetReloadCoordinator.Reloader {
        var callCount = 0
        func reloadAllTimelines() { callCount += 1 }
    }

    @Test func collapses_rapidCalls_intoOne() async throws {
        let fake = FakeReloader()
        let coordinator = WidgetReloadCoordinator(reloader: fake, debounceMs: 50)
        for _ in 0..<5 { coordinator.requestReload() }
        try await Task.sleep(for: .milliseconds(120))
        #expect(fake.callCount == 1)
    }

    @Test func fires_oncePerWindow() async throws {
        let fake = FakeReloader()
        let coordinator = WidgetReloadCoordinator(reloader: fake, debounceMs: 50)
        coordinator.requestReload()
        try await Task.sleep(for: .milliseconds(120))
        coordinator.requestReload()
        try await Task.sleep(for: .milliseconds(120))
        #expect(fake.callCount == 2)
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Same xcodebuild test command. Expected: compile error — `WidgetReloadCoordinator` undefined.

- [ ] **Step 3: Create the coordinator**

`swift/TigerDuck/Widgets/WidgetReloadCoordinator.swift`:

```swift
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class WidgetReloadCoordinator {
    protocol Reloader {
        func reloadAllTimelines()
    }

    struct WidgetKitReloader: Reloader {
        func reloadAllTimelines() {
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }

    private let reloader: Reloader
    private let debounce: TimeInterval
    private var pendingTask: Task<Void, Never>?

    init(reloader: Reloader = WidgetKitReloader(), debounceMs: Int = 300) {
        self.reloader = reloader
        self.debounce = TimeInterval(debounceMs) / 1000.0
    }

    func requestReload() {
        pendingTask?.cancel()
        let interval = debounce
        let reloader = reloader
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            reloader.reloadAllTimelines()
        }
    }
}
```

- [ ] **Step 4: User adds to TigerDuck target only**

- [ ] **Step 5: Run tests, verify pass**

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
git add swift/TigerDuck/Widgets/WidgetReloadCoordinator.swift \
        swift/TigerDuckTests/Widgets/WidgetReloadCoordinatorTests.swift
git commit -m "feat(widgets): debounced reload coordinator"
```

---

### Task 6: `WidgetSnapshotWriter` (observers + write pipeline)

**Files:**
- Create: `swift/TigerDuck/Widgets/WidgetSnapshotWriter.swift`

No TDD here — this is integration glue that observes existing app state. We verify it manually via the manual test plan.

- [ ] **Step 1: Create the writer**

`swift/TigerDuck/Widgets/WidgetSnapshotWriter.swift`:

```swift
import Foundation
import Combine
import os

/// Owns the widget snapshot write pipeline. Listens for course-store, prefs,
/// auth, and locale changes; rebuilds the snapshot via WidgetSnapshotBuilder;
/// writes it to the App Group; triggers a debounced widget reload.
@MainActor
final class WidgetSnapshotWriter {
    private let store: WidgetSnapshotStore
    private let coordinator: WidgetReloadCoordinator
    private let appState: AppState
    private let courseProvider: CanonicalCourseProvider
    private let cache: DataCache
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "WidgetWriter")

    private var cancellables: Set<AnyCancellable> = []

    init(
        appState: AppState,
        cache: DataCache = .shared,
        store: WidgetSnapshotStore = WidgetSnapshotStore(),
        coordinator: WidgetReloadCoordinator = WidgetReloadCoordinator(),
        courseProvider: CanonicalCourseProvider = CanonicalCourseProvider()
    ) {
        self.appState = appState
        self.cache = cache
        self.store = store
        self.coordinator = coordinator
        self.courseProvider = courseProvider
        observe()
    }

    /// Idempotent — call at app cold-start and again on any state change you
    /// want reflected in widgets.
    func regenerate() {
        let courses = courseProvider.currentCourses()
        let customNames = cache.loadCourseCustomNames()
        let snapshot = WidgetSnapshotBuilder.build(
            .init(
                courses: courses,
                customNames: customNames,
                isLoggedIn: appState.isAuthenticated,
                accentColorHex: UInt32(bitPattern: Int32(truncatingIfNeeded: appState.accentColorHex)),
                now: Date()
            )
        )
        store.writeSnapshot(snapshot)
        coordinator.requestReload()
    }

    private func observe() {
        // Locale changes (system language switch).
        NotificationCenter.default
            .publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .sink { [weak self] _ in self?.regenerate() }
            .store(in: &cancellables)

        // Course-store writes — listen for whatever notification DataCache or
        // CourseSelectionService already posts when courses change. If none
        // exists, post one explicitly from the relevant write paths. The
        // simplest path: piggyback on AppState's @Published `courses` or
        // equivalent via objectWillChange.
        appState.objectWillChange
            .sink { [weak self] in
                // Coalesce: requestReload is already debounced.
                self?.regenerate()
            }
            .store(in: &cancellables)
    }
}
```

Caveats noted in the code: `appState.isAuthenticated` and `appState.accentColorHex` must be real properties. Read `swift/TigerDuck/App/AppState.swift` to confirm names. If `isAuthenticated` is exposed differently (e.g., as a service), adapt. The `appState.objectWillChange` subscription is coarse — every AppState mutation triggers a regenerate. Coupled with the debounce coordinator, this is acceptable for v1. If it proves chatty in profiling, narrow the observation to specific publishers.

- [ ] **Step 2: User adds to TigerDuck target only**

- [ ] **Step 3: Build to verify it compiles**

Same xcodebuild build command. If references like `appState.isAuthenticated` don't exist, the build will fail with a clear error — fix by reading the actual AppState and renaming.

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuck/Widgets/WidgetSnapshotWriter.swift
git commit -m "feat(widgets): writer observes app state and pushes snapshots"
```

---

### Task 7: Wire `WidgetSnapshotWriter` into app lifecycle

**Files:**
- Modify: `swift/TigerDuck/TigerDuckApp.swift`

- [ ] **Step 1: Read TigerDuckApp.swift**

```bash
cat swift/TigerDuck/TigerDuckApp.swift
```

Locate the `@main` struct's `body` and any `init()` or `@StateObject`/`@State` declarations for AppState.

- [ ] **Step 2: Add the writer**

Add a `@State` property next to AppState:

```swift
@State private var widgetSnapshotWriter: WidgetSnapshotWriter?
```

(Or use `@StateObject` if AppState is an `ObservableObject`. Match the surrounding style.)

In the scene's `.task` or `.onAppear` modifier on the root view (whichever the file already uses for cold-start side effects), initialize and trigger:

```swift
.task {
    if widgetSnapshotWriter == nil {
        widgetSnapshotWriter = WidgetSnapshotWriter(appState: appState)
        widgetSnapshotWriter?.regenerate()
    }
}
```

If `appState` is captured by a different name (`state`, `appState`, etc.), match that.

- [ ] **Step 3: Build, verify success**

```bash
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuck/TigerDuckApp.swift
git commit -m "feat(widgets): start snapshot writer at app cold-start"
```

---

## Phase 2 — URL routing

### Task 8: `WidgetURLRouter` (pure function, TDD)

**Files:**
- Create: `swift/TigerDuck/App/WidgetURLRouter.swift`
- Create: `swift/TigerDuckTests/Widgets/WidgetURLRouterTests.swift`

- [ ] **Step 1: Write the failing test**

`swift/TigerDuckTests/Widgets/WidgetURLRouterTests.swift`:

```swift
import Foundation
import Testing
@testable import TigerDuck

struct WidgetURLRouterTests {
    @Test func routesLibrary() {
        let url = URL(string: "tigerduck://library")!
        #expect(WidgetURLRouter.route(url) == .library)
    }

    @Test func routesClassTable() {
        let url = URL(string: "tigerduck://classtable")!
        #expect(WidgetURLRouter.route(url) == .classTable)
    }

    @Test func rejectsUnknownHost() {
        let url = URL(string: "tigerduck://nope")!
        #expect(WidgetURLRouter.route(url) == nil)
    }

    @Test func rejectsWrongScheme() {
        let url = URL(string: "https://library")!
        #expect(WidgetURLRouter.route(url) == nil)
    }

    @Test func handlesMalformedGracefully() {
        let url = URL(string: "tigerduck://")!
        #expect(WidgetURLRouter.route(url) == nil)
    }
}
```

- [ ] **Step 2: Run, verify fail**

Expected: compile error — `WidgetURLRouter` undefined.

- [ ] **Step 3: Create the router**

`swift/TigerDuck/App/WidgetURLRouter.swift`:

```swift
import Foundation

enum WidgetDestination: Equatable {
    case library
    case classTable
}

enum WidgetURLRouter {
    static func route(_ url: URL) -> WidgetDestination? {
        guard url.scheme == "tigerduck", let host = url.host, !host.isEmpty else {
            return nil
        }
        switch host {
        case "library":    return .library
        case "classtable": return .classTable
        default:           return nil
        }
    }
}
```

- [ ] **Step 4: User adds file to TigerDuck target only**

- [ ] **Step 5: Run tests, verify pass**

Expected: 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add swift/TigerDuck/App/WidgetURLRouter.swift \
        swift/TigerDuckTests/Widgets/WidgetURLRouterTests.swift
git commit -m "feat(widgets): tigerduck:// URL router for widget tap targets"
```

---

### Task 9: Wire `.onOpenURL` and `AppState.openFromWidget`

**Files:**
- Modify: `swift/TigerDuck/App/AppState.swift`
- Modify: `swift/TigerDuck/TigerDuckApp.swift`

- [ ] **Step 1: Read AppState.swift around the tab-selection area**

```bash
grep -n "selectedTab\|@Published" swift/TigerDuck/App/AppState.swift | head -30
```

Identify the property that controls the currently-selected tab and any "navigate to library" path already used by push or in-app links.

- [ ] **Step 2: Add `openFromWidget` to AppState**

In `swift/TigerDuck/App/AppState.swift`, add a property and method. Exact placement depends on the file's existing structure — add near other navigation state.

```swift
/// Set by `onOpenURL` when the app is launched cold by a widget tap and
/// SwiftData stores haven't finished loading. Drained by `processPendingWidgetDestination`
/// once `bootCompleted == true`.
@Published var pendingWidgetDestination: WidgetDestination?

func openFromWidget(_ destination: WidgetDestination) {
    if !bootCompleted {
        pendingWidgetDestination = destination
        return
    }
    apply(widgetDestination: destination)
}

func processPendingWidgetDestination() {
    guard let destination = pendingWidgetDestination else { return }
    pendingWidgetDestination = nil
    apply(widgetDestination: destination)
}

private func apply(widgetDestination destination: WidgetDestination) {
    switch destination {
    case .library:
        // Library has a feature-disabled flag; when disabled, the existing
        // settings-prompt sheet handles the redirect. We just navigate to
        // the library tab/screen — the existing guard kicks in.
        selectedTab = .library
    case .classTable:
        selectedTab = .classTable
    }
}
```

Adapt to the actual `selectedTab` enum cases (search for the existing enum). If `bootCompleted` doesn't exist by that name, find the equivalent boot-state flag or introduce one. If selectedTab is set differently (e.g., a router struct), match that pattern.

- [ ] **Step 3: Wire `.onOpenURL` in TigerDuckApp.swift**

In the root scene's view chain, add (or extend an existing `.onOpenURL`):

```swift
.onOpenURL { url in
    guard let destination = WidgetURLRouter.route(url) else { return }
    appState.openFromWidget(destination)
}
```

If there's already an `.onOpenURL` (e.g., for push deep-links), add the widget routing as an additional branch inside it rather than stacking another modifier.

- [ ] **Step 4: Drain pending destination on bootCompleted**

Find where `bootCompleted` is set to `true` (likely after SwiftData stores finish loading + first auth check). Immediately after that assignment, call `processPendingWidgetDestination()`.

- [ ] **Step 5: Build, verify success**

```bash
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 15'
```

- [ ] **Step 6: Commit**

```bash
git add swift/TigerDuck/App/AppState.swift swift/TigerDuck/TigerDuckApp.swift
git commit -m "feat(widgets): route tigerduck:// URLs to library/classtable tabs"
```

---

## Phase 3 — Widget infrastructure (palette, timeline derivation)

### Task 10: `WidgetPalette`

**Files:**
- Create: `swift/TigerDuckWidgets/Theme/WidgetPalette.swift`

- [ ] **Step 1: Create the palette**

```swift
import SwiftUI

struct WidgetPalette {
    let background: Color
    let surface: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let emptyCell: Color
    let highlight: Color

    static func resolve(snapshot: WidgetSnapshot, colorScheme: ColorScheme) -> WidgetPalette {
        let base = colorScheme == .dark ? Self.dark : Self.light
        return WidgetPalette(
            background: base.background,
            surface: base.surface,
            onSurface: base.onSurface,
            onSurfaceVariant: base.onSurfaceVariant,
            emptyCell: base.emptyCell,
            highlight: Color(hex: snapshot.accentColorHex)
        )
    }

    private static let light = WidgetPalette(
        background: Color(hex: 0xF5F5F5),
        surface: Color(hex: 0xFFFFFF),
        onSurface: Color(hex: 0x1C1C1E),
        onSurfaceVariant: Color(hex: 0x6E6E73),
        emptyCell: Color(hex: 0xECECEC),
        highlight: .blue   // overridden by resolve()
    )

    private static let dark = WidgetPalette(
        background: Color(hex: 0x1C1C1E),
        surface: Color(hex: 0x2C2C2E),
        onSurface: Color(hex: 0xF5F5F5),
        onSurfaceVariant: Color(hex: 0x8E8E93),
        emptyCell: Color(hex: 0x2C2C2E),
        highlight: .blue
    )
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
```

Note: the app already has a `Color(hex:)` initializer in `swift/TigerDuck/Theme/Color+Extensions.swift`. If you'd rather reuse that file, add it to BOTH targets instead of duplicating the extension here. For simplicity v1 duplicates the 4-line init (it's trivial, and avoids dragging the app's full theme file into the extension).

- [ ] **Step 2: User adds file to TigerDuckWidgets target only**

- [ ] **Step 3: Build, verify**

```bash
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 15'
```

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWidgets/Theme/WidgetPalette.swift
git commit -m "feat(widgets): palette tokens matching Android WidgetTheme"
```

---

### Task 11: `WidgetTimelineDerivation` (pure, TDD)

**Files:**
- Create: `swift/TigerDuckWidgets/Logic/WidgetTimelineDerivation.swift`
- Create: `swift/TigerDuckTests/Widgets/WidgetTimelineDerivationTests.swift`

- [ ] **Step 1: Write the failing test**

`swift/TigerDuckTests/Widgets/WidgetTimelineDerivationTests.swift`:

```swift
import Foundation
import Testing
@testable import TigerDuck

struct WidgetTimelineDerivationTests {
    private func snapshot(courses: [SnapshotCourse]) -> WidgetSnapshot {
        WidgetSnapshot(
            version: 1,
            generatedAt: Date(),
            isLoggedIn: true,
            accentColorHex: 0x007AFF,
            courses: courses,
            periodTimes: [
                "A": PeriodTime(start: "08:10", end: "09:00"),
                "B": PeriodTime(start: "09:10", end: "10:00"),
                "C": PeriodTime(start: "10:20", end: "11:10"),
            ],
            periodOrder: ["A", "B", "C"],
            activeWeekdays: [1, 2, 3, 4, 5],
            activePeriodIds: ["A", "B", "C"]
        )
    }

    private func course(courseNo: String, displayName: String, weekday: Int, periods: [String]) -> SnapshotCourse {
        SnapshotCourse(
            courseNo: courseNo,
            displayName: displayName,
            classroom: "",
            schedule: [weekday: periods],
            colorHex: 0
        )
    }

    /// Helper: Monday at H:M in current calendar (test runs in same TZ as device).
    private func monday(_ hour: Int, _ minute: Int) -> Date {
        // Pick a fixed Monday for deterministic tests.
        var components = DateComponents()
        components.year = 2024; components.month = 1; components.day = 1  // 2024-01-01 was a Monday
        components.hour = hour; components.minute = minute
        return Calendar.current.date(from: components)!
    }

    @Test func notLoggedIn_emitsSignInState() {
        var snap = snapshot(courses: [])
        snap = WidgetSnapshot(
            version: snap.version, generatedAt: snap.generatedAt,
            isLoggedIn: false, accentColorHex: snap.accentColorHex,
            courses: snap.courses, periodTimes: snap.periodTimes,
            periodOrder: snap.periodOrder, activeWeekdays: snap.activeWeekdays,
            activePeriodIds: snap.activePeriodIds
        )
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        #expect(derived == .signInRequired)
    }

    @Test func ongoing_singleCourse() {
        let courses = [course(courseNo: "A", displayName: "DS", weekday: 1, periods: ["B"])]
        let snap = snapshot(courses: courses)
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        if case .ongoing(let list) = derived {
            #expect(list.count == 1)
            #expect(list[0].course.displayName == "DS")
            #expect(list[0].progress > 0 && list[0].progress < 1)
        } else {
            Issue.record("Expected .ongoing, got \(derived)")
        }
    }

    @Test func nextToday_betweenPeriods() {
        let earlier = course(courseNo: "A", displayName: "Early", weekday: 1, periods: ["A"])
        let later = course(courseNo: "B", displayName: "Later", weekday: 1, periods: ["C"])
        let snap = snapshot(courses: [earlier, later])
        // 09:30 — Earlier ended at 09:00; Later starts at 10:20.
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        if case .nextToday(let info) = derived {
            #expect(info.course.displayName == "Later")
        } else {
            Issue.record("Expected .nextToday, got \(derived)")
        }
    }

    @Test func tomorrowFirst_whenNothingLeftToday() {
        let earlier = course(courseNo: "A", displayName: "MonClass", weekday: 1, periods: ["A"])
        let tomorrow = course(courseNo: "B", displayName: "TuesClass", weekday: 2, periods: ["B"])
        let snap = snapshot(courses: [earlier, tomorrow])
        // 18:00 Monday — nothing left today
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(18, 0))
        if case .tomorrowFirst(let info) = derived {
            #expect(info.course.displayName == "TuesClass")
            #expect(info.startTime == "09:10")
        } else {
            Issue.record("Expected .tomorrowFirst, got \(derived)")
        }
    }

    @Test func noMoreClasses_atAll() {
        let snap = snapshot(courses: [])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        #expect(derived == .noMoreClasses)
    }
}
```

- [ ] **Step 2: Run, verify fail**

Expected: compile error.

- [ ] **Step 3: Create the derivation**

`swift/TigerDuckWidgets/Logic/WidgetTimelineDerivation.swift`:

```swift
import Foundation

enum WidgetDerivedState: Equatable {
    case signInRequired
    case ongoing([OngoingInfo])           // 1 or more (cap at 2 for layouts; logic stays general)
    case nextToday(NextInfo)
    case tomorrowFirst(NextInfo)
    case noMoreClasses

    struct OngoingInfo: Equatable {
        let course: SnapshotCourse
        let startTime: String              // "HH:mm"
        let endTime: String
        let periodRange: String            // e.g. "B" or "B–C"
        let progress: Double               // 0.0…1.0
    }

    struct NextInfo: Equatable {
        let course: SnapshotCourse
        let startTime: String
        let periodRange: String
    }
}

enum WidgetTimelineDerivation {
    static func derive(snapshot: WidgetSnapshot, at date: Date) -> WidgetDerivedState {
        guard snapshot.isLoggedIn else { return .signInRequired }
        guard !snapshot.courses.isEmpty else { return .noMoreClasses }

        let weekday = weekdayFor(date)
        let nowMin = minuteOfDayFor(date)
        let order = snapshot.periodOrder

        // 1. Ongoing courses (any course whose any period contains nowMin)
        let ongoing = snapshot.courses.compactMap { course -> WidgetDerivedState.OngoingInfo? in
            guard let periods = course.schedule[weekday]?.sorted(by: { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }),
                  !periods.isEmpty else { return nil }
            let first = periods.first!
            let last = periods.last!
            guard let firstStart = parseHm(snapshot.periodTimes[first]?.start),
                  let lastEnd = parseHm(snapshot.periodTimes[last]?.end),
                  nowMin >= firstStart, nowMin < lastEnd else { return nil }
            let progress = lastEnd > firstStart
                ? Double(nowMin - firstStart) / Double(lastEnd - firstStart)
                : 0
            return .init(
                course: course,
                startTime: snapshot.periodTimes[first]?.start ?? "",
                endTime: snapshot.periodTimes[last]?.end ?? "",
                periodRange: periods.count > 1 ? "\(first)–\(last)" : first,
                progress: progress.clamped(to: 0...1)
            )
        }
        if !ongoing.isEmpty { return .ongoing(ongoing) }

        // 2. Next today (any course whose first period today starts in the future)
        let candidates = snapshot.courses.compactMap { course -> (SnapshotCourse, Int, String)? in
            guard let periods = course.schedule[weekday]?.sorted(by: { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }) else { return nil }
            for periodId in periods {
                if let start = parseHm(snapshot.periodTimes[periodId]?.start), start > nowMin {
                    return (course, start, periodId)
                }
            }
            return nil
        }
        if let pick = candidates.min(by: { $0.1 < $1.1 }) {
            return .nextToday(.init(
                course: pick.0,
                startTime: snapshot.periodTimes[pick.2]?.start ?? "",
                periodRange: pick.2
            ))
        }

        // 3. Tomorrow first: scan ahead up to 7 weekdays
        for offset in 1...7 {
            let target = ((weekday - 1 + offset) % 7) + 1
            let dayCourses = snapshot.courses.compactMap { course -> (SnapshotCourse, String)? in
                guard let periods = course.schedule[target]?.sorted(by: { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }),
                      let firstPeriod = periods.first else { return nil }
                return (course, firstPeriod)
            }
            if let pick = dayCourses.min(by: { order.firstIndex(of: $0.1)! < order.firstIndex(of: $1.1)! }) {
                return .tomorrowFirst(.init(
                    course: pick.0,
                    startTime: snapshot.periodTimes[pick.1]?.start ?? "",
                    periodRange: pick.1
                ))
            }
        }

        return .noMoreClasses
    }

    // MARK: - Helpers

    static func weekdayFor(_ date: Date) -> Int {
        // Calendar.component returns 1=Sun, 2=Mon, …, 7=Sat. We want 1=Mon … 7=Sun.
        let raw = Calendar(identifier: .gregorian).component(.weekday, from: date)
        return raw == 1 ? 7 : raw - 1
    }

    static func minuteOfDayFor(_ date: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        return h * 60 + m
    }

    static func parseHm(_ string: String?) -> Int? {
        guard let s = string else { return nil }
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
```

- [ ] **Step 4: User adds file to BOTH TigerDuck and TigerDuckWidgets targets**

Both — the app needs it for testing; the extension needs it for runtime use.

- [ ] **Step 5: Run tests, verify pass**

Expected: 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add swift/TigerDuckWidgets/Logic/WidgetTimelineDerivation.swift \
        swift/TigerDuckTests/Widgets/WidgetTimelineDerivationTests.swift
git commit -m "feat(widgets): pure derivation of ongoing/next/tomorrow state"
```

---

### Task 12: Timeline entry generator helper

**Files:**
- Modify: `swift/TigerDuckWidgets/Logic/WidgetTimelineDerivation.swift` (add static)

- [ ] **Step 1: Add the entry-date generator**

Append to `WidgetTimelineDerivation`:

```swift
extension WidgetTimelineDerivation {
    /// Returns the set of `Date`s at which the widget should refresh:
    ///   - `now` itself
    ///   - every remaining period start AND end today
    ///   - midnight at the start of tomorrow
    ///
    /// Deduplicated and sorted. Callers feed these into TimelineEntry construction.
    static func entryDates(snapshot: WidgetSnapshot, after now: Date,
                           calendar: Calendar = Calendar(identifier: .gregorian)) -> [Date] {
        var result: Set<Date> = [now]
        let weekday = weekdayFor(now)
        let dayStart = calendar.startOfDay(for: now)

        for course in snapshot.courses {
            guard let periods = course.schedule[weekday] else { continue }
            for periodId in periods {
                if let pt = snapshot.periodTimes[periodId] {
                    if let start = parseHm(pt.start),
                       let date = calendar.date(byAdding: .minute, value: start, to: dayStart),
                       date > now {
                        result.insert(date)
                    }
                    if let end = parseHm(pt.end),
                       let date = calendar.date(byAdding: .minute, value: end, to: dayStart),
                       date > now {
                        result.insert(date)
                    }
                }
            }
        }

        if let midnight = calendar.date(byAdding: .day, value: 1, to: dayStart) {
            result.insert(midnight)
        }

        return result.sorted()
    }
}
```

- [ ] **Step 2: Build, verify**

No new test for this — exercised end-to-end by the widget providers in later tasks, and indirectly by the derivation tests when entries land at boundaries.

- [ ] **Step 3: Commit**

```bash
git add swift/TigerDuckWidgets/Logic/WidgetTimelineDerivation.swift
git commit -m "feat(widgets): timeline entry-date helper for period boundaries"
```

---

## Phase 4 — Widget bundle + first widget (vertical slice)

### Task 13: `TigerDuckWidgetsBundle` + `LibraryShortcutWidget` (vertical slice)

**Files:**
- Create: `swift/TigerDuckWidgets/TigerDuckWidgetsBundle.swift`
- Create: `swift/TigerDuckWidgets/Widgets/LibraryShortcutWidget.swift`
- Create: `swift/TigerDuckWidgets/Views/LibraryShortcutView.swift`

This is the first widget to render end-to-end. After this task, you can install the widget on the simulator's Home Screen and see it work.

- [ ] **Step 1: Create the view**

`swift/TigerDuckWidgets/Views/LibraryShortcutView.swift`:

```swift
import SwiftUI

struct LibraryShortcutView: View {
    let palette: WidgetPalette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.highlight)
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            Text(String(localized: "widget_library_shortcut_title"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(palette.onSurface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Create the widget definition**

`swift/TigerDuckWidgets/Widgets/LibraryShortcutWidget.swift`:

```swift
import WidgetKit
import SwiftUI

struct LibraryShortcutEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct LibraryShortcutProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> LibraryShortcutEntry {
        LibraryShortcutEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LibraryShortcutEntry) -> Void) {
        completion(LibraryShortcutEntry(date: Date(), snapshot: store.readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LibraryShortcutEntry>) -> Void) {
        // Library Shortcut is static — single entry, refresh at midnight only.
        let snapshot = store.readSnapshot()
        let entry = LibraryShortcutEntry(date: Date(), snapshot: snapshot)
        let midnight = Calendar(identifier: .gregorian).startOfDay(for: Date().addingTimeInterval(86_400))
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }
}

struct LibraryShortcutWidgetView: View {
    let entry: LibraryShortcutEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = entry.snapshot.map { WidgetPalette.resolve(snapshot: $0, colorScheme: colorScheme) }
            ?? WidgetPalette.resolve(snapshot: fallbackSnapshot, colorScheme: colorScheme)
        LibraryShortcutView(palette: palette)
            .containerBackground(palette.background, for: .widget)
            .widgetURL(URL(string: "tigerduck://library"))
    }

    private var fallbackSnapshot: WidgetSnapshot {
        WidgetSnapshot(
            version: 1, generatedAt: Date(), isLoggedIn: false,
            accentColorHex: 0x007AFF, courses: [], periodTimes: [:],
            periodOrder: [], activeWeekdays: [], activePeriodIds: []
        )
    }
}

struct LibraryShortcutWidget: Widget {
    let kind: String = "LibraryShortcutWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LibraryShortcutProvider()) { entry in
            LibraryShortcutWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_library_shortcut_light_label"))
        .description(String(localized: "widget_library_shortcut_light_desc"))
        .supportedFamilies([.systemSmall])
    }
}
```

- [ ] **Step 3: Create the bundle**

`swift/TigerDuckWidgets/TigerDuckWidgetsBundle.swift`:

```swift
import WidgetKit
import SwiftUI

@main
struct TigerDuckWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LibraryShortcutWidget()
        // Later tasks add: NextClassWidget(), TodayWidget(), WeekWidget(), AccessoryWidget()
    }
}
```

If Xcode auto-generated a `TigerDuckWidgets.swift` file with its own `@main`, delete it. Two `@main` declarations won't compile.

- [ ] **Step 4: User adds all three files to TigerDuckWidgets target only**

- [ ] **Step 5: Build and run**

```bash
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 15'
```

Then in Xcode: select the TigerDuckWidgets scheme, build to simulator. On the simulator's home screen, long-press → + → search "TigerDuck" → add "Library QR Shortcut" widget. Verify it renders with the library icon and "Library" label, and toggles correctly between light/dark when you change simulator appearance.

Tap the widget — the app should open via deep link to the Library tab (provided Tasks 8–9 are wired correctly, which you can confirm by setting a breakpoint in `WidgetURLRouter.route`).

- [ ] **Step 6: Commit**

```bash
git add swift/TigerDuckWidgets/TigerDuckWidgetsBundle.swift \
        swift/TigerDuckWidgets/Widgets/LibraryShortcutWidget.swift \
        swift/TigerDuckWidgets/Views/LibraryShortcutView.swift
git commit -m "feat(widgets): LibraryShortcutWidget + bundle entry point"
```

**🚦 PR Breakpoint 1:** At this point you have a fully working Library Shortcut widget end-to-end. Consider opening a PR with everything up to here if you want incremental review.

---

## Phase 5 — NextClass widget

### Task 14: `NextClassView` (state-machine SwiftUI view)

**Files:**
- Create: `swift/TigerDuckWidgets/Views/NextClassView.swift`

- [ ] **Step 1: Create the view**

`swift/TigerDuckWidgets/Views/NextClassView.swift`:

```swift
import SwiftUI
import WidgetKit

struct NextClassView: View {
    let derived: WidgetDerivedState
    let palette: WidgetPalette
    let family: WidgetFamily

    var body: some View {
        switch derived {
        case .signInRequired:
            signInBody
        case .ongoing(let infos):
            ongoingBody(infos: infos)
        case .nextToday(let info):
            nextBody(info: info, kind: .nextToday)
        case .tomorrowFirst(let info):
            nextBody(info: info, kind: .tomorrow)
        case .noMoreClasses:
            emptyBody
        }
    }

    // MARK: - Variants

    private var isCompact: Bool { family == .systemSmall }

    private var signInBody: some View {
        Text(String(localized: "widget_sign_in"))
            .font(.callout)
            .foregroundStyle(palette.onSurfaceVariant)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func ongoingBody(infos: [WidgetDerivedState.OngoingInfo]) -> some View {
        let displayCount = min(infos.count, 2)
        if isCompact {
            // Compact: first ongoing only, with +1 badge if there's a second.
            compactOngoing(first: infos[0], showsPlusBadge: displayCount > 1)
        } else if displayCount == 2 {
            VStack(spacing: 10) {
                ongoingCard(info: infos[0])
                ongoingCard(info: infos[1])
            }
        } else {
            ongoingCard(info: infos[0])
        }
    }

    private func compactOngoing(first info: WidgetDerivedState.OngoingInfo, showsPlusBadge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(localized: "widget_ongoing"))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(palette.highlight, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                if showsPlusBadge {
                    Text("+1").font(.caption2.weight(.bold)).foregroundStyle(palette.onSurfaceVariant)
                }
            }
            Text(info.course.displayName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(palette.onSurface)
                .lineLimit(1)
            Text(String.localizedStringWithFormat(
                String(localized: "widget_until_time"), info.endTime))
                .font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ongoingCard(info: WidgetDerivedState.OngoingInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "widget_ongoing"))
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(palette.highlight, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
            Text(info.course.displayName)
                .font(.title3.weight(.bold))
                .foregroundStyle(palette.onSurface).lineLimit(2)
            Text("\(info.startTime)–\(info.endTime)  \(info.periodRange)")
                .font(.caption).foregroundStyle(palette.onSurfaceVariant)
            if !info.course.classroom.isEmpty {
                Text(info.course.classroom)
                    .font(.caption).foregroundStyle(palette.onSurfaceVariant)
            }
            Spacer(minLength: 4)
            ProgressView(value: info.progress)
                .progressViewStyle(.linear)
                .tint(palette.highlight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum NextKind { case nextToday, tomorrow }

    private func nextBody(info: WidgetDerivedState.NextInfo, kind: NextKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !isCompact {
                Text(kind == .nextToday
                     ? String(localized: "widget_next_class")
                     : String(localized: "widget_tomorrow"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            Text(info.course.displayName)
                .font(isCompact ? .subheadline.weight(.bold) : .title3.weight(.bold))
                .foregroundStyle(palette.onSurface)
                .lineLimit(2)
            Text(info.startTime)
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
            if !info.course.classroom.isEmpty {
                Text(info.course.classroom)
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyBody: some View {
        Text(String(localized: "widget_no_more_classes"))
            .font(.subheadline.weight(.bold))
            .foregroundStyle(palette.onSurface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: User adds to TigerDuckWidgets target only**

- [ ] **Step 3: Build to verify it compiles**

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWidgets/Views/NextClassView.swift
git commit -m "feat(widgets): NextClassView state-machine variants"
```

---

### Task 15: `NextClassWidget` definition

**Files:**
- Create: `swift/TigerDuckWidgets/Widgets/NextClassWidget.swift`
- Modify: `swift/TigerDuckWidgets/TigerDuckWidgetsBundle.swift`

- [ ] **Step 1: Create the widget**

`swift/TigerDuckWidgets/Widgets/NextClassWidget.swift`:

```swift
import WidgetKit
import SwiftUI

struct NextClassEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let derived: WidgetDerivedState
}

struct NextClassProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> NextClassEntry {
        let empty = WidgetSnapshot(
            version: 1, generatedAt: Date(), isLoggedIn: false,
            accentColorHex: 0x007AFF, courses: [], periodTimes: [:],
            periodOrder: [], activeWeekdays: [], activePeriodIds: []
        )
        return NextClassEntry(date: Date(), snapshot: empty, derived: .signInRequired)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextClassEntry) -> Void) {
        let snap = store.readSnapshot() ?? placeholder(in: context).snapshot
        completion(NextClassEntry(date: Date(), snapshot: snap,
                                  derived: WidgetTimelineDerivation.derive(snapshot: snap, at: Date())))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextClassEntry>) -> Void) {
        let snap = store.readSnapshot() ?? placeholder(in: context).snapshot
        let now = Date()
        let dates = WidgetTimelineDerivation.entryDates(snapshot: snap, after: now)
        let entries = dates.map { date in
            NextClassEntry(date: date, snapshot: snap,
                           derived: WidgetTimelineDerivation.derive(snapshot: snap, at: date))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct NextClassWidgetView: View {
    let entry: NextClassEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WidgetPalette.resolve(snapshot: entry.snapshot, colorScheme: colorScheme)
        NextClassView(derived: entry.derived, palette: palette, family: family)
            .padding(family == .systemSmall ? 10 : 14)
            .containerBackground(palette.background, for: .widget)
            .widgetURL(URL(string: "tigerduck://classtable"))
    }
}

struct NextClassWidget: Widget {
    let kind: String = "NextClassWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextClassProvider()) { entry in
            NextClassWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_next_class_light_label"))
        .description(String(localized: "widget_next_class_light_desc"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
```

- [ ] **Step 2: Add to bundle**

In `TigerDuckWidgetsBundle.swift`, add `NextClassWidget()` after `LibraryShortcutWidget()`:

```swift
@main
struct TigerDuckWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LibraryShortcutWidget()
        NextClassWidget()
    }
}
```

- [ ] **Step 3: User adds the new file to TigerDuckWidgets target**

- [ ] **Step 4: Build and verify on simulator**

Build, then add the "Next Class" widget on the simulator home screen in both small and medium families. Verify:
- Renders sign-in state when not logged in
- Renders ongoing state with progress bar when at a class period
- Switches to next-today after the period ends
- Switches to tomorrow-first when nothing is left today
- Dark mode toggles correctly

If the snapshot isn't being written yet (it should be, from Task 7), force one by opening the app once.

- [ ] **Step 5: Commit**

```bash
git add swift/TigerDuckWidgets/Widgets/NextClassWidget.swift \
        swift/TigerDuckWidgets/TigerDuckWidgetsBundle.swift
git commit -m "feat(widgets): NextClassWidget with small + medium families"
```

---

## Phase 6 — Today widget

### Task 16: `TodayListView`

**Files:**
- Create: `swift/TigerDuckWidgets/Views/TodayListView.swift`

- [ ] **Step 1: Create the view**

`swift/TigerDuckWidgets/Views/TodayListView.swift`:

```swift
import SwiftUI
import WidgetKit

struct TodayListView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette
    let maxRows: Int

    var body: some View {
        Group {
            if !snapshot.isLoggedIn {
                VStack { Spacer()
                    Text(String(localized: "widget_sign_in"))
                        .font(.callout).foregroundStyle(palette.onSurfaceVariant)
                    Spacer()
                }
            } else {
                loggedInBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var loggedInBody: some View {
        let weekday = WidgetTimelineDerivation.weekdayFor(now)
        let isWeekend = weekday == 6 || weekday == 7
        let order = snapshot.periodOrder
        let todayCourses = snapshot.courses
            .filter { $0.schedule[weekday] != nil }
            .sorted { lhs, rhs in
                let li = lhs.schedule[weekday]!.compactMap { order.firstIndex(of: $0) }.min() ?? .max
                let ri = rhs.schedule[weekday]!.compactMap { order.firstIndex(of: $0) }.min() ?? .max
                return li < ri
            }
        let ongoingNos = ongoingCourseNos(weekday: weekday, snapshot: snapshot, now: now)

        VStack(alignment: .leading, spacing: 6) {
            header(weekday: weekday)
            if todayCourses.isEmpty {
                Spacer()
                Text(String(localized: isWeekend ? "widget_no_classes_weekend" : "widget_no_classes_today"))
                    .font(.callout).foregroundStyle(palette.onSurfaceVariant)
                Spacer()
            } else {
                ForEach(todayCourses.prefix(maxRows), id: \.courseNo) { course in
                    row(course: course, weekday: weekday, isOngoing: ongoingNos.contains(course.courseNo))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func header(weekday: Int) -> some View {
        let dayKey = weekdayKey(weekday)
        let dayName = String(localized: String.LocalizationValue(dayKey))
        let title = String.localizedStringWithFormat(
            String(localized: "widget_today_weekday_title"), dayName
        )
        return Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(palette.onSurface)
    }

    private func row(course: SnapshotCourse, weekday: Int, isOngoing: Bool) -> some View {
        let order = snapshot.periodOrder
        let periods = (course.schedule[weekday] ?? [])
            .sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        let first = periods.first ?? ""
        let last = periods.last ?? ""
        let startTime = snapshot.periodTimes[first]?.start ?? ""
        let endTime = snapshot.periodTimes[last]?.end ?? ""
        let range = first == last ? first : "\(first)–\(last)"

        let rowFill = isOngoing ? Color(hex: course.colorHex) : palette.surface
        let primary = isOngoing ? Color.white : palette.onSurface
        let secondary = isOngoing ? Color.white.opacity(0.85) : palette.onSurfaceVariant

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(range).font(.caption.weight(.bold)).foregroundStyle(primary)
                Text("\(startTime)–\(endTime)").font(.caption2).foregroundStyle(secondary)
            }
            .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(course.displayName)
                    .font(.caption.weight(.medium)).foregroundStyle(primary).lineLimit(1)
                if !course.classroom.isEmpty {
                    Text(course.classroom).font(.caption2).foregroundStyle(secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func weekdayKey(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "weekday_mon_short"
        case 2: return "weekday_tue_short"
        case 3: return "weekday_wed_short"
        case 4: return "weekday_thu_short"
        case 5: return "weekday_fri_short"
        case 6: return "weekday_sat_short"
        default: return "weekday_sun_short"
        }
    }

    private func ongoingCourseNos(weekday: Int, snapshot: WidgetSnapshot, now: Date) -> Set<String> {
        let derived = WidgetTimelineDerivation.derive(snapshot: snapshot, at: now)
        if case .ongoing(let infos) = derived {
            return Set(infos.map { $0.course.courseNo })
        }
        return []
    }
}
```

- [ ] **Step 2: Add to TigerDuckWidgets target**

- [ ] **Step 3: Build, verify**

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWidgets/Views/TodayListView.swift
git commit -m "feat(widgets): TodayListView with ongoing-row highlight"
```

---

### Task 17: `TodayWidget` definition

**Files:**
- Create: `swift/TigerDuckWidgets/Widgets/TodayWidget.swift`
- Modify: `swift/TigerDuckWidgets/TigerDuckWidgetsBundle.swift`

- [ ] **Step 1: Create the widget**

`swift/TigerDuckWidgets/Widgets/TodayWidget.swift`:

```swift
import WidgetKit
import SwiftUI

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct TodayProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), snapshot: emptySnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(TodayEntry(date: Date(), snapshot: store.readSnapshot() ?? emptySnapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let snap = store.readSnapshot() ?? emptySnapshot
        let now = Date()
        let dates = WidgetTimelineDerivation.entryDates(snapshot: snap, after: now)
        let entries = dates.map { TodayEntry(date: $0, snapshot: snap) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private var emptySnapshot: WidgetSnapshot {
        WidgetSnapshot(version: 1, generatedAt: Date(), isLoggedIn: false,
                       accentColorHex: 0x007AFF, courses: [], periodTimes: [:],
                       periodOrder: [], activeWeekdays: [], activePeriodIds: [])
    }
}

struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WidgetPalette.resolve(snapshot: entry.snapshot, colorScheme: colorScheme)
        let maxRows: Int
        switch family {
        case .systemMedium:     maxRows = 4
        case .systemLarge:      maxRows = 8
        case .systemExtraLarge: maxRows = 16
        default:                maxRows = 4
        }
        TodayListView(snapshot: entry.snapshot, now: entry.date, palette: palette, maxRows: maxRows)
            .padding(12)
            .containerBackground(palette.background, for: .widget)
            .widgetURL(URL(string: "tigerduck://classtable"))
    }
}

struct TodayWidget: Widget {
    let kind: String = "TodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_today_light_label"))
        .description(String(localized: "widget_today_light_desc"))
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}
```

- [ ] **Step 2: Add to bundle**

```swift
@main
struct TigerDuckWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LibraryShortcutWidget()
        NextClassWidget()
        TodayWidget()
    }
}
```

- [ ] **Step 3: User adds new file to TigerDuckWidgets target**

- [ ] **Step 4: Build and verify on simulator**

Add the "Schedule (Today)" widget in medium, large, and on iPad simulator extraLarge. Verify row count scales, ongoing row highlighted with course color, dark mode renders correctly.

- [ ] **Step 5: Commit**

```bash
git add swift/TigerDuckWidgets/Widgets/TodayWidget.swift \
        swift/TigerDuckWidgets/TigerDuckWidgetsBundle.swift
git commit -m "feat(widgets): TodayWidget medium/large/extraLarge"
```

---

## Phase 7 — Week widget

### Task 18: `WeekGridView`

**Files:**
- Create: `swift/TigerDuckWidgets/Views/WeekGridView.swift`

- [ ] **Step 1: Create the view**

`swift/TigerDuckWidgets/Views/WeekGridView.swift`:

```swift
import SwiftUI

struct WeekGridView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette

    var body: some View {
        Group {
            if !snapshot.isLoggedIn {
                Text(String(localized: "widget_sign_in"))
                    .font(.callout).foregroundStyle(palette.onSurfaceVariant)
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var grid: some View {
        let weekdays = snapshot.activeWeekdays
        let periods = snapshot.activePeriodIds
        let todayWeekday = WidgetTimelineDerivation.weekdayFor(now)

        VStack(spacing: 2) {
            headerRow(weekdays: weekdays, todayWeekday: todayWeekday)
            ForEach(periods, id: \.self) { periodId in
                HStack(spacing: 2) {
                    Text(periodId)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .frame(width: 16, alignment: .center)
                    ForEach(weekdays, id: \.self) { weekday in
                        cell(weekday: weekday, periodId: periodId)
                    }
                }
            }
        }
    }

    private func headerRow(weekdays: [Int], todayWeekday: Int) -> some View {
        HStack(spacing: 2) {
            Spacer().frame(width: 16)
            ForEach(weekdays, id: \.self) { weekday in
                VStack(spacing: 2) {
                    Text(String(localized: String.LocalizationValue(weekdayKey(weekday))))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.onSurface)
                    Rectangle()
                        .fill(weekday == todayWeekday ? palette.highlight : .clear)
                        .frame(height: 2)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func cell(weekday: Int, periodId: String) -> some View {
        let course = snapshot.courses.first { $0.schedule[weekday]?.contains(periodId) == true }
        return Group {
            if let course {
                VStack(spacing: 1) {
                    Text(course.displayName)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(1)
                    if !course.classroom.isEmpty {
                        Text(course.classroom)
                            .font(.system(size: 7))
                            .foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(2)
                .background(Color(hex: course.colorHex), in: RoundedRectangle(cornerRadius: 3))
            } else {
                Rectangle()
                    .fill(palette.emptyCell)
                    .cornerRadius(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24)
    }

    private func weekdayKey(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "weekday_mon_short"
        case 2: return "weekday_tue_short"
        case 3: return "weekday_wed_short"
        case 4: return "weekday_thu_short"
        case 5: return "weekday_fri_short"
        case 6: return "weekday_sat_short"
        default: return "weekday_sun_short"
        }
    }
}
```

- [ ] **Step 2: Add to TigerDuckWidgets target**

- [ ] **Step 3: Build, verify**

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWidgets/Views/WeekGridView.swift
git commit -m "feat(widgets): WeekGridView 5-7 day grid"
```

---

### Task 19: `WeekWidget` definition

**Files:**
- Create: `swift/TigerDuckWidgets/Widgets/WeekWidget.swift`
- Modify: `swift/TigerDuckWidgets/TigerDuckWidgetsBundle.swift`

- [ ] **Step 1: Create the widget**

`swift/TigerDuckWidgets/Widgets/WeekWidget.swift`:

```swift
import WidgetKit
import SwiftUI

struct WeekEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct WeekProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> WeekEntry {
        WeekEntry(date: Date(), snapshot: emptySnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (WeekEntry) -> Void) {
        completion(WeekEntry(date: Date(), snapshot: store.readSnapshot() ?? emptySnapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeekEntry>) -> Void) {
        let snap = store.readSnapshot() ?? emptySnapshot
        // Week grid only needs to refresh at midnight (to advance "today" underline).
        let midnight = Calendar(identifier: .gregorian).startOfDay(for: Date().addingTimeInterval(86_400))
        completion(Timeline(entries: [WeekEntry(date: Date(), snapshot: snap)], policy: .after(midnight)))
    }

    private var emptySnapshot: WidgetSnapshot {
        WidgetSnapshot(version: 1, generatedAt: Date(), isLoggedIn: false,
                       accentColorHex: 0x007AFF, courses: [], periodTimes: [:],
                       periodOrder: [], activeWeekdays: [], activePeriodIds: [])
    }
}

struct WeekWidgetView: View {
    let entry: WeekEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WidgetPalette.resolve(snapshot: entry.snapshot, colorScheme: colorScheme)
        WeekGridView(snapshot: entry.snapshot, now: entry.date, palette: palette)
            .padding(8)
            .containerBackground(palette.background, for: .widget)
            .widgetURL(URL(string: "tigerduck://classtable"))
    }
}

struct WeekWidget: Widget {
    let kind: String = "WeekWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WeekProvider()) { entry in
            WeekWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_week_light_label"))
        .description(String(localized: "widget_week_light_desc"))
        .supportedFamilies([.systemLarge, .systemExtraLarge])
    }
}
```

- [ ] **Step 2: Add to bundle**

```swift
@main
struct TigerDuckWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LibraryShortcutWidget()
        NextClassWidget()
        TodayWidget()
        WeekWidget()
    }
}
```

- [ ] **Step 3: User adds new file to TigerDuckWidgets target**

- [ ] **Step 4: Build and verify**

Install "Schedule (Week)" widget in large family. Verify grid renders with today column underlined in accent. Verify on iPad simulator at extraLarge.

- [ ] **Step 5: Commit**

```bash
git add swift/TigerDuckWidgets/Widgets/WeekWidget.swift \
        swift/TigerDuckWidgets/TigerDuckWidgetsBundle.swift
git commit -m "feat(widgets): WeekWidget large + iPad extraLarge"
```

---

## Phase 8 — Accessory family (Lock Screen)

### Task 20: `AccessoryViews`

**Files:**
- Create: `swift/TigerDuckWidgets/Views/AccessoryViews.swift`

- [ ] **Step 1: Create the views**

`swift/TigerDuckWidgets/Views/AccessoryViews.swift`:

```swift
import SwiftUI
import WidgetKit

struct AccessoryInlineView: View {
    let derived: WidgetDerivedState

    var body: some View {
        switch derived {
        case .signInRequired: Text(String(localized: "widget_sign_in"))
        case .ongoing(let infos):
            Text("\(String(localized: "widget_ongoing")): \(infos[0].course.displayName)")
        case .nextToday(let info):
            Text("\(String(localized: "widget_next_class_short")): \(info.course.displayName) · \(info.startTime)")
        case .tomorrowFirst(let info):
            Text(String.localizedStringWithFormat(String(localized: "widget_tomorrow_time"),
                                                   "\(info.course.displayName) \(info.startTime)"))
        case .noMoreClasses:
            Text(String(localized: "widget_no_more_classes"))
        }
    }
}

struct AccessoryCircularView: View {
    let derived: WidgetDerivedState

    var body: some View {
        switch derived {
        case .ongoing(let infos):
            let info = infos[0]
            VStack(spacing: 0) {
                Text(info.course.displayName.prefix(3))
                    .font(.system(size: 12, weight: .bold))
                Text(info.endTime).font(.system(size: 8))
            }
        case .nextToday(let info), .tomorrowFirst(let info):
            VStack(spacing: 0) {
                Text(info.course.displayName.prefix(3))
                    .font(.system(size: 12, weight: .bold))
                Text(info.startTime).font(.system(size: 8))
            }
        case .signInRequired, .noMoreClasses:
            Image(systemName: "calendar")
        }
    }
}

struct AccessoryRectangularView: View {
    let derived: WidgetDerivedState

    var body: some View {
        switch derived {
        case .signInRequired:
            Text(String(localized: "widget_sign_in"))
        case .ongoing(let infos):
            let info = infos[0]
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "widget_ongoing")).font(.caption2.weight(.bold))
                Text(info.course.displayName).font(.caption.weight(.semibold)).lineLimit(1)
                HStack {
                    Text("\(info.startTime)–\(info.endTime)").font(.caption2)
                    if !info.course.classroom.isEmpty { Text("·").font(.caption2); Text(info.course.classroom).font(.caption2) }
                }
            }
        case .nextToday(let info):
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "widget_next_class")).font(.caption2.weight(.bold))
                Text(info.course.displayName).font(.caption.weight(.semibold)).lineLimit(1)
                Text("\(info.startTime)  \(info.course.classroom)").font(.caption2)
            }
        case .tomorrowFirst(let info):
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "widget_tomorrow")).font(.caption2.weight(.bold))
                Text(info.course.displayName).font(.caption.weight(.semibold)).lineLimit(1)
                Text(info.startTime).font(.caption2)
            }
        case .noMoreClasses:
            Text(String(localized: "widget_no_more_classes")).font(.caption)
        }
    }
}
```

- [ ] **Step 2: Add to TigerDuckWidgets target**

- [ ] **Step 3: Build, verify**

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckWidgets/Views/AccessoryViews.swift
git commit -m "feat(widgets): inline/circular/rectangular accessory views"
```

---

### Task 21: `AccessoryWidget` definition

**Files:**
- Create: `swift/TigerDuckWidgets/Widgets/AccessoryWidget.swift`
- Modify: `swift/TigerDuckWidgets/TigerDuckWidgetsBundle.swift`

- [ ] **Step 1: Create the widget**

`swift/TigerDuckWidgets/Widgets/AccessoryWidget.swift`:

```swift
import WidgetKit
import SwiftUI

struct AccessoryEntry: TimelineEntry {
    let date: Date
    let derived: WidgetDerivedState
}

struct AccessoryProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> AccessoryEntry {
        AccessoryEntry(date: Date(), derived: .signInRequired)
    }

    func getSnapshot(in context: Context, completion: @escaping (AccessoryEntry) -> Void) {
        let snap = store.readSnapshot()
        let derived = snap.map { WidgetTimelineDerivation.derive(snapshot: $0, at: Date()) } ?? .signInRequired
        completion(AccessoryEntry(date: Date(), derived: derived))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AccessoryEntry>) -> Void) {
        guard let snap = store.readSnapshot() else {
            completion(Timeline(entries: [AccessoryEntry(date: Date(), derived: .signInRequired)], policy: .atEnd))
            return
        }
        let now = Date()
        let dates = WidgetTimelineDerivation.entryDates(snapshot: snap, after: now)
        let entries = dates.map { date in
            AccessoryEntry(date: date, derived: WidgetTimelineDerivation.derive(snapshot: snap, at: date))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct AccessoryWidgetView: View {
    let entry: AccessoryEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let view = Group {
            switch family {
            case .accessoryInline:      AccessoryInlineView(derived: entry.derived)
            case .accessoryCircular:    AccessoryCircularView(derived: entry.derived)
            case .accessoryRectangular: AccessoryRectangularView(derived: entry.derived)
            default:                    EmptyView()
            }
        }
        .widgetURL(URL(string: "tigerduck://classtable"))
        .widgetAccentable(true)

        view.containerBackground(.clear, for: .widget)
    }
}

struct AccessoryWidget: Widget {
    let kind: String = "AccessoryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AccessoryProvider()) { entry in
            AccessoryWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_next_class_light_label"))
        .description(String(localized: "widget_next_class_light_desc"))
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
```

- [ ] **Step 2: Add to bundle**

```swift
@main
struct TigerDuckWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LibraryShortcutWidget()
        NextClassWidget()
        TodayWidget()
        WeekWidget()
        AccessoryWidget()
    }
}
```

- [ ] **Step 3: User adds new file to TigerDuckWidgets target**

- [ ] **Step 4: Build, install on Lock Screen**

In simulator: lock device (Cmd-L), then "Customize" the Lock Screen, add inline/circular/rectangular accessory widgets, find "Next Class". Verify each accessory family renders.

- [ ] **Step 5: Commit**

```bash
git add swift/TigerDuckWidgets/Widgets/AccessoryWidget.swift \
        swift/TigerDuckWidgets/TigerDuckWidgetsBundle.swift
git commit -m "feat(widgets): accessory family for Lock Screen"
```

---

## Phase 9 — Localization smoke test

### Task 22: Verify every widget chrome key resolves in the extension bundle

**Files:**
- Create: `swift/TigerDuckTests/Widgets/WidgetLocalizationKeysTests.swift`

- [ ] **Step 1: Write the test**

```swift
import Foundation
import Testing
@testable import TigerDuck

struct WidgetLocalizationKeysTests {
    /// Every key referenced from widget SwiftUI views. Update this list when
    /// you add or remove a localized string in any widget view.
    private let keys: [String] = [
        // Chrome
        "widget_sign_in",
        "widget_ongoing",
        "widget_ongoing_count",
        "widget_next_class",
        "widget_next_class_short",
        "widget_until_time",
        "widget_tomorrow",
        "widget_tomorrow_time",
        "widget_no_more_classes",
        "widget_no_classes_today",
        "widget_no_classes_weekend",
        "widget_no_courses",
        "widget_today_schedule_title",
        "widget_today_weekday_title",
        "widget_library_shortcut_title",
        // Gallery
        "widget_library_shortcut_light_label",
        "widget_library_shortcut_light_desc",
        "widget_next_class_light_label",
        "widget_next_class_light_desc",
        "widget_today_light_label",
        "widget_today_light_desc",
        "widget_week_light_label",
        "widget_week_light_desc",
        // Weekday shorts
        "weekday_mon_short", "weekday_tue_short", "weekday_wed_short",
        "weekday_thu_short", "weekday_fri_short", "weekday_sat_short",
        "weekday_sun_short",
    ]

    @Test func everyKeyResolvesInMainBundle() {
        // We can't load the widget extension's bundle from the test target
        // directly, but the keys also live in the main app's Localizable.strings
        // (same translation source). If they resolve here, they resolve in the
        // widget bundle too.
        for key in keys {
            let resolved = String(localized: String.LocalizationValue(key), bundle: .main)
            #expect(!resolved.isEmpty, "Key \(key) resolved to empty")
            #expect(resolved != key, "Key \(key) had no translation (got key back as value)")
        }
    }
}
```

- [ ] **Step 2: Add to TigerDuckTests target**

- [ ] **Step 3: Run, verify pass**

```bash
xcodebuild test -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:TigerDuckTests/WidgetLocalizationKeysTests
```

Expected: all keys resolve.

- [ ] **Step 4: Commit**

```bash
git add swift/TigerDuckTests/Widgets/WidgetLocalizationKeysTests.swift
git commit -m "test(widgets): smoke-test every widget chrome key resolves"
```

---

## Phase 10 — Final manual verification

### Task 23: Run the manual verification checklist

No code changes — this is a verification gate before merging.

- [ ] **Run each scenario on iPhone simulator (iOS 18):**

1. Install each of the 4 home-screen widgets in each supported family. ✓
2. Toggle Dark Mode (Settings → Developer → Dark Appearance) — verify instant repaint of all widgets, no app re-launch. ✓
3. Switch system language to 繁體中文, return to home screen — verify chrome strings update on next reload (may take a minute; force by toggling Airplane mode or rebooting simulator if needed). ✓
4. In the app: add a custom course, then delete it. Verify the widget reflects each change within ~1 second of returning to home screen. ✓
5. In the app: rename a course, verify the new name appears in the widget. ✓
6. In the app: toggle the "show abbreviation" setting in Settings, verify widget names update. ✓
7. In the app: change accent color, verify ongoing pills / progress bars / library tile / today underline all change to the new accent. ✓
8. Wait at a real period boundary (or fake `Date()` if testing locally), verify ongoing/next state transitions without manual intervention. ✓
9. Lock device, customize Lock Screen, install accessory widgets in each family — verify they render and update. ✓

- [ ] **Run scenarios on iPad simulator:**

10. Install Today and Week widgets in `systemExtraLarge` on iPad — verify they render. ✓

- [ ] **Tap-routing verification (each widget kind, both cold and warm app states):**

11. With app force-quit, tap Library Shortcut — app launches to Library tab. ✓
12. With app force-quit, tap Next Class / Today / Week — app launches to Class Table tab. ✓
13. With app open in Settings tab, tap Library Shortcut — switches to Library tab. ✓

- [ ] **All-pass confirmation**

If every scenario passes, this is the final commit (no source changes, but verification is the gate):

```bash
git status   # Should be clean — no uncommitted changes
```

If any scenario fails, do NOT merge. File a bug in the form of a failing test or note the missing behavior, fix it, then re-run the relevant scenarios.

---

## Wrap-up

After Task 23 completes, the branch is ready for PR. Open it against `dev`:

```bash
gh pr create --base dev --title "feat: iOS home + lock screen widgets" --body "$(cat <<'EOF'
## Summary
- 4 home-screen widgets (Library, Next Class, Today, Week) + 1 accessory bundle (inline/circular/rectangular) for the Lock Screen
- Strict system theme via @Environment(\.colorScheme), accent color synced from app prefs
- System language via existing localization submodule symlinks extended to the widget target
- Custom course names + abbreviation toggle propagate live via WidgetSnapshotWriter + WidgetCenter.reloadAllTimelines
- URL scheme tigerduck:// for deep-linking taps

## Test plan
- [x] Unit tests pass (`xcodebuild test`)
- [x] Manual verification checklist in spec passed on iPhone + iPad simulators
- [x] Manual Xcode setup steps completed (new target, App Group, URL scheme)
EOF
)"
```

Note: do NOT include the spec or plan files in the PR — `docs/superpowers/` is local-only per repo policy.
