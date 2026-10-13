# 0013. Detect mail bounces from Return-Path, and only on the opened message

Status: accepted

## Context

A Mail2000 delivery failure arrives as `From: "Mail Deliver System" <MAILER-DAEMON>`, a bare local
part with no domain. Treating every sender without a domain as outside called the school's own mail
system an outside sender, which is wrong on its face and teaches people to ignore the warning. The
display name cannot mark a bounce, because any sender can type it.

Under RFC 5321 §4.5.5 a delivery status notification is sent with the null reverse-path, which the
final delivery server records as `Return-Path: <>` (§4.4). The school's own server writes that
header, not the sender, so it is the only bounce marker worth trusting, though not proof of origin:
anyone may send `MAIL FROM:<>`.

## Decision

- `MailWarnings.isBounce(returnPath:)` in `swift/TigerDuck/Services/Mail/Rules/MailWarnings.swift`
  treats `Return-Path: <>` as a bounce. `LiveMailClient.returnPath(from:)` reads the first
  `Return-Path`, the one the final delivery server prepends, not a copy the sender wrote lower down.
- `MailWarnings.evaluate` exempts a bounce from `external` only when the sender has no domain at
  all, so a bounce whose `From` names an outside domain stays external. The same marker gates
  `MailWarning.mistypedRecipient`.
- The opened message reads the header at no cost: `LiveMailClient.detailOptions` already fetches the
  whole header section (`BODY.PEEK[HEADER]`), and the value rides in the cached
  `MailMessageDetail.returnPath` into `MailWarningInput.returnPath`.
- The folder list does not read it. Its fetch, `LiveMailClient.summaryOptions`, takes ENVELOPE but
  no header section, and ENVELOPE has no `Return-Path`. Asking for that one field,
  `BODY.PEEK[HEADER.FIELDS (...)]`, is the request Mail2000 echoes back with the field name
  double-quoted, which NIOIMAP cannot decode (see `LiveMailClient.detailOptions`), and a full
  header for all 50 rows of every page is a real download for a badge that is already right:
  `LiveMailClient.summary(from:)` keeps no address for a sender without a domain, so
  `MailSummary.isExternal` is false. The list decides on that weaker signal.

## Consequences

- The list and the opened message agree on a real Mail2000 bounce. A forged bounce whose `From`
  names an outside domain is external in both, since the exemption needs a missing domain.
- The exemption stays safe. `external` feeds the external-sender banner and the password-bait gate,
  which fires on `keywordHit && (external || linksOutside)`, so a forged bounce with a phishing link
  to a non-school host is still caught through the link. What is left is a forged, link-free bounce,
  which has nothing to click.
- Without the header (a body cached before `returnPath` existed, or a detail fetch that fell back to
  the summary attributes) a sender with no domain stays external.
  `swift/TigerDuckTests/SchoolMail/MailWarningsTests.swift` pins these rules.
