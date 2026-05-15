# iOS Home Screen + Lock Screen Widgets — Design Spec

**Status:** Draft for review
**Date:** 2026-05-12
**Branch:** `feat/widgets`
**Source-of-inspiration:** Android implementation at `~/StudioProjects/tigerduck-app-android/app/src/main/java/org/ntust/app/tigerduck/widget/`

---

## Goal

Bring TigerDuck's Android widgets to iOS (iPhone + iPad) with these constraints:

1. **Always follow system theme** — strict iOS Light/Dark via `@Environment(\.colorScheme)`, ignoring any in-app theme override.
2. **Follow system language** — widget chrome strings adopt the iOS device language, reusing the existing shared localization submodule (60+ locales already translated).
3. **Follow app class-table design** — visual parity with the in-app `Features/ClassTable` views (course colors, surface treatment, typography).
4. **Follow app course names** — custom renames and the abbreviation toggle propagate to widgets without manual refresh.

## Scope

Ship four widget kinds, plus one shared Lock-Screen accessory bundle:

| Widget | iOS families |
|---|---|
| Library Shortcut | `systemSmall` |
| Next Class | `systemSmall` + `systemMedium` |
| Today | `systemMedium` + `systemLarge` + `systemExtraLarge` (iPad) |
| Week | `systemLarge` + `systemExtraLarge` (iPad) |
| Accessory (shared) | `accessoryInline` + `accessoryCircular` + `accessoryRectangular` |

iPad supports every family the iPhone does, plus `systemExtraLarge` for the two most data-dense kinds.

Out of scope for v1: watchOS complications (no watch target exists), visual-regression screenshot tests, in-widget configuration (App Intents for picking "which course to feature").

---

## 1. Architecture

### Targets

A new Xcode target sits next to the existing Live Activity extension:

```
TigerDuck (app, iOS 18.0, iPhone + iPad)
TigerDuckLiveActivity (LA extension, existing)
TigerDuckWidgets (NEW — WidgetKit extension, iOS 18.0)
```

Bundle ID: `org.ntust.app.TigerDuck1.TigerDuckWidgets`.

### App Group

Reuses the existing `group.org.ntust.app.TigerDuck` App Group already wired for Live Activity. The new extension's entitlements file (`swift/TigerDuckWidgets.entitlements`) must declare the same group. Per the project's pbxproj-hands-off convention, the user enables the App Group capability on the new target manually in Xcode signing.

### File layout

**New widget-extension files:**

```
swift/TigerDuckWidgets/
├── TigerDuckWidgetsBundle.swift          # @main WidgetBundle
├── Snapshot/
│   └── WidgetSnapshotStore.swift         # read-side only
├── Theme/
│   └── WidgetPalette.swift               # Light/Dark palette + accent
├── Widgets/
│   ├── LibraryShortcutWidget.swift
│   ├── NextClassWidget.swift
│   ├── TodayWidget.swift
│   ├── WeekWidget.swift
│   └── AccessoryWidget.swift
├── Views/
│   ├── NextClassView.swift               # state-machine view
│   ├── TodayListView.swift
│   ├── WeekGridView.swift
│   ├── LibraryShortcutView.swift
│   └── Accessory{Inline,Circular,Rectangular}View.swift
├── Logic/
│   └── WidgetTimelineDerivation.swift    # pure: snapshot + date → derived state
├── TigerDuckWidgets.entitlements
└── Resources/
    └── <lang>.lproj/                     # symlinks created by sync script
```

**New app-side files:**

```
swift/TigerDuck/Widgets/
├── WidgetSnapshot.swift                  # Codable contract (also in widget target)
├── WidgetSnapshotWriter.swift            # observes change events, writes snapshot
├── WidgetSnapshotBuilder.swift           # pure: state → WidgetSnapshot
├── WidgetReloadCoordinator.swift         # 300ms-debounced reloadAllTimelines
└── WidgetURLRouter.swift                 # tigerduck:// URL → typed destination
```

`WidgetSnapshot.swift` is multi-target (main app + widget extension) — the same trick `LiveActivitySnapshot.swift` already uses.

---

## 2. Snapshot Contract & Data Flow

### Codable shape

```swift
struct WidgetSnapshot: Codable {
    let version: Int                       // bump on incompatible change
    let generatedAt: Date
    let isLoggedIn: Bool
    let accentColorHex: UInt32             // resolved at write time
    let courses: [SnapshotCourse]
    let periodTimes: [String: PeriodTime]  // periodId → start/end "HH:mm"
    let periodOrder: [String]              // chronological
    let activeWeekdays: [Int]              // 1=Mon … 7=Sun
    let activePeriodIds: [String]
}

struct SnapshotCourse: Codable {
    let courseNo: String
    let displayName: String                // post-abbreviation, post-customName
    let classroom: String
    let schedule: [Int: [String]]          // weekday → [periodId]
    let colorHex: UInt32                   // resolved from palette + customColor
}

struct PeriodTime: Codable {
    let start: String                      // "HH:mm"
    let end: String
}
```

**Key principle:** the snapshot is **timeless**. It carries raw schedule data, NOT pre-computed "ongoing/next/tomorrow" state. Derivations happen inside the widget process at each timeline entry's `date`, so future entries render correctly without re-writing the snapshot.

### Storage

App Group `UserDefaults(suiteName: "group.org.ntust.app.TigerDuck")` under key `Widget-snapshot-v1`. Distinct from Live Activity's `LA-current-snapshot-v1` so the two extensions evolve independently. Schema migration: bump the suffix on incompatible change.

### Writer triggers (app-side)

`WidgetSnapshotWriter` subscribes to:

- Course store writes (NTUST sync, user-added/deleted, custom rename)
- `accentColorHex` preference change
- `nameAbbreviationEnabled` toggle
- `Locale.current` change (system language switch)
- Auth state change
- App cold-start `init`

Each event calls a 300ms-debounced `regenerate()`. `regenerate()`:

1. Runs `WidgetSnapshotBuilder.build(...)` (pure function)
2. Writes the result to App Group UserDefaults
3. Triggers `WidgetReloadCoordinator.requestReload()` → `WidgetCenter.shared.reloadAllTimelines()`

### Timeline provider semantics

For each widget kind:

```
placeholder  → static "shell" entry for previews (Add Widget gallery)
getSnapshot  → read App Group snapshot, derive state for Date.now
getTimeline  → read snapshot, build entries at:
                 ⋅ now
                 ⋅ each remaining today period start AND end (deduped)
                 ⋅ midnight tonight (rolls into tomorrow)
               return .atEnd reload policy
```

Weekend with no scheduled courses → single entry until midnight.

### Failure / empty states

| Snapshot state | Widget renders |
|---|---|
| Missing | "Open TigerDuck" + library/class-table glyph |
| Version mismatch | Treat as missing |
| `isLoggedIn=false` | `widget_sign_in` |
| Logged in, no courses today (weekday) | `widget_no_classes_today` |
| Logged in, no courses today (weekend) | `widget_no_classes_weekend` |

---

## 3. Per-Widget UX

All widgets use SwiftUI views that mirror the in-app class-table aesthetic from `Features/ClassTable/Components/TimetableGridView.swift` — same corner radius, padding, typography weights, and per-course color application.

### 3a. LibraryShortcutWidget (`systemSmall`)

```
┌─────────────────┐
│                 │
│      ┌────┐     │
│      │ 📖 │     │   ← rounded-square (44pt) filled with accentColor
│      └────┘     │     containing SF Symbol "qrcode.viewfinder" in white
│                 │
│     Library     │   ← widget_library_shortcut_title, .footnote, .medium
└─────────────────┘
```

Background: `Color(.systemBackground)`. Tap: `widgetURL("tigerduck://library")`.

### 3b. NextClassWidget (`systemSmall` + `systemMedium`)

State machine driven by `(snapshot, entry.date) → DerivedState`:

| State | Compact (small) | Full (medium) |
|---|---|---|
| Ongoing × 1 | One-line card with name + end time | Large card: ongoing pill, name (≤2 lines), time range, period range, classroom, progress bar at bottom |
| Ongoing × 2 | First course + "+1" badge | Two stacked half-height cards, each with its own progress bar |
| Next today | "Next: Calculus, 10:10" | Label + name + start time + classroom |
| Tomorrow first | First course name + "Tomorrow HH:mm" | Same, with `widget_no_more_classes` headline above |
| No courses tomorrow either | `widget_no_more_classes` | `widget_no_more_classes` |
| Not logged in | `widget_sign_in` (single line) | `widget_sign_in` centered |

Progress bar fills proportionally to `(now - startMin) / (endMin - startMin)`, clamped 0–1, color = `accentColor`.

Tap: `widgetURL("tigerduck://classtable")`.

### 3c. TodayWidget (`systemMedium` + `systemLarge` + `systemExtraLarge` on iPad)

Vertical list per `TodayListContent.kt`:

- Header: `widget_today_weekday_title` substituted with `weekday_*_short`
- Rows: `[period range "1–2" + time range "HH:mm–HH:mm"]  displayName  classroom`
- Ongoing rows: fill with course's palette `colorHex`, text in white (matches class-table card style)
- Non-ongoing rows: surface fill, primary/secondary text colors
- Row count fit: medium ≈ 4, large ≈ 8, extraLarge ≈ 16

Overflow truncates silently (no "+N more" indicator — matches Android).

Tap: `widgetURL("tigerduck://classtable")`.

### 3d. WeekWidget (`systemLarge` + `systemExtraLarge` on iPad)

Grid: 5 columns (Mon–Fri), or 6/7 if `activeWeekdays` contains Sat/Sun. Rows = `activePeriodIds` in chronological order.

- Header row: weekday `weekday_*_short` names; **today** column highlighted with an underline in `accentColor`.
- Cells: filled with the course's palette color when occupied, neutral `emptyCell` color when empty. `displayName` (1 line, tail-truncated) + `classroom` (if space).
- Leading period labels along the rows.
- iPad extraLarge: same grid with roomier cells and naturally accommodates weekend columns when present.

Tap: `widgetURL("tigerduck://classtable")`.

### 3e. Accessory family (Lock Screen)

A single `Widget` struct whose `supportedFamilies` is `[.accessoryInline, .accessoryCircular, .accessoryRectangular]`. All three accessory families render the same `DerivedState` that `NextClassWidget` uses on `systemMedium` (ongoing → next today → tomorrow → no-more-classes), so the user only has to think about "I want my next class on the Lock Screen" — not pick between accessory variants per Home Screen kind:

- `accessoryInline`: `"Next class: Calculus · 10:10"`
- `accessoryCircular`: time/countdown center, course abbreviation around the ring
- `accessoryRectangular`: 3 lines — label, course name, time + classroom

`.widgetRenderingMode(.fullColor)` with the system handling Lock-Screen monochrome tinting. Transparent backgrounds (accessory contract requirement).

---

## 4. Theming, Accent, Localization

### Strict system theme

Every widget view reads `@Environment(\.colorScheme)` and resolves through `WidgetPalette`. The extension never consults `themeMode` from the App Group.

```swift
struct WidgetPalette {
    let background, surface, onSurface, onSurfaceVariant, emptyCell: Color
    let highlight: Color   // = snapshot.accentColor

    static func resolve(snapshot: WidgetSnapshot, colorScheme: ColorScheme) -> WidgetPalette {
        (colorScheme == .dark ? Self.dark : Self.light).with(highlight: Color(hex: snapshot.accentColorHex))
    }
}
```

Color values mirror Android `WidgetTheme`:

| Token | Light | Dark |
|---|---|---|
| `background` | `#F5F5F5` | `#1C1C1E` |
| `surface` | `#FFFFFF` | `#2C2C2E` |
| `onSurface` | `#1C1C1E` | `#F5F5F5` |
| `onSurfaceVariant` | `#6E6E73` | `#8E8E93` |
| `emptyCell` | `#ECECEC` | `#2C2C2E` |

### Container background

Every widget body uses `.containerBackground(for: .widget) { ... }` with the palette's `background` color, so the Lock-Screen/StandBy "transparent" rendering modes work correctly.

### Accent vs per-course color

Two independent color axes:

- **`WidgetPalette.highlight`** (= app accent): library tile fill, ongoing badge pill, progress-bar fill, today-column underline in Week grid.
- **`SnapshotCourse.colorHex`** (per-course palette): Today row backgrounds for ongoing courses, Week grid cell fills. Resolved app-side via `buildCourseColorAssignments` so collisions match the in-app palette.

This matches the in-app class-table design.

### Localization wiring

1. **Extend `tools/localization/sync_localizations.py`** to create matching `.lproj` symlinks in `swift/TigerDuckWidgets/Resources/`, pointing to `../../../localization/generated/apple/<lang>.lproj/` (one level deeper than the main app's symlinks, since the widget Resources folder is nested).
2. **Resources phase** of the widget extension target includes those symlinks (auto-discovered as localized resources).
3. **String access** at runtime: standard `String(localized: "widget_sign_in", bundle: .main)` from widget views — `.main` resolves to the widget extension's bundle, which contains its own copy of `Localizable.strings`.

**Reused keys (all already present in `localization/source/en.json` and 60+ locale files):**

- Chrome: `widget_sign_in`, `widget_ongoing`, `widget_ongoing_count`, `widget_next_class`, `widget_next_class_short`, `widget_until_time`, `widget_tomorrow`, `widget_tomorrow_time`, `widget_no_more_classes`, `widget_no_classes_today`, `widget_no_classes_weekend`, `widget_no_courses`, `widget_today_schedule_title`, `widget_today_weekday_title`, `widget_library_shortcut_title`
- Weekday shorts: `weekday_mon_short` … `weekday_sun_short`
- Add Widget gallery: reuse the `*_light_label` + `*_light_desc` variants. The `*_dark_*` keys become iOS-orphaned — leave them in the submodule for now since Android still uses them; a future localization-cleanup PR can rationalize the schema if Android also drops dual-theme widgets.

### Stale-on-language-switch handling

System language change triggers two effects:

1. Bundle string resolution updates automatically — no app code needed.
2. The pre-resolved `course.displayName` in the snapshot reflects the *previous* language (since `NameAbbrService` localizes course names against the active locale at resolution time).

To handle (2): `WidgetSnapshotWriter` observes `NSLocale.currentLocaleDidChangeNotification` (or equivalent) and triggers `regenerate()`. After the new snapshot is written and `reloadAllTimelines` is called, widgets render with freshly-localized names.

---

## 5. Deep Linking & Tap Routing

### URL scheme registration

Add to the main app target's Info.plist (manual Xcode step, same category as App Group capability):

```
CFBundleURLTypes:
  - CFBundleURLName:    org.ntust.app.TigerDuck.widgetLinks
    CFBundleURLSchemes: [tigerduck]
```

### Routes

| Widget | URL |
|---|---|
| LibraryShortcut | `tigerduck://library` |
| NextClass / Today / Week | `tigerduck://classtable` |
| Accessory family | `tigerduck://classtable` |

`widgetURL(_:)` is set on the root view of each widget — single tap region per widget, matching Android.

### App-side handling

`WidgetURLRouter.swift`:

```swift
enum WidgetDestination { case library, classTable }

enum WidgetURLRouter {
    static func route(_ url: URL) -> WidgetDestination? {
        guard url.scheme == "tigerduck" else { return nil }
        switch url.host {
        case "library":    return .library
        case "classtable": return .classTable
        default:           return nil
        }
    }
}
```

In `TigerDuckApp.swift`'s root scene:

```swift
.onOpenURL { url in
    guard let destination = WidgetURLRouter.route(url) else { return }
    appState.openFromWidget(destination)
}
```

`AppState.openFromWidget(_:)` mirrors the existing push-notification-driven tab selection (see `PushAppDelegate` and `AppState.selectedTab` setters). For `.library`, the existing "library feature disabled" branch already routes to Settings with the enable-prompt — no extra widget-side handling needed.

### Cold-launch safety

`onOpenURL` fires before SwiftData stores are guaranteed loaded. `AppState.openFromWidget` queues the destination if `bootCompleted == false` and replays on the next `bootCompleted == true` transition. Pattern matches the existing push queue if one exists; otherwise introduces a minimal `pendingWidgetDestination: WidgetDestination?` property on `AppState`.

---

## 6. Testing

### Unit tests (XCTest in `TigerDuckTests`)

- **`WidgetSnapshotBuilderTests`** — fixture courses + prefs → expected snapshot. Covers name resolution (custom > abbreviated > raw), per-course color assignment, active weekday/period computation, login-state branching.
- **`WidgetTimelineDerivationTests`** — given a snapshot + fixed `Date`, the derived ongoing/next/tomorrow state matches expectations at each transition boundary (before/at/after period start, before/at/after period end, midnight roll, weekend, no-courses-at-all).
- **`WidgetSnapshotCodableTests`** — JSON round-trip + a frozen `WidgetSnapshot-v1.json` fixture. Test fails on incompatible schema change unless the version is bumped.
- **`WidgetURLRouterTests`** — `tigerduck://library`, `tigerduck://classtable`, unknown host, malformed URL, wrong scheme.
- **`WidgetReloadCoordinatorTests`** — debouncing: 5 rapid `requestReload()` within 300ms produce exactly 1 `WidgetCenter.reloadAllTimelines` (injected via protocol stub).

### Localization smoke

A single test enumerates every widget chrome key referenced in views and asserts each resolves to a non-empty `String(localized:)` in the widget extension's bundle. Catches "key not symlinked into the extension" regressions.

### Manual verification checklist

Widget rendering can't be fully covered by XCTest. The implementation PR must include verification that:

1. Each of the 4 widgets installs in each supported family on iPhone simulator (small/medium/large).
2. Each iPad-supporting widget installs in extraLarge on iPad simulator.
3. Toggling system Dark Mode while the widget is on Home Screen triggers instant repaint (no app relaunch needed).
4. Switching system language between zh-Hant and en updates chrome strings on next reload tick.
5. Add/delete a course, rename a course, toggle abbreviation, change accent — widget updates within ~1s.
6. Wait at a period boundary — ongoing/next state transitions without manual intervention.
7. Lock device → Lock-Screen accessory widgets render in all three accessory families.
8. Tap-route from each widget kind to the correct app destination, with the app both cold-launched and warm.

### Out of scope for v1 tests

- Visual regression / screenshot tests (would need `pointfreeco/swift-snapshot-testing` or similar — defer).
- StandBy presentation testing (manual only).

---

## Manual Xcode Setup Steps (User)

These are not covered by source code in this PR because the project's pbxproj is hand-managed:

1. Create new "Widget Extension" target named `TigerDuckWidgets`, bundle ID `org.ntust.app.TigerDuck1.TigerDuckWidgets`, min iOS 18.0, embed in `TigerDuck` host app.
2. Enable App Groups capability on the new target. Add `group.org.ntust.app.TigerDuck`.
3. In the main `TigerDuck` target, add `tigerduck` URL scheme via the Info tab → URL Types.
4. Verify the `TigerDuckLiveActivity` target also has the App Group (no change needed — already present).
5. Set the widget extension's signing team to match the main app.
6. Add `TigerDuckWidgets` to the `TigerDuck.xcscheme` so widget builds run alongside app builds.

## File Touch Summary

**New files (in repo):**

- `swift/TigerDuckWidgets/*` (entire extension)
- `swift/TigerDuck/Widgets/WidgetSnapshot.swift` (shared with extension)
- `swift/TigerDuck/Widgets/WidgetSnapshotWriter.swift`
- `swift/TigerDuck/Widgets/WidgetSnapshotBuilder.swift`
- `swift/TigerDuck/Widgets/WidgetReloadCoordinator.swift`
- `swift/TigerDuck/App/WidgetURLRouter.swift`
- `swift/TigerDuckTests/Widgets/*Tests.swift`

**Modified files (in repo):**

- `tools/localization/sync_localizations.py` — add widget-extension symlink creation
- `swift/TigerDuck/App/AppState.swift` — add `openFromWidget(_:)` + `pendingWidgetDestination`
- `swift/TigerDuck/TigerDuckApp.swift` — add `.onOpenURL` handler

**User-managed (not in repo):**

- `swift/TigerDuck.xcodeproj/project.pbxproj` (new target + URL scheme + capabilities)
- `swift/TigerDuckWidgets.entitlements` (new file referenced by pbxproj)
- `swift/TigerDuck/TigerDuck.entitlements` (re-add `group.org.ntust.app.TigerDuck` locally)
- `swift/TigerDuckLiveActivityExtension.entitlements` (no change needed — should already have the group locally)
