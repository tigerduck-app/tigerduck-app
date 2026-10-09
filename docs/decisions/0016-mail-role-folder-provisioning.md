# 0016. Create missing School Mail role folders on demand

Status: accepted

## Context

A Mail2000 account need not have Sent, Drafts or Trash: one can be missing from the start, and the
user can delete any of them in webmail. Without them a draft cannot be saved, a sent mail keeps no
copy, and Delete can only destroy mail instead of moving it to Trash. `MailFolderMap.resolve` finds
roles by name, never by an RFC 6154 SPECIAL-USE attribute: Mail2000 sends none, and on other servers
a long-lived mailbox collects `Sent`, `Sent Items` and `Sent Messages` from the clients that touched
it, so picking one to file into is a guess.

## Decision

`MailFolderProvisioner.ensure` (`swift/TigerDuck/Services/Mail/Core/MailFolderProvisioner.swift`)
creates a missing role folder when an operation needs it and re-resolves roles from a fresh `LIST`.

- Only `.sent`, `.drafts` and `.trash` are created: `.junk` is where the server's spam classifier
  files mail, and a folder it does not know may confuse it; RFC 3501 reserves `INBOX` for the
  user's primary mailbox (§5.1) and makes creating it an error (§6.3.3).
- Nothing is created speculatively (at sign-in, on a folder refresh, while resolving roles), as a
  new folder is a visible change to the account. Sent is created only after the mail has gone out,
  and Trash when the user asks to delete, before the confirmation, so the dialog says truthfully
  whether the mail moves to Trash or is destroyed.
- The fresh `LIST` decides, not the `CREATE` reply: Mail2000 has no RFC 5530 `[ALREADYEXISTS]`, and
  two operations or another client can race to one folder. The map a caller holds cannot see the new
  folder, so callers adopt the returned map wholesale instead of patching their own.
- `ensure` never throws; it returns nil when the role is not creatable or the fresh `LIST` fails or
  lacks it. Saving a draft then throws `MailFolderUnavailable`; filing a sent copy and deleting fall
  back, so a failed `CREATE` never fails a send.
- `MailClient.createFolder` gets the raw modified UTF-7 `MailFolderRole.imapName`, the spelling
  `listFolders()` reports, and nothing below re-encodes it: SwiftMail's `IMAPServer.createMailbox`
  only adds an advertised personal namespace prefix (`resolveMailboxPath`) before
  `MailboxName(ByteBuffer(string:))` sends the raw bytes. The re-resolve proves the round trip: a
  mangled or double-encoded name does not resolve back, so `ensure` reports failure instead of a
  folder the next operation would create again.
- The same names are created on any server, the DEBUG override's included: TigerDuck owns one
  unambiguous set, spelled the same everywhere, and files only into it.

## Consequences

- Mail TigerDuck files lands in its own Sent, which another client's Sent does not show.
- `swift/TigerDuckTests/SchoolMail/MailFolderProvisionerTests.swift` pins the round trip, the wire
  form of the name and the roles that are never created.
