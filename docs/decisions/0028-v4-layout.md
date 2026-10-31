# 0028. The v4 layout: folders by responsibility, one home per rule, a size budget

Status: accepted

## Context

The app target's `Services/` folder held the school's clients, the TigerDuck backend's, School Mail
and the caches side by side, and rules shared by several of them had no place of their own, so each
caller wrote its own copy: the Taipei calendar three times (the app's, the Watch's and the
widgets'), "now and next class" four times, a login generation compared in 44 files, six ways of
deciding whether an upload already went out. Types grew the same way: `AppState` is one type spread
over 16 files of nearly 3,900 lines. The extensions could not share the app's code and copied it,
and the macOS build's source list was kept by hand in two copies.

## Decision

- Sources of the app target live in folders named for their responsibility:
  - `App/` the entry points and app-wide wiring; `Account/` the signed-in account and sign-out;
    `Stores/` the observable stores screens read and edit through;
  - `Persistence/` storage: `DataCache`, the Keychain and the SwiftData models;
  - `School/` NTUST, SSO, Moodle, the library and the school's pages; `Backend/` the TigerDuck
    backend's clients, tokens, sync and push; `Mail/` School Mail;
  - `Devices/` widgets, the Watch and Live Activities; `Features/<feature>/` views, view models
    and their components; `UI/` shared views, the theme and view helpers; `Platform/Mac/` the
    Mac's own screens; `Migrations/` one-time upgrade code; `Support/` the clock, concurrency,
    logging and security helpers and plain extensions; `Debug/`.

  `Stores/` arrives with the stores; `Bridge/`, `Models/Domain/` and `Shared/` hold code the
  later phases split into these folders and TigerDuckCore.

  Screens talk to stores and the account; stores reach `School/`, `Backend/` and
  `Persistence/`. `School/`, `Backend/`, `Mail/`, `Migrations/` and `Devices/LiveActivity/` have
  an AGENTS.md of their own.
- `swift/Packages/TigerDuckCore` is a local Swift package for rules with no screen and no I/O.
  The app, the Watch app and the widget, Live Activity and Watch complication extensions link it,
  so an extension calls a rule instead of copying it. Its API is `public`, it builds in the Swift 6
  language mode without a default actor, and `swift test` runs its tests in the `TigerDuckCore`
  job of `.github/workflows/tests.yaml`. It holds `TaipeiTime`, the term codes
  (`AcademicTerm`), a day's classes (`ClassTimeline`) and the quiet days (`QuietDayCalendar`).
- Each shared rule has one home, listed under "Shared homes" in `swift/TigerDuck/AGENTS.md` and
  under "Conventions" in a folder's AGENTS.md for a rule of that folder alone.
- A type stays under 250 lines, its extensions in other files counted and its nested types not;
  a SwiftUI view under 200. A class or actor holds at most 10 stored instance properties, and a
  file stays under 400 lines.
- `tools/check_architecture.py` checks the Swift sources of the app target and of TigerDuckCore,
  tests left out. Each rule names the refactor phase that turns it on, and the script fails the
  rules of the phases up to `ENFORCED_PHASE` while it counts the others:

  | Phase | Rule |
  | --- | --- |
  | 0 | `"Asia/Taipei"` outside TigerDuckCore; two app-target Swift files with one base name; an `on_screen_tests` entry in `tests.yaml` naming no test |
  | 1 | the ROC year offset, `1911`, outside TigerDuckCore in any shipping target |
  | 2 | a login generation compared outside `Account/` |
  | 3 | `dataDidUpdate` or `isUpdatingFromNetwork`; `UserDefaults` outside `Persistence/` |
  | 4 | a `URLSession` created outside `School/NTUST/`, `Backend/Client/` and `Mail/Transport/` |
  | 6 | the size budget; `Features/` using a type declared in `School/`, `Backend/` or `Persistence/` |
  | 7 | `Task.sleep` outside `Support/Clock/` and `Support/Concurrency/` |

  `architecture.yaml` runs it, with `tools/check_account_state.py`, on every pull request to
  `main` and `dev`.
- The macOS build's `INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` arrays are every app-target Swift
  file minus `tools/macos-excluded-sources.txt`, written by `tools/check_macos_sources.py --write`.
- The `.lproj` folders are built, not checked in: each Apple target's "Generate Localizations"
  phase runs `tools/localization/build_apple_lproj.sh`, which generates them from
  `app-translation/source/` into the target's temp folder and copies them into the bundle. The
  build sandbox stays on; the paths it may write are listed in
  `tools/localization/apple-lproj.xcfilelist`.

## Consequences

- A new file goes into the folder of its responsibility, and `check_macos_sources.py --write`
  decides its Mac membership with the exclusion list.
- Writing a shared rule again outside its home fails CI once its phase is enforced; the message
  names the home. `ENFORCED_PHASE` reaches 7 with the last phase, and every rule fails from then.
- Adding or removing a locale in app-translation means regenerating the output list with
  `build_apple_lproj.sh --list`; the build fails until it is.
- Code the Watch app shares with the phone that is not a pure rule, such as the Watch wire format,
  the TLS pins and `CredentialPost`, stays in `swift/Shared/`.
