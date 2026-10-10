# 0018. Accept mail warning differences from Android only when they hide no outside link

Status: accepted

## Context

School Mail's warning rules exist on iOS (`MailWarnings` and `MailTextCleaner` in
`swift/TigerDuck/Services/Mail/Rules/`) and on Android (`MailWarnings` in `mail/warning/` and
`TextCleaning` in `mail/mime/`, under `app/src/main/java/org/ntust/app/tigerduck/` in
`tigerduck-app/tigerduck-app-android`). The shared `warnings.json` fixture, in
`swift/TigerDuckTests/SchoolMail/Fixtures/` and in Android's `app/src/test/resources/mail/`, keeps
the two agreeing. Most iOS patterns and steps name the Android constant or function they mirror,
and where ICU and Java regular expressions disagree the iOS patterns spell the Java behavior out.
Some differences come from the platform libraries: Foundation's whitespace set against Kotlin's,
and `URLComponents` against `java.net.IDN`.

## Decision

A difference from Android is accepted only when it never widens what counts as a school link: it
never hides an outside link or suppresses a real mismatch. Where iOS is stricter, Android has the
gap to close; iOS never matches it by weakening. Accepted in `MailWarnings` link handling:

- The trim after `sanitizeHref`, `.trimmingCharacters(in: .whitespacesAndNewlines)`, removes more
  Unicode whitespace than WHATWG's trim of C0 controls and space, which `sanitizeHref`'s leading
  trim matches. At the end of an href it keeps the C0 controls outside U+0009 to U+000D; one left
  after a host fails `plainHttpLinkPattern` and stays in the host, so it only adds warnings.
- `toASCII` follows UTS46 through `URLComponents`, and `java.net.IDN` the older IDNA2003 tables,
  which disagree on a few characters such as German sharp s and Greek final sigma.
- A scheme with a combining mark inside its letters, such as `http\u{0307}s://`, is not `http` or
  `https` under WHATWG either, so `schemePattern` not matching it and `hostOf` falling through is
  the outcome a browser reaches.

Where iOS is stricter, each site keeps a note:

- `MailTextCleaner.visibleText` removes all `Cf`, `Cc` and `Default_Ignorable_Code_Point`
  characters; Android's `MailWarnings.INVISIBLE` covers only `Cf`, `Cc` and U+200B.
- `MailWarnings.scannedFilename` removes invisible characters before the extension checks; Android's
  `MailWarnings.cleanFileName` keeps format characters other than bidi controls, so
  `payload.ex<U+200B>e` is still open there.
- `MailTextCleaner.clean` trims with Foundation's set, which also removes U+0085 and U+200B that
  Kotlin's `trim()` in Android's `TextCleaning.clean` keeps; trimming more can only expose an
  extension or a host to the checks.

## Consequences

- A new difference needs the same argument before it is accepted.
- The Android gaps stay open until the Android app closes them.
