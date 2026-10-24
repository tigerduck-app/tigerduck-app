---
name: tls-pin-rotation
description: Use when TigerDuck's TLS pins need rotating or checking, when a built-in pin set nears its expiration date, when an NTUST certificate chain changes, or when the pin-signing key rotates. Generates SPKI SHA-256 pins and updates the built-in table in TLSPinTable together with the Android app.
---

# TLS pin rotation

Pins come from two places; the reasoning is in `docs/decisions/0025-remote-tls-pins.md`.

- The signed document at `https://api.tigerduck.app/.well-known/tigerduck/tls-pins.json`. The
  backend's pin watcher adds a new CA's pins and republishes on its own; the portal adds and
  removes pins and extends a set's expiry (tigerduck-backend). This is the normal path for a CA
  change, and no app release is needed.
- The built-in table, `builtIn` in `swift/Shared/TLSPins/TLSPinTable.swift`: the fallback for a
  build that has no valid document. `swift/TigerDuckTests/TLSPinningDelegateTests.swift` fails 45
  days before any built-in set expires.

Pins are CA-only: intermediates and roots, never a leaf.

1. For each pinned host (`ntust.edu.tw` and its subdomains, `api.lib.ntust.edu.tw`), print the
   SPKI SHA-256 of every certificate in the chain the server sends:

   ```bash
   HOST=moodle2.ntust.edu.tw
   echo | openssl s_client -servername "${HOST}" -connect "${HOST}:443" -showcerts \
     | openssl x509 -noout -pubkey \
     | openssl pkey -pubin -outform der \
     | openssl dgst -sha256 -binary \
     | openssl enc -base64
   ```

   The pipeline above hashes the first certificate only. Split the `-showcerts` output into one
   PEM file per certificate and run the last four commands on each but the leaf, and read each
   leaf's `notAfter` with `openssl x509 -noout -enddate`. Check several subdomains,
   `mail.ntust.edu.tw:993` and `:465` among them: `cardsystem.ntust.edu.tw` shows TWCA SSL CA and
   TWCA CYBER Root CA, which the other hosts do not serve.
2. Compare with the live document: decode its `payload` (base64url) and read `serial` and
   `pin_sets`. If the watcher has not added a CA the hosts serve, add it in the portal first.
3. To change the built-in table, publish the same pins from the portal, then set each set's
   `pins` to them, keeping any CA a renewal may still come from, and set `baselineSerial` to that
   document's serial so an older document cannot replace the new table. Set each `expiresAt` to
   six months after the latest `notAfter` among the leaves the set's hosts serve. Keep the
   library set's Sectigo roots, E46 and R46: its renewals change the issuer, and Sectigo issues
   only under these two.
4. Update the tests that hold certificate data: `appPins` in
   `swift/TigerDuckTests/SchoolMail/MailTLSVerifierTests.swift`, and `servedChains` in
   `TLSPinningDelegateTests`. Each set needs chains its hosts served, with a date inside their
   validity, whose CAs cover every pin in the set. Add a chain as base64 DER, one certificate each
   (`openssl x509 -outform der | openssl enc -base64 -A`). A root no host serves yet, such as
   Sectigo R46, goes in `renewalRoots` instead.
5. Make the same change in `tigerduck-app-android`'s built-in table and `PIN_EXPIRY_EPOCH`, the
   earliest expiration in epoch milliseconds. Both apps must ship the same sets, expirations and
   `baselineSerial`.
6. Ship both builds before the old expiration date. After it, a build with no valid document falls
   back to system trust and logs the expiry at `.fault` (`TLSPinEngine`, `TLSPinningDelegate`).

## Rotating the signing key

`signingKeys` in `TLSPinTable.swift` holds the server's key and an offline standby, as raw 32-byte
Ed25519 public keys in base64. Ship both apps with the new public key first, then switch the
server to it; a document signed with a `key_id` a build does not know is no document to it.
