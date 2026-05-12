# watchOS App — Design Spec

- **Date**: 2026-05-12
- **Branch**: `feat/watchos`
- **Author**: brainstormed with Claude (Opus 4.7)
- **Reference**: Android Wear module at `~/StudioProjects/tigerduck-app-android/wear/`

## 1. Goals

Ship a watchOS companion app for TigerDuck that mirrors the feature set of the Android Wear module: a quick-glance schedule view on the wrist, a watch-face complication, and a Smart Stack widget for the next class. The watch app depends on the iPhone for authentication and data — there is no login UI on the watch, no direct backend access, and no standalone mode.

## 2. Scope

### In scope (v1)

- New `TigerDuckWatch` (Watch App) target embedded inside the iOS app's archive.
- New `TigerDuckWatchWidget` (Widget Extension) target embedded inside the watch app.
- Three SwiftUI screens (NowNext, Today, Settings) plus pushed detail (CourseDetail).
- WatchConnectivity-based schedule sync from iPhone → Watch.
- Force-sync (`Sync now`) via watch → phone message.
- WidgetKit widget supporting four complication/Smart Stack families.
- Locale + accent-color propagation from phone.

### Out of scope (v1, documented for posterity)

- Independent watchOS standalone mode (no SSO on watch, no Keychain on watch, no direct backend calls).
- Per-course complication configuration intents.
- Standalone watch notifications mirroring iOS push.
- Audio / haptic class-start alerts.
- Background app refresh (`WKApplicationRefreshBackgroundTask`) — unnecessary; WC delivers context automatically.
- Padding-settings screen (Wear has it for round/rectangular display variance; Apple Watch is uniform).
- Course color editor on watch (read-only mirror of phone-side color).
- Onboarding flow on the watch (empty states direct user to iPhone).

## 3. Targets, identifiers, entitlements

### New Xcode targets

| Target | Type | Bundle ID | Deployment | Folder |
|---|---|---|---|---|
| `TigerDuckWatch` | Watch App (watchOS single-target) | `tw.smashit.tigerduck.watchkitapp` | watchOS 11.0 | `swift/TigerDuckWatch/` |
| `TigerDuckWatchWidget` | Widget Extension | `tw.smashit.tigerduck.watchkitapp.widget` | watchOS 11.0 | `swift/TigerDuckWatchWidget/` |

### Pairing & distribution

- Watch app declares `WKCompanionAppBundleIdentifier = tw.smashit.tigerduck`.
- iOS app target gains the watch app as an embedded target dependency. Single Xcode archive, single App Store Connect upload, single listing.
- Watch app and widget pinned to the iOS app's `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. `release-bump` skill will need a one-line update later to bump those two targets too; out of scope for this PR (v1 inherits `1.6.1` manually).

### Entitlements

- New App Group: `group.tw.smashit.tigerduck.watch`, shared between `TigerDuckWatch` and `TigerDuckWatchWidget` only.
- iOS app target: **no new entitlements**. `WCSession` requires none.

### Schemes

- One new shared scheme `TigerDuckWatch`. Widget runs hosted by the watch app scheme; no separate scheme.

## 4. WatchConnectivity data flow

### Transport choices

| Use case | API | Why |
|---|---|---|
| Phone → watch: latest schedule | `WCSession.updateApplicationContext(_:)` | Coalesced "latest value" semantics. Survives termination of either app. Mirrors Wear's DataClient. |
| Watch → phone: force re-sync | `WCSession.sendMessage(_:replyHandler:errorHandler:)` | Live request; falls back to cached snapshot on error. |
| Phone → watch: debug-clock spoof | `WCSession.transferUserInfo(_:)` | Rare, queued, ordered. Mirrors `DebugClockListener`. |

No `transferFile` — payload is small (raw JSON < 16KB for a full semester).

### Wire format

`applicationContext` dictionary keys:

```
{
  "v": 1,                          // protocol version, for forward-compat
  "courses": [ {...}, ... ],       // [[String: Any]] — array of WatchCourse dicts
  "accentHex": "#FF8800",
  "syncedAtMs": 1747000000000,     // Int64 ms epoch
  "loggedIn": true,
  "languageTag": "zh-Hant-TW"      // BCP-47, nullable
}
```

The payload is uncompressed in v1 — full-semester arrays are well under WC's practical
`applicationContext` limit. Apple's `Compression` framework doesn't expose a direct
gzip wrapper, so taking on compression would mean either zlib (incompatible field name)
or shipping a small gzip helper for no measurable benefit. A `v: 2` payload can add
compression later if real-world sizes demand it.

`WatchCourse` JSON shape (flat DTO, decoupled from `SDCourse`). One entry per concrete weekday session — a course that meets twice a week serialises to two `WatchCourse` rows.

```
{
  "id": "1142EC1013701-1-3",       // courseNo-weekday-firstPeriod, stable
  "courseNo": "1142EC1013701",
  "name": "資料結構",
  "teacher": "...",
  "classroom": "TR-313",           // per-(weekday, period) classroom resolved
  "colorHex": "#FF8800",
  "weekday": 1,                    // 1=Mon..7=Sun, ISO
  "startHHmm": "10:20",            // first-period start, phone-resolved
  "endHHmm": "11:10",              // last-period end, phone-resolved
  "periodLabel": "3-4"             // human-readable, e.g. "3-4" or "A"
}
```

Phone resolves any timezone- or settings-dependent values into absolute values before sending; the watch never re-runs that logic. Period-to-bell-time mapping happens on the phone (it owns the existing `TimetablePeriod` table).

### Phone-side lifecycle (`Services/Watch/WatchSyncCoordinator.swift`)

1. Created at app launch from `TigerDuckApp`. Activates `WCSession.default` and sets itself delegate.
2. Subscribes to `SDCourse` change notifications, accent color preference, language preference, and auth state. On any change, pushes a fresh context. Debounced ~500ms to coalesce bursts.
3. On `didReceiveMessage` with `{ "kind": "syncRequest" }`, immediately re-pushes context.

### Watch-side lifecycle

1. `WatchApp.swift` (the `@main` entry) activates `WCSession.default` at launch.
2. `ScheduleStore: ObservableObject, @MainActor` is the equivalent of Wear's `ScheduleRepository`. On `didReceiveApplicationContext`, it decodes the payload, writes it to the shared App Group file `schedule.json.gz`, updates published state, and calls `WidgetCenter.shared.reloadAllTimelines()`.
3. Cold start: read `schedule.json.gz` from the App Group if present; otherwise show "never synced" empty state and trigger a one-shot `syncRequest` (10-min cooldown — mirrors Wear's `SyncRequester.maybeRequest`).
4. The widget extension reads `schedule.json.gz` from the same App Group; never opens `WCSession` itself.
5. `Sync now` button in SettingsView invokes `sendMessage(syncRequest)`. Failures are silent for auto-syncs, surfaced (e.g. a brief inline label) only when the user tapped the button explicitly.

## 5. Watch app UI

### Navigation shape

Top-level horizontal paged `TabView` with `.tabViewStyle(.page)`. Each page roots its own `NavigationStack` for push-detail flows. Mirrors Wear's three-page `HorizontalPager` + swipe-dismiss nav.

```
WatchRootView (TabView, .tabViewStyle(.page))
├── Page 0: NowNextView   (NavigationStack root)
├── Page 1: TodayView     (NavigationStack root)
│             └ row tap → CourseDetailView
└── Page 2: SettingsView  (NavigationStack root)
              └ "Sync now" button
```

### Screens

| View | Data | Notes |
|---|---|---|
| `NowNextView` | Current course (if a period is in progress) + next course of today | Two stacked cards with accent stripe. Wrapped in `ScrollView` so crown can scroll if both cards overflow on smaller watches. Empty state: "Nothing more today." |
| `TodayView` | `[WatchCourse]` filtered to today's weekday, sorted by first period | Compact `List` (auto-crown-scroll). Time range • course name • room per row. Tap pushes detail. |
| `CourseDetailView` | Single `WatchCourse` | Course name, teacher, classroom, time range, period numbers, accent swatch. Wrapped in `ScrollView`. |
| `SettingsView` | `loggedIn`, `lastSyncedAt` text | `List` with: login status row, "Last synced X ago" row, "Sync now" button, app version footer. |

### State

- `ScheduleStore: ObservableObject` injected at root via `@StateObject` / `.environmentObject(_:)`. Publishes `snapshot: WatchSnapshot?`. Same role as Wear's `ScheduleRepository`.
- One-shot cold-start sync request guarded by 10-minute cooldown (Wear parity).

### Theming

- `WatchTheme` modifier reads `snapshot.accentHex` → `Color`, applies via `.accentColor(_:)` at the root so it propagates through `Button`/`ProgressView`/`Link` tints.
- Falls back to default accent `#FF8800` when no snapshot yet.

### Locale handling

- Watch reads `snapshot.languageTag`, applies `\.environment(\.locale, Locale(identifier: tag))` at the root. SwiftUI re-renders when locale changes — no `Activity.recreate()` equivalent needed.

### Digital crown contract

- Crown is reserved for **vertical scrolling within the active tab**, not for top-level tab navigation. Spec authors and reviewers must not switch the top-level `TabView` to `.tabViewStyle(.verticalPage)` — it would break this contract.
- `List` and `ScrollView` get crown scrolling for free on watchOS; we rely on the default, never overriding `.focusable(false)`.
- Use `.digitalCrownRotation(_:)` directly only for value editors that aren't lists (e.g. a future font-size stepper). None in v1.

## 6. Widget extension (Smart Stack + complications)

### Single widget: `NextClassWidget`

WidgetKit on watchOS 11 unifies complications and Smart Stack under one widget definition. Supported families:

| Family | Wear analogue | Rendering |
|---|---|---|
| `.accessoryCircular` | `SHORT_TEXT` complication | 2-char monogram from course name, accent-tinted ring. |
| `.accessoryCorner` | corner complication slot | Time on outer arc via `widgetLabel`, course name truncated in the corner. |
| `.accessoryInline` | `SHORT_TEXT` inline | One line, ≤20 chars: `"􀐱 Algo · 11:10"` or `"Algo in 12 min"` if within 30 min of start. |
| `.accessoryRectangular` | `LONG_TEXT` complication / Wear Tile | 3-line: course name (headline) • `HH:mm–HH:mm` (subheadline) • classroom (caption). Doubles as the Smart Stack rectangle. |

No `IntentConfiguration` in v1 — single static widget = "next class," matching Wear.

### Timeline strategy (`TimelineProvider`)

1. Reads `schedule.json.gz` from the shared App Group. Never goes through WC. Never touches the network.
2. Computes today's class boundary times: `[now, class1.start, class1.end, …, endOfDay]`. Emits one entry per boundary; each entry's payload is "what's the next class as of *this* time."
3. After end-of-day, emits a single "Nothing more today" entry valid until `04:00` tomorrow; `.policy = .atEnd` triggers reload then. The watch app will have refreshed by then via WC.
4. Whenever the watch app rewrites `schedule.json.gz`, it calls `WidgetCenter.shared.reloadAllTimelines()` to invalidate.

### Relevance (Smart Stack)

Each entry gets a `TimelineEntryRelevance(score:duration:)`:

- High (`90`) for entries within 30 minutes of a class start — surfaces the widget in Smart Stack near class time.
- Baseline (`30`) otherwise.

Cheap to include, real ergonomic win.

### Refresh discipline

- Widget code never opens `WCSession`. Only the host watch app does.
- Widget never schedules timer-based reloads — only timeline boundary reloads + on-demand reloads from the watch app.
- `relevances()` computed at timeline generation, not at render.

### Preview snapshots

Hard-coded sample course `"資料結構 · D101"` for snapshot/placeholder timelines so the watch face picker, gallery, and Smart Stack onboarding render before any real data has arrived.

## 7. Apple Watch HIG conformance

### Native components only

- `NavigationStack` + `.navigationTitle(_:)` — system handles title placement near the time; no custom headers.
- `List` for every vertical row collection (Today, Settings).
- `Button`, `Toggle`, `Stepper`, `Link` — no hand-rolled tappable rectangles.
- `ContentUnavailableView` (watchOS 10+) for every empty state (never synced, not logged in, no classes today, course not found).
- `ProgressView()` for loading; no custom spinners.

### Typography & layout

- System text styles only: `.headline` for course name, `.subheadline` for time range, `.caption2` for "Last synced X ago." All scale with Dynamic Type and Apple's watch size classes (40mm vs 49mm Ultra).
- No fixed point sizes. No hardcoded `.frame(width:)`/`.frame(height:)` on layout containers — SwiftUI + safe-area drives size.
- Tap targets ≥ 44×44pt. Natural with `List` rows.

### Color & vibrancy

- Global accent via `.accentColor(Color(hex: snapshot.accentHex))` at the root — propagates to all standard control tints.
- Per-course color used only as a thin leading accent stripe + symbol tint, not row background fill. OLED-black backgrounds (battery + Apple Watch app aesthetic).
- Backgrounds: rely on default container chrome. No explicit fills.

### Icons

- SF Symbols throughout: `chevron.right`, `arrow.clockwise`, `person.crop.circle.badge.exclamationmark`, `calendar.badge.clock`, etc.
- `.symbolRenderingMode(.hierarchical)` for multi-tone glyphs in widgets.

### Widget HIG specifics

- `accessoryCircular`: `Gauge` or `ZStack { Circle + Text }` — both Apple-blessed.
- `accessoryRectangular`: max 3 lines, each a single line (no wrapping).
- `accessoryInline`: ≤20 chars including SF Symbol prefix.
- `accessoryCorner`: `widgetLabel { Text(...) }` for outer arc, content in the corner spot.
- All families: `.widgetAccentable()` on secondary glyph/text for tinted watch faces.
- `.containerBackground(.fill.tertiary, for: .widget)` on every entry view.

### Navigation depth

Two levels max: TabView page → pushed detail/settings. Edge-swipe-back is `NavigationStack`'s built-in behaviour and maps cleanly to Wear's swipe-dismiss.

### Transitions

System transitions only — TabView page swipe, NavigationStack push. No custom `.transition(...)` overrides.

## 8. Localization

- `localization/` git submodule (shared `app-translation` repo) is the source of truth for all UI strings across iOS + Android.
- Watch app + widget consume strings via the same generated `Localizable.strings` files the iOS app already uses, wired through Target Membership.
- New keys for watch-specific copy added to the shared JSON source: `watch.now`, `watch.next`, `watch.no_classes_today`, `watch.empty.never_synced`, `watch.empty.not_logged_in`, `watch.empty.course_not_found`, `watch.settings.sync_now`, `watch.settings.last_synced`, `watch.settings.signed_out`, `watch.settings.app_version`.
- Watch widget gets locale via the standard widget-extension locale propagation (respects host watch's system locale). We accept the small compromise that the widget may temporarily render in the watch's system language before the next `applicationContext` push aligns it — same behaviour Wear's complication has.

## 9. Error & edge cases

| State | UI | Behavior |
|---|---|---|
| Never synced (cold install) | `ContentUnavailableView`: "Open TigerDuck on your iPhone to sync" | Trigger `sendMessage(syncRequest)` if reachable; otherwise wait. Complication shows `"—"`. |
| Not logged in on phone (`loggedIn=false`) | `ContentUnavailableView`: "Sign in on your iPhone" | Cached schedule still shown with a "Signed out" inline banner. |
| Stale snapshot (`now − syncedAtMs > 24h`) | Subtle "Last synced X ago" indicator | Don't block UI. Auto-request sync (10-min cooldown). |
| Phone unreachable for sync | Silent failure for auto-sync; brief inline error if user tapped "Sync now" | Cached data remains visible. Logged via watch-side `AppLogger` equivalent. |
| WC payload decode failure | Keep prior cache | Log error; do not overwrite `schedule.json.gz`. Mirrors the audit-branch SDCourse preserve-on-encode-failure fix. |
| Schedule empty today | NowNext: "Nothing more today." Today: empty state. | Complication shows day-end placeholder. |
| Course tapped that no longer exists | `ContentUnavailableView`: "Course not found" | Mirrors Wear's `watch_not_found`. |

## 10. Testing strategy

### Unit tests — new `TigerDuckWatchTests` target

- `WatchPayloadCodec`: round-trip encode/decode; missing-field tolerance; forward-compat (`v: 1` stays decodable when `v: 2` is introduced).
- `NextClassResolver`: given `[WatchCourse]` + a fixed `Date`, returns correct current/next pair. Critical-path. Mirror the test surface of Wear's `NextClassResolver`. Edge cases: between classes, before first class, after last class, weekend, no classes today.
- `WatchScheduleStore`: WC delegate writes file + reloads widget timelines; respects 10-min sync cooldown.

### Phone-side unit tests — added to `TigerDuckTests`

- `WatchSyncCoordinator`: serialisation `SDCourse[]` → `WatchCourse[]` (field mapping, period→time resolution, color preservation); debouncing burst updates; correct response to `syncRequest`.

### Widget snapshot tests — `TigerDuckWatchWidgetTests` target

- Render each of the four families for the sample course and the empty state. Compare via SwiftUI `ImageRenderer` snapshots committed to the repo.

### Manual test plan (run before merge)

- Pair iPhone Simulator with Apple Watch Simulator (Xcode → Devices → pair).
- Smoke: sign in on phone, observe context push, verify NowNext shows correct class for the current time.
- Force-quit watch app; verify widget still renders from cached file.
- Toggle airplane mode on phone; tap "Sync now" on watch; verify graceful failure (no crash, cached data remains).
- Change accent color on phone; confirm app + widget pick it up after next reload.
- Switch device language on phone; confirm watch app re-renders in the new language after next context push.

## 11. Open items / future work

- Padding-settings UI is intentionally absent in v1. If user feedback shows a real need (unlikely given Apple Watch's uniform shape), revisit.
- Shared Swift Package extraction (`TigerDuckCore`) deferred. If the `feat/widgets` branch and this branch both end up duplicating model code, that's the trigger to revisit.
- `release-bump` skill update for the two new targets — separate one-line PR after v1 lands.
- Independent watch mode — not on the roadmap. Companion-only matches Wear.
