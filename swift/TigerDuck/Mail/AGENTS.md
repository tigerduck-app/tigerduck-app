# School Mail

Rules for `swift/TigerDuck/Mail/`: the School Mail client, its IMAP and SMTP transport, cache,
search index and background checks. The screens are in `Features/SchoolMail/`.

## Anti-patterns

- Do not route School Mail through the TigerDuck backend. The phone talks to the school's mail
  server directly, and the mail password stays on the device (`Store/MailCredentialStore.swift`).

## Gotchas

- `MailCredentialStore` is the one Keychain item readable after first unlock
  (`.afterFirstUnlockThisDeviceOnly`), because new-mail checks run in Background App Refresh
  while the phone is locked. Everything else uses `SecureStore`'s `.whenUnlockedThisDeviceOnly`.
- School Mail is hidden on macOS (`Core/SchoolMailAvailability.swift`), and its sources are
  left out of the Mac build.
