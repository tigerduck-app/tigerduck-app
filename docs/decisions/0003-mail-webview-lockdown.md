# 0003. Render mail HTML in a locked-down web view

Status: accepted

## Context

School Mail shows HTML written by anyone who can send to a student: it can carry scripts,
tracking images, remote content and links whose text hides their target.

## Decision

`swift/TigerDuck/Features/SchoolMail/Components/MailWebViewFactory.swift` builds the
`WKWebView` that renders a message:

- JavaScript is off, the website data store is non-persistent and data detectors are off.
- A content rule list blocks every network load. Inline `cid:` images load from the `tdcid:`
  scheme through `MailCIDSchemeHandler`, `data:` URLs are allowed, and remote images load only
  after the reader asks for them.
- The page's Content Security Policy is a second layer (`default-src 'none'`, images only from
  the same sources), so remote loads stay blocked if the rule list fails to compile.
- `MailHTMLSanitizer.rewriteLinks` replaces each link with `https://link.invalid/<index>`, and
  the view resolves only that exact form, failing closed on anything else.
- HTML mail that sets a text or background color of its own opens on white paper, other mail
  on the app's page, and the reader can switch. The sender's colors are kept, except a text
  color under 4.5:1 against its background on the page shown, which moves to the nearest OKLCH
  lightness that reaches it (`MailReadableHTML`). Only color values the sanitizer kept change.

## Consequences

- Remote images and links never load without a tap.
- Any new kind of resource the view must load needs both a content rule and a CSP source.
