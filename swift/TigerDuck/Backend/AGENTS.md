# Backend

Rules for `swift/TigerDuck/Backend/`: the TigerDuck backend clients, its auth tokens, cloud sync,
push registration, the course catalog and `APIVersionGate`.

- Cloud sync reaches the backend through `PushCoordinator`.
- Every write the backend settles by time goes through `BackendClient.sendStamped` with the
  edit's own `hlc`, and is never sent again unstamped after a 409 `clock_ahead`.
- `Sync/SyncClock.swift` gives every sync time: `stamp()` and `lowestNextStamp` for an edit's
  stamp, a cutoff and a course add's start or landing, which are compared with stamps; `mark()`
  and `lowestNextMark` for a term reset's landing, a holiday edit and the full sync's fetch they
  are compared with. A `Date()` is compared only with another `Date()`.
- A sync time kept past the request that stamped it, in memory or stored, moves with
  `SyncClock.onPullBack` when a header brings the clock back.
- Add Course searches the term's catalog from the backend (`CourseCatalog/`) on the device and
  sends the school nothing, with no school query or fallback to one.
- Nothing derived from school data, the course and assignment uploads, goes before the
  sign-in's first pull from the backend is applied (`Sync/FirstPullGate.swift`).
