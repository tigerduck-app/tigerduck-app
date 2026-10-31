# Backend

Rules for `swift/TigerDuck/Backend/`: the TigerDuck backend clients, its auth tokens, cloud sync,
push registration, the course catalog and `APIVersionGate`.

## Conventions

- New TigerDuck backend clients copy the request construction, auth header and error handling
  of `Push/PushAPIClient.swift`, as `Sync/SettingsDocumentClient.swift` does. Cloud sync reaches
  the backend through `PushCoordinator`.
- Add Course searches the term's catalog from the backend (`CourseCatalog/`) on the device and
  sends the school nothing; do not add a school query or a fallback to one there.

## Gotchas

- `Push/ScheduleSyncService.swift` builds the 48-hour event list it sends to the backend with
  the Live Activity resolvers, so a resolver change also changes what the server pushes.
- A `410 Gone` from the TigerDuck backend latches `Client/APIVersionGate.swift` for good, and the
  app asks the user to update. Only backend clients report to it; a 410 from the school's
  servers means a page moved.
