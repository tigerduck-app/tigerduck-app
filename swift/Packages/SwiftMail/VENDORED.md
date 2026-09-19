# Vendored copy

This package is a patched copy of [Cocoanetics/SwiftMail](https://github.com/Cocoanetics/SwiftMail)
1.11.0 (commit `a2d4a94f844db62843ef6aec16f3ed9462152acc`), vendored directly into this
repo rather than consumed as a remote Swift package dependency. License: BSD-2-Clause
(see `LICENSE`, unmodified).

## TigerDuck changes on top of 1.11.0

1. `MailCertificateVerificationPolicy.custom` — a caller-supplied certificate verifier, which
   **replaces NIOSSL's verification entirely** and owns the whole evaluation, chain and
   hostname included
   (`MailTransportSecurity.swift`, `IMAPConnection+TLS.swift`, `SMTPServer+Connection.swift`).

   This is not pinning layered on top of platform trust, and reading it that way is how a
   client ends up with no validation at all. `NIOSSLCustomVerificationCallback` overrides all
   of BoringSSL's verification, hostname checking included, and on Darwin the
   Security.framework callback NIOSSL installs in `NIOSSLContext.createConnection()` is
   overwritten by `NIOSSLClientHandler.init`. Setting `certificateVerification =
   .fullVerification` with `trustRoots = .default` is *necessary* — NIOSSL skips a custom
   callback altogether when verification is `.none`, so without it the callback never runs —
   but it performs no validation of its own.

   The shipped app is correct only because its verifier does the whole job itself:
   `Services/Mail/Transport/MailTLSVerifier.swift` runs `SecTrustCreateWithCertificates` +
   `SecPolicyCreateSSL(true, host)` + `SecTrustEvaluateWithError` **before** it looks at pins.
   A pin-only verifier written on the assumption that something else still checks the chain and
   the hostname would ship a client that validates neither.
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

6. `MessageInfo.bodyStructureUnusable` — set when the server answers the `BODYSTRUCTURE`
   request with a structure NIOIMAP cannot parse (`IMAP/Models/MessageInfo.swift`,
   `IMAP/IMAP/Handler/FetchMessageInfoHandler.swift`). NIOIMAP deliberately does not fail the
   whole FETCH over a bad body structure — it hands back
   `MessageAttribute.BodyStructure.invalid`, whose own doc comment says the wrapper exists so a
   client can tell valid from invalid `BODYSTRUCTURE` data. `FetchMessageInfoHandler` matched
   only `.valid` and dropped `.invalid` into `default: break`, so that distinction died one layer
   above the parser: `parts` came back empty with no error and no log, identical to a message
   that genuinely has no parts. Without this, a Mail2000 message whose structure the server
   botches renders as nothing at all on iOS — `LiveMailClient.detail` iterates zero parts, every
   body is nil, and the message screen falls back to the source view — while Android, which parses the
   MIME itself instead of trusting the server's description, opens the same message fine.
   `LiveMailClient` reads this flag to decide whether to fetch the message whole and parse it
   locally. Additive: one new `case` in an existing `switch`, one new property with a default,
   decoded with `decodeIfPresent ?? false` so an older encoding still reads back; no upstream
   behaviour changes. `InvalidBodyStructureTests` pins it, driving the real
   `FetchMessageInfoHandler` behind `IMAPClientHandler`.

7. `IMAPCommand` refines `SendableMetatype` (`IMAP/IMAP/Commands/IMAPCommand.swift`). Every
   command is forwarded down to `IMAPConnection`, whose `nonisolated` `async` execution path
   runs on the concurrent executor; a generic conformance that *may* be actor-isolated cannot
   cross into one, so both forwarding sites
   (`IMAPNamedConnection.executeCommand`, `IMAPServer.executeCommand`) drew
   `conformance of 'CommandType' to protocol 'IMAPCommand' may be isolated and cannot be passed
   to @concurrent context` — a warning today, an error in the Swift 6 language mode. Stating the
   requirement once on the protocol is the narrowest fix that works: adding `SendableMetatype` to
   the two generic parameters instead does **not** silence it (verified against Swift 6.4), and
   the only other thing that does is making `IMAPConnection.executeCommand`
   `nonisolated(nonsending)`, which would relocate where every IMAP command body runs. Additive
   and behaviour-neutral: `SendableMetatype` is a marker protocol with no runtime representation,
   and every conformer in the package is already a non-isolated `struct` — `IMAPCommand` is
   internal, so no other module can add an isolated conformance. It does raise the minimum
   compiler to Swift 6.2, which first shipped `SendableMetatype`; TigerDuck builds with Xcode 27
   (Swift 6.4).

8. The explicit `swift-testing` package dependency is dropped from `Package.swift`, along with
   the four `.product(name: "Testing", package: "swift-testing")` entries in the test targets.
   The test targets still `import Testing`; they now get it from the toolchain, which has
   shipped Swift Testing since Xcode 16 (Xcode 27 carries `Testing.framework` in both the
   iPhoneSimulator and MacOSX platform directories). Declaring it as a package instead dragged
   **swift-syntax** into the graph — the macro machinery behind `@Test` and `#expect` — and
   built five modules of it (`SwiftSyntax`, `SwiftSyntax601`, `SwiftSyntax602`,
   `SwiftSyntaxBuilder`, `SwiftSyntaxMacros`, 130 object files) that nothing in the app ever
   links. Measured on a clean `swift build --build-tests`: **63.0 s → 38.0 s wall, 304 s → 171 s
   CPU**. Verified that a `swift-tools-version:5.9` manifest — which this is — resolves the
   toolchain's Testing without the dependency; all three test targets still pass (380/57,
   110/3, 21/4), as does the app suite (714/77).

9. `search(identifierSet:criteria:calendar:)` is **not deprecated** in this fork, on both
   `IMAPServer` (`IMAP/IMAPServer+Search.swift`) and `IMAPNamedConnection`
   (`IMAP/IMAPNamedConnection+Search.swift`). Upstream marks it deprecated in favour of
   `extendedSearch(...)` and `search(..., sortCriteria:)`. Neither replacement is usable here:
   Mail2000's CAPABILITY banner, captured from a real logged-in session, is
   `IMAP4 IMAP4rev1 AUTH=LOGIN LITERAL+ ID NAMESPACE STARTTLS` — no ESEARCH, no SORT, no WITHIN —
   so `sortCriteria:` throws before sending a byte and `extendedSearch` would reach the server
   through a command and response handler never exercised against it, on a path whose callers
   include the §8.3 pre-EXPUNGE ownership check. This variant is also the one **patch 3** teaches
   to send `CHARSET UTF-8`, so moving off it would silently regress search for Chinese queries.
   Keeping the annotation meant one permanent, un-actionable warning in every build; the method
   body is untouched, and a re-vendor that restores the annotation restores only the warning.

`Package.swift` also drops the upstream CLI demo executables and their demo-only
dependencies (`swift-dotenv`, `swift-argument-parser`) — TigerDuck links only the
`SwiftMail` library target.

## Tests TigerDuck added

Both live in the upstream test targets, so `swift test` runs them and a re-vendor that drops
them fails loudly rather than quietly.

- `Tests/SwiftIMAPTests/TigerDuckPatchTests.swift` — the only test pinning **patches 1 and 3**:
  that a `.custom` policy keeps `certificateVerification` at `.fullVerification` (patch 1's
  callback is skipped entirely otherwise), that verifiers compare by identifier, that a
  `.custom` policy builds a client handler, and that `SEARCH`/`UID SEARCH` carry `CHARSET UTF-8`
  exactly when a criterion contains non-ASCII text. Undocumented, this is the file whose loss at
  the next re-vendor would take two patches with it unnoticed.
- `Tests/SwiftIMAPTests/InvalidBodyStructureTests.swift` — pins **patch 6**, driving the real
  `FetchMessageInfoHandler` behind `IMAPClientHandler`.
