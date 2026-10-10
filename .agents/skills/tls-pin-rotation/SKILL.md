---
name: tls-pin-rotation
description: Use when TigerDuck's TLS pins need rotating or checking, when a pin set nears its expiration date, or when an NTUST certificate chain changes. Generates SPKI SHA-256 pins and updates TLSPinningDelegate together with the Android app.
---

# TLS pin rotation

The pin table is `pinSets` in `swift/Shared/TLSPinningDelegate.swift`; the reasoning is in
`docs/decisions/0001-tls-pinning.md`. School Mail's `MailTLSVerifier` reads the same table.

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

   The pipeline above hashes the first certificate only. Pin the leaf and the intermediate:
   split the `-showcerts` output into one PEM file per certificate and run the last four
   commands on each.
2. Set the host's `pins` to those values and move the shared `expiration` date forward.
3. Make the same change in `tigerduck-app-android`'s
   `app/src/main/res/xml/network_security_config.xml`; both apps must ship the same pin set and
   expiration.
4. Ship both builds before the old expiration date. After it, unrotated builds fall back to
   system trust and log the expiry at `.fault` (`TLSPinningDelegate` and `MailTLSVerifier`).
