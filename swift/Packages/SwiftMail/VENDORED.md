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
4. `closeAllConnections()` also clears the stored `authentication` — without this, `logout()`
   and `disconnect()` left it set, so the next command any caller issued on the same
   `IMAPServer` (e.g. a fetch loop still in flight when the caller closed the session) routed
   through `ensurePrimaryConnectionAuthenticated()`, which silently reconnected and logged back
   in with the stored credentials instead of failing as no-longer-authenticated
   (`IMAP/IMAPServer+Connection.swift`).

   This change invalidates an upstream test: `IMAPPlaintextIntegrationTests`'
   `reconnectsBeforeResolvingExamineMailboxPath` asserted exactly the silent re-login it
   removes, and so could not pass here. It is kept, renamed
   `resolvesExamineMailboxPathAndDoesNotSilentlyReLogInAfterDisconnect`, asserting the
   namespace-prefix resolution it was really about *before* the disconnect, and the new
   contract — a command after `disconnect()` fails — after it.

5. `FetchMessageInfoRequest.wireCommand(options:headerFields:uid:tag:)` — renders the `UID FETCH`
   command `fetchMessageInfo(for:options:headerFields:)` encodes for a given set of arguments
   (`IMAP/IMAP/Commands/FetchMessageInfoRequest.swift`, new file). A caller picks options and
   header-field names; the `BODY.PEEK[...]` section specifier they turn into is otherwise
   invisible to it, and that section's shape decides whether a non-conforming server's *response*
   can be parsed at all — `headerFields:` sends the field name quoted, and Mail2000 echoes the
   section back with quoting of its own added, producing `BODY[HEADER.FIELDS (""NAME"")]`, which
   no IMAP parser can read. TigerDuck pins the request shape its message screen sends against
   this. Additive: no upstream file is modified and no upstream behaviour changes.

`Package.swift` also drops the upstream CLI demo executables and their demo-only
dependencies (`swift-dotenv`, `swift-argument-parser`) — TigerDuck links only the
`SwiftMail` library target.
