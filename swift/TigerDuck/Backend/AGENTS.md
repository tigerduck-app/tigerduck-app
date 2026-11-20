# Backend

Rules for `swift/TigerDuck/Backend/`: the TigerDuck backend clients, its auth tokens, cloud sync,
push registration, the course catalog and `APIVersionGate`.

- Cloud sync reaches the backend through `PushCoordinator`.
- Every write the backend settles by time goes through `BackendClient.sendStamped`, which sends
  the edit's `age_ms` measured as the request goes out; no device time is sent or compared with a
  backend time. An automatic course colour is the one write sent with an `hlc`, a time the
  snapshot named.
- Add Course searches the term's catalog from the backend (`CourseCatalog/`) on the device and
  sends the school nothing, with no school query or fallback to one.
- Nothing derived from school data, the course and assignment uploads, goes before the
  sign-in's first pull from the backend is applied (`Sync/FirstPullGate.swift`).
