# Vendored copy

This package is a patched copy of [Cocoanetics/SwiftMail](https://github.com/Cocoanetics/SwiftMail)
1.11.0 (commit `a2d4a94f844db62843ef6aec16f3ed9462152acc`), vendored directly into this
repo rather than consumed as a remote Swift package dependency. License: BSD-2-Clause
(see `LICENSE`, unmodified).

## TigerDuck changes on top of 1.11.0

1. `MailCertificateVerificationPolicy.custom` — a caller-supplied certificate verifier,
   so the app can add SPKI pinning on top of NIOSSL's default trust evaluation
   (`MailTransportSecurity.swift`, `IMAPConnection+TLS.swift`, `SMTPServer+Connection.swift`).
2. `MailCharsetResolver` — an overridable charset-label → `String.Encoding` hook for
   RFC 2047 header decoding *and* message body decoding, so the app's Appendix A.5
   rules (Big5-as-HKSCS, GBK-as-GB18030, …) apply to sender names, subjects, and
   `textBody`/`htmlBody` alike (`Core/MailCharsetResolver.swift`,
   `Extensions/String+QuotedPrintable+MIMEHeader.swift`, `IMAP/Models/MessagePart.swift`'s
   `textContent`).
3. `CHARSET UTF-8` on `SEARCH`/`UID SEARCH` when any criterion contains non-ASCII text —
   applied to both the deprecated `SearchCommand` and the `ExtendedSearchCommand` used by
   `extendedSearch(...)`/`search(..., sortCriteria:)`'s non-sort (SEARCH/UID SEARCH) branch
   (`IMAP/Models/SearchCriteria.swift`, `IMAP/IMAP/Commands/SearchCommand.swift`,
   `IMAP/IMAP/Commands/ExtendedSearchCommand.swift`).

`Package.swift` also drops the upstream CLI demo executables and their demo-only
dependencies (`swift-dotenv`, `swift-argument-parser`) — TigerDuck links only the
`SwiftMail` library target.
