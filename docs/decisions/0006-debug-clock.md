# 0006. Real time for the server and the OS, app time for display

Status: accepted

## Context

Debug builds can override the app clock (`AppClock`, `ClockOverride`), frozen or ticking from
a chosen instant. The backend dispatches its jobs on the real wall clock, and the OS checks
the dates it is handed against the real clock: a Live Activity `staleDate`, `Task.sleep` and
WidgetKit timeline entry dates.

## Decision

- UI, class status and scheduling code read time through `AppClock`, so the override applies
  everywhere. Auth and network timestamps (session expiry, cookie and cache TTLs, login
  timestamps) stay on real time, since those expire in real time.
- `ScheduleSyncService.sync` builds its 48-hour window from `AppClock.now()`, so the server's
  event window matches what the Live Activity, widgets and watch show; the horizon is display
  state.
- A date the server or the OS acts on goes through `AppClock.realTime(forApp:)`: every
  `fireAt` from `ScheduleSyncService.buildEvents`, the Live Activity `countdown_target` (the
  end job's `fire_at`), the `staleDate` and automatic-end sleep in `LiveActivityCoordinator`,
  and the scenario boundary sleep in `swift/TigerDuck/App/AppState+LiveActivity.swift`.
- Snapshot dates stay in app time; the widget and Live Activity extensions translate them
  when they render.
- In frozen mode `realTime(forApp:)` is not idempotent (real now moves while fake now stands
  still), so each result is captured once, at scheduling time.
  `LiveActivityUpdateTokenRegistration.countdownTargetRealTime` is computed when the
  registration is made, so every retry of the send asks for the same instant instead of moving
  the end job out by the backoff.

## Alternatives

- Sending app-clock dates as they are: a fake clock filed the end push at the fake instant,
  days out or already past, and in the second case the register endpoint
  (`server/routes/live_activities_v3.py` in `tigerduck-app/tigerduck-backend`) files no end job
  and the activity has no remote end. A raw `staleDate` under a clock set to a future date
  makes `Activity.request` fail with `ActivityInput error 0`.

## Consequences

- A new date sent to the server or handed to the OS goes through `AppClock.realTime(forApp:)`
  once, where it is scheduled.
