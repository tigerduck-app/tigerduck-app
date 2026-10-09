# 0001. Pin TLS public keys in code, failing soft after expiry

Status: accepted

## Context

The app's sessions with NTUST hosts carry NTUST SSO credentials, the long-lived Moodle `wstoken`
and `privatetoken`, and the library bearer token; School Mail sends the mail password over IMAP
and SMTP. The threat is campus Wi-Fi with a hostile MDM root CA installed in the device trust
store: system trust accepts certificates issued by it, so it cannot refuse that man in the middle.

The Android app pins the same hosts in `app/src/main/res/xml/network_security_config.xml`
(`tigerduck-app-android`), with the same pin set and the same expirations.

## Decision

- `swift/Shared/TLSPinningDelegate.swift` is a `URLSessionDelegate` that checks the SHA-256 of
  each certificate's SubjectPublicKeyInfo (the value Android's `pin-set` uses) against a
  per-host pin set. It is installed on every session that carries those secrets. Hosts outside
  the pin table fall through to system trust, so it is safe on a session that also reaches
  other hosts.
- Each pin set holds the leaf and the intermediate, so a leaf rotation that keeps the
  intermediate does not break the app.
- `swift/TigerDuck/Services/Mail/Transport/MailTLSVerifier.swift` applies the same rules to
  IMAP and SMTP: the system chain and the hostname must pass, then some certificate's SPKI must
  be in the host's pin set. Its custom verification callback replaces all of BoringSSL's
  checks, hostname included, so its own chain and hostname evaluation is the connection's only
  validation.
- After a pin set's expiration date both fall back to system trust instead of failing, as
  Android's `expiration` attribute does, so a build that was never updated keeps working when
  TWCA rotates the chain (https://github.com/tigerduck-app/tigerduck-app/issues/92). They log
  it at `.fault`, which Console and sysdiagnose flag.
- Nothing lets a user bypass a failed pin check.

## Alternatives

- ATS `NSPinnedDomains` in Info.plist: declarative, but it has no fail-soft expiration, and a
  delegate's `useCredential(URLCredential(trust:))` cannot override its rejection, because the
  system enforces it beneath `URLSessionDelegate`. Both were tested.

## Consequences

- Pins must be rotated before they expire, in both repositories at once; diverging pin sets
  break one platform before the other. A release-calendar reminder before each expiration date
  prompts a build with new pins, and the post-expiry fault in the system log shows a missed
  rotation. The `tls-pin-rotation` skill has the steps.
