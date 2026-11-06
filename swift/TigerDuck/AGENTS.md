# App target

Rules for `swift/TigerDuck/`, the iOS app and its native macOS build.
`docs/decisions/0028-v4-layout.md` explains the folders, the shared homes and the size budget.

## Conventions

- `App/AppEnvironment.swift` is the composition root, built once per process. Features read auth
  and protected-access state from `app.authService` instead of keeping their own copy.
- Feature view models are `@Observable` and show cached data before the network fetch.
- Screens and devices see course, assignment and colour changes by observing their stores
  (`AppDataRevision`, `StoreObservation`); other cross-feature updates use the
  `NotificationCenter` names in `AppConstants`.
- Styling goes through `TigerDuckTheme`, `VisualPreset` and `VisualStylePolicy`, with no spacing
  or color system of a feature's own.
- Schedule code reads the time through `Support/Clock/AppClock`, so the debug clock override
  applies.
- `AppLogger`'s `os.Logger`s write only to the device's system log; `captureError` and
  `breadcrumb` log as private, which a logging profile can reveal, so they still scrub tokens,
  passwords and URL query strings first.
- Console and a sysdiagnose show `.public` values without a logging profile. Log errors and
  their descriptions as `.private`, and course data and backend ids too: course numbers and
  keys, device, Live Activity and token ids, and request paths that hold one. Fixed labels,
  counts, booleans and status codes stay `.public`.
- A rule with no screen and no I/O that the Watch app or an extension also needs goes in
  `swift/Packages/TigerDuckCore/`, which every target links. Other code the Watch app also needs
  goes in `swift/Shared/`, which the widget and Live Activity extensions do not compile.

## Shared homes

Each rule below has one home; call it instead of writing the rule again.
`tools/check_architecture.py` fails a second copy of the rules it knows.

- Signed-in account, sign-out, writes after a sign-out: `Account/AccountSession.swift`.
  A store of one account's data conforms to `AccountScoped`.
- The sign-in a write or send belongs to: a `SignIn` handed to the store or request, which drops
  it once that sign-in has ended (`docs/decisions/0029-account-bound-writes.md`). An account's
  `Defaults` key is an `AccountKey` (`Account/AccountKey.swift`), written `Defaults[.key, for: signIn]`.
- Courses and assignments, and every edit to them: `Stores/CourseStore.swift`,
  `Stores/AssignmentStore.swift`.
- Course colors: `Stores/CourseColorStore.swift`.
- The cached Moodle assignments: `AssignmentFetch` in `School/Moodle/`.
- Settings: a `Defaults` key in `App/AppDefaults.swift`; a raw `UserDefaults` key goes through
  `Persistence/AppUserDefaults.swift`.
- Term codes: `AcademicTerm` in TigerDuckCore.
- Today's classes, now and next: `ClassTimeline` in TigerDuckCore.
- Days without classes, from the terms and holidays: `QuietDayCalendar` in TigerDuckCore.
- Taipei dates: `TaipeiTime` in TigerDuckCore.
- A class time range on any screen, widget, Watch face or Live Activity, and its VoiceOver form:
  `TimeRange` in TigerDuckCore.
- What this device may send or apply: `Backend/Sync/SyncPolicy.swift`.
- Whether an upload already went out: `Backend/Sync/SendLedger.swift`.
- Requests to the TigerDuck backend: `Backend/Client/BackendClient.swift`.
- A cached answer revalidated with its ETag: `ConditionalGet` in `Backend/Client/ConditionalGet.swift`.
- A full sync's categories: one `CategoryReconciler` each, in `Backend/Sync/Reconcilers/`.
- Freshness of a cached answer: `Persistence/FreshnessPolicy.swift`.
- The demo account's data: `Account/Demo/demo.json`, shared with the Android app's
  `app/src/main/assets/demo.json`; a change here comes with an Android issue to copy it.
- Waiting for a state: `StateSignal` in `Support/Concurrency/`; for a time: `AppClock.sleep(until:)`
  in `Support/Clock/`.
- Deep links and sheets: `App/Routing/AppRouter.swift`.
- What a launch, a return to the app and a sign-in run, and in which order:
  `App/SceneActivation.swift`.
- Widget, Watch and Live Activity refresh: `Devices/DeviceSurfaceSyncer.swift`.

## Anti-patterns

- Gate protected NTUST screens on `NTUSTProtectedAccessState(signedIn:isEmpty:)`, not on cookie
  validity or `isNTUSTAuthenticated` alone; silent re-auth is expected.
- Do not call `AuthService.login` to re-authenticate silently: it harvests a new Moodle token
  and drops the course cache. The Moodle token renews itself on `.invalidToken`.
- Launch code contacts the TigerDuck backend only once onboarding is complete; a fresh install
  builds `AppEnvironment` before the user has seen a screen. Check `hasCompletedOnboarding` as
  `AppEnvironment.init` and `SceneActivation.refresh()` do; `completeOnboarding()` starts both.
- `TigerDuckApp.init` reads `UserDefaults`, the Keychain and the app's files only in the closure
  `TigerDuckApp.makeLaunch` hands `AfterFirstUnlock`, since before the first unlock after a
  restart they read as empty. A background entry point that can run earlier, as School Mail's
  background refresh does, asks `FirstUnlock.storedDataReadsBack()` first
  (docs/decisions/0024-launch-before-first-unlock.md).
- Do not trigger a Live Activity refresh for presentation-only changes such as `visualPreset`.
- Do not put a plain `.onTapGesture` on content in a ScrollView or lazy grid, or a plain tap or
  long-press over all of it; since iOS 18 the former fires only on a second tap and the latter
  eats each child's first tap. Use the helpers in `UI/ViewHelpers/View+ScrollSafeGesture.swift`.
