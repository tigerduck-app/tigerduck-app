# Backend

Rules for `swift/TigerDuck/Backend/`: the TigerDuck backend clients, its auth tokens, cloud sync,
push registration, the course catalog and `APIVersionGate`.

## Conventions

- Every request to the TigerDuck backend goes through `Client/BackendClient.swift`, which builds
  it, adds the bearer token, maps the `/v4` error envelope and owns the one refresh after a 401.
  A client describes its endpoints with `BackendRequest`; do not create a `URLSession` or read a
  status code's body elsewhere. Cloud sync reaches the backend through `PushCoordinator`.
- Every write the backend settles by time sends the edit's own `hlc`
  (`BackendClient.sendStamped`); a 409 `clock_ahead` is answered by stamping it again from the
  server's clock, never by sending it unstamped, and an outbox edit held by then
  (`BackendClient.holdsResend`) waits in the outbox instead.
- An upload goes through `Sync/SendLedger.swift`: one send in flight per channel, never
  cancelled by a newer one, and an unchanged body skipped by its fingerprint.
- Add Course searches the term's catalog from the backend (`CourseCatalog/`) on the device and
  sends the school nothing; do not add a school query or a fallback to one there.

## Gotchas

- `Push/ScheduleSyncService.swift` builds the 48-hour event list it sends to the backend with
  the Live Activity resolvers, so a resolver change also changes what the server pushes.
- A `410 Gone` from the TigerDuck backend with `api_retired` or `app_version_retired`, or with no
  readable code, latches `Client/APIVersionGate.swift` for good, and the app asks the user to
  update. Only `BackendClient` reports to it; a 410 from the school's servers means a page moved.
- Nothing derived from school data, the course and assignment uploads, goes before the
  sign-in's first pull from the backend is applied (`Sync/FirstPullGate.swift`).
