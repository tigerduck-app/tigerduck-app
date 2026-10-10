# 0004. The course-name font scale is iOS and iPadOS only

Status: accepted

## Context

Class-table cells on a phone are narrow, so a setting scales the course-name font.
`CourseCardFontScale` (`swift/TigerDuck/Shared/CourseCardFontScale.swift`) holds the slider
range, 0.6…1.2× in slider units that render sites multiply by `baselineMultiplier` (1.4).
`CourseCardFontScaleStore` keeps the value in the App Group `UserDefaults` suite
(`group.org.ntust.app.TigerDuck`) so the widget extension reads what the app writes, and
`AppState.courseCardFontScale` writes the snapped value and asks `WidgetReloadCoordinator` for a
debounced timeline reload. The same sources build the native macOS app and its widgets, and the
Watch app shows the day's classes too.

## Decision

- Only the iOS and iPadOS class table (`TimetableGridView`) and home-screen widgets (Next Class,
  Today, Week) apply the scale, and only the iOS app has the slider (`FontSizeSettingsView`).
- macOS: the Mac class table keeps a fixed `.callout.weight(.semibold)` course-name font
  (`MacClassTableView.courseCell` in `swift/TigerDuck/Platform/Mac/MacClassTableView+Grid.swift`)
  and `MacSettingsScene` has no slider. The Mac widgets share the widget views and read the
  store, but nothing on the Mac moves it off the default, so they render at the baseline. Mac
  surfaces are sized for a desktop window.
- watchOS: the Watch app and the Watch widget sources (`swift/TigerDuckWatchWidget/`, which no
  target builds) use their own App Group (`group.org.ntust.app.TigerDuck.watch`) and do not read
  the scale. They show course names in system text styles such as `.headline`, which follow the
  watch's own text size.

## Alternatives

- A slider on the Mac: the class-table grid there spreads its columns across up to
  `MacContentWidth.wide` (1280 points), so its cells are not narrow the way a phone's are.
- Honoring the scale on the Watch: the value lives in the phone's App Group, so a sync channel
  to the Watch would have to be built before the setting could reach Watch surfaces.

## Consequences

- Mac and Watch views that do not read `courseCardFontScale` are correct as they are.
- Extending the scale to the Watch starts with a sync path from the phone, not with reading
  `CourseCardFontScaleStore` there.
