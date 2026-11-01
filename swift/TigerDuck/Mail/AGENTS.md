# School Mail

Rules for `swift/TigerDuck/Mail/`: the School Mail client, its IMAP and SMTP transport, cache,
search index and background checks. The screens are in `Features/SchoolMail/`.

- The phone talks to the school's mail server directly, never through the TigerDuck backend, and
  the mail password stays on the device (`Store/MailCredentialStore.swift`).
