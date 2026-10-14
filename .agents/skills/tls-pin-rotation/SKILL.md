---
name: tls-pin-rotation
description: Use when TigerDuck's TLS pins need rotating or checking, when a pin set nears its expiration date, or when an NTUST certificate chain changes. Generates SPKI SHA-256 pins and updates TLSPinningDelegate together with the Android app.
---

# TLS pin rotation

The pin table is `pinSets` in `swift/Shared/TLSPinningDelegate.swift`; the reasoning is in
`docs/decisions/0001-tls-pinning.md`. School Mail's `MailTLSVerifier` reads the same table.
`swift/TigerDuckTests/TLSPinningDelegateTests.swift` fails 45 days before any pin set expires.

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
   commands on each, and read each leaf's `notAfter` with `openssl x509 -noout -enddate`.
   Check several subdomains, `mail.ntust.edu.tw:993` and `:465` among them. A subdomain with a
   certificate of its own can show the intermediate the next renewal comes from:
   `cardsystem.ntust.edu.tw`'s is why the `ntust.edu.tw` set also pins TWCA SSL Certification
   Authority.
2. Set each set's `pins` to those values, keeping any intermediate a renewal may still come
   from, and its `expiration` to six months after the `notAfter` of the leaf it pins. Keep the
   `api.lib.ntust.edu.tw` set's Sectigo roots, E46 and R46: its renewals change the issuer, and
   Sectigo issues only under these two.
3. Update the tests that hold certificate data: `appPins` in
   `swift/TigerDuckTests/SchoolMail/MailTLSVerifierTests.swift`, and `servedChains` in
   `TLSPinningDelegateTests`. Each set needs a chain one of its hosts served, with a date inside
   the chain's validity, that holds a certificate for every pin in the set. Add a chain as
   base64 DER, one certificate each (`openssl x509 -outform der | openssl enc -base64 -A`).
   A root no host serves yet, such as Sectigo R46, goes in `renewalRoots` instead.
4. Make the same change in `tigerduck-app-android`: the pin sets in both
   `app/src/main/res/xml/network_security_config.xml` and
   `app/src/debug/res/xml/network_security_config.xml`, and `PIN_EXPIRY_EPOCH` in
   `app/build.gradle.kts`, the earliest expiration in epoch milliseconds.
   `NetworkSecurityConfigTest` there checks all three. Both apps must ship the same pin sets
   and expirations.
5. Ship both builds before the old expiration date. After it, unrotated builds fall back to
   system trust and log the expiry at `.fault` (`TLSPinningDelegate` and `MailTLSVerifier`).
