# 0025. Pin NTUST's CAs from a signed document, and let the user continue past a public root

Status: accepted. Supersedes [0001](0001-tls-pinning.md).

## Context

The app's sessions with NTUST hosts carry the SSO credentials, the Moodle `wstoken` and
`privatetoken` and the library bearer token, and School Mail sends the mail password over IMAP and
SMTP. The threat is still a root CA installed on the device, by an MDM profile or a campus proxy:
system trust accepts certificates it issues, so it cannot refuse that man in the middle.

Under 0001 the pins were compiled in, a leaf and its intermediate per set. Every CA change needed
a release of both apps before the new certificates went live, and a renewal under an intermediate
no build pinned failed every NTUST request until the user updated.

## Decision

- Pins are CA-only: intermediates and roots, never a leaf. The built-in table is
  `swift/Shared/TLSPins/TLSPinTable.swift`; it is the fallback, and its `baselineSerial` is the
  serial of the first production document.
- The backend publishes the pins as an Ed25519-signed document at
  `https://api.tigerduck.app/.well-known/tigerduck/tls-pins.json`, signs it on the production
  server, and republishes on its own when its hourly watcher sees a new CA
  (tigerduck-backend). The apps verify the signature over the payload bytes with keys built into
  them, a current one and a standby whose private half is kept offline. They accept a serial no
  lower than the one they hold, an equal one only with the same payload, never a document past its
  `expires_at`, and verify the stored copy again on every load.
- A document's set replaces the built-in set of the same id once its serial is above
  `baselineSerial`; a set it leaves out keeps the built-in pins. A set's expiry is the later of the
  two, so a document cannot end pinning early. Sets the built-in table does not have are ignored.
- The document is fetched on a session with system trust only, at the first foreground, at most
  every six hours after, and once per set per launch after a mismatch. Failures are silent.
- `TLSPinEngine` in `swift/Shared/TLSPins/` applies the rules for the phone, the Mac, the Watch and
  School Mail. System trust runs first; then some SPKI of the chain system trust built, up to its
  anchor, must be in the set's pins. On a mismatch `TLSPinningDelegate` holds the handshake while
  the document is fetched again and checks once more, so a fixed document lets the same request
  through. `MailTLSVerifier` runs synchronously on a NIO event loop, so it fails that connection,
  and its next connect uses the new pins.
- A chain still refused may be continued past only when its anchor's SPKI is in the valid
  document's `prompt_roots`, the TLS roots of Mozilla's store. That is checked again when the
  prompt shows and when Continue stores, since the document can expire or be replaced meanwhile.
  Continue trusts the leaf's and the intermediates' SPKIs, never the root's, for that set until the
  build number changes. The acceptance lives in `UserDefaults`, not the Keychain, which outlives an
  uninstall. One prompt shows at a time, in the foreground only, each set at most once per launch
  and not within an hour of a Cancel; a background refusal waits for the next foreground.
- `api.tigerduck.app` is not pinned. Cloudflare rotates its edge certificates across several CAs,
  so a pin would break the app at an unannounced rotation; Certificate Transparency monitoring of
  the zone stands in for it.
- The Watch follows the phone: the phone forwards the verified envelope and its acceptances, the
  Watch verifies the envelope itself and keeps only acceptances of its own build, and on a refusal
  the library page asks the user to open the phone.

## Why only listed public roots get the prompt

iOS cannot tell a root installed on the device from a system root: `SecTrustEvaluateWithError`
accepts both. Offering Continue for any chain system trust accepts would hand the MDM or proxy
root, the threat pinning exists for, a button to get through. A root from Mozilla's list cannot be
installed that way, so the prompt is limited to those, and with no valid document nothing is
eligible. Storing the leaf and intermediates, never the root, keeps an acceptance from trusting
everything a public root issues.

## Accepted risk

The production server holds the signing key and signs automatically, so whoever takes it over can
publish any pins. Pins only narrow system trust, so the worst outcomes are pinning made
ineffective, as in an app without pins, or wrong pins that fail requests, with a prompt only for
public roots. A document cannot move a set's expiry earlier, and an acceptance never trusts a root.

## Alternatives

- Compiled-in pins only (0001): every CA change needs a release of both apps ahead of it.
- ATS `NSPinnedDomains`: no fail-soft expiry, and a delegate cannot override its rejection (tested
  for 0001).
- Pinning `api.tigerduck.app` as well: broken by Cloudflare's rotation, as above.

## Consequences

- The built-in sets still expire, and `swift/TigerDuckTests/TLSPinningDelegateTests.swift` fails
  45 days before one does; the `tls-pin-rotation` skill has the steps. With the document live, a
  rotation of the built-in table only refreshes the fallback.
- A new signing key ships in the apps before the server switches to it.
- The Android app implements the same rules (`tigerduck-app-android`).
