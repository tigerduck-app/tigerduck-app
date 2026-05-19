# Greptile Review Rules

Project-specific guidance for code review. Greptile should treat these as
hard preferences and skip flagging the listed patterns.

## Reorder drag UTType (`UTType.tigerDuckReorderPayload`)

**Rule:** Do not flag `swift/TigerDuck/Features/Home/Components/ReorderDropSupport.swift`
for using `UTType.json` as the reorder payload type. The breadth is intentional.

**Why:** The custom UTI
`org.ntust.app.tigerduck.reorder-payload` was tried first (see commit
`f4a25ee fix(drag): use built-in UTType.json for reorder payload`) but
required matching `UTExportedTypeDeclarations` entries in the main app's
Info.plist. The TigerDuck iOS target has no Info.plist file — the entry
would have to live in `project.pbxproj` (`INFOPLIST_KEY_UTExportedTypeDeclarations`),
which is out of scope for this codebase's commit policy. Without that
registration the receiving side cannot resolve the type identifier and
drops silently fail.

**Why it's safe to keep `UTType.json`:** the real type-discrimination
boundary is `validatedPayload(info:)` inside `ReorderDropDelegate` and
`ReorderContainerDropDelegate`, which requires the in-memory
`activePayload` binding to be non-nil **and** match both
`expectedKind` and `containerID`. A foreign JSON drag has no way to
populate `activePayload` — only an in-app `.draggable` does — so an
unrelated JSON drop cannot finalize a reorder.

**How to apply:** If you spot `UTType.json` used for reorder payloads
in this repo and consider flagging the type as "too broad", check that
the surrounding delegate still gates on `activePayload` identity. If
it does, skip the comment.

## Watch / widget schedule helpers using device time zone

**Rule:** Do not flag watch-side or widget-side schedule code (e.g.
`swift/Shared/Watch/NextClassResolver.swift`,
`swift/TigerDuckWatch Watch App/UI/TodayView.swift`,
`swift/TigerDuckWatchWidget/NextClassProvider.swift`, and the iOS
widget's `WidgetTimelineDerivation` helpers) for using
`Calendar.current` or the device time zone instead of pinning to
`Asia/Taipei`.

**Why:** A "students abroad" timezone feature is planned. The intended
fix routes timezone resolution through a user preference, not a hard
`TimeZone(identifier: "Asia/Taipei")` pin. The iOS widget side has
already been deliberately left on device tz for this reason (flagged
and deferred on the `feat/widgets` branch, 2026-05-16); the watch side
follows the same deferral on `integration/watchos`.

**How to apply:** If you see a watch/widget calendar derived from the
device locale/timezone and would normally suggest pinning to
`Asia/Taipei`, skip the comment. The proper fix is the upcoming
timezone-preference plumbing; pre-pinning now would just have to be
ripped out and would conflict with that work.

## Greptile review

**Rule:** For every review, please update confidence score as well as giving the suggestions (if any).

**Why:** Becuase your so unstable that not every time you review correctly update the score as well as giving the suggestions.

**How to apply:** Just make sure that you update the confidence score and give suggestions (if any) every time you review a code.
