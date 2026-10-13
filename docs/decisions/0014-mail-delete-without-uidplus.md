# 0014. Move and delete School Mail without UIDPLUS

Status: accepted

## Context

Mail2000 has no MOVE and no UIDPLUS, so no UID EXPUNGE: its only EXPUNGE removes every `\Deleted`
message in the selected folder, another client's included. A move is therefore a sequence of
separate client calls (STATUS, COPY, STORE `\Deleted`, a fresh deleted-UID search, EXPUNGE), and
the mail page's 60 s poll, which shares the client, can run between any two of them. A folder
recreated on the server gets a new UIDVALIDITY, and a UID recorded under the old value may then
name a different message.

## Decision

- `MailMover` (`swift/TigerDuck/Services/Mail/Transport/MailMover.swift`) expunges only when every
  `\Deleted` message in the folder is one TigerDuck flagged (`shouldExpunge`), going by a fresh
  server-side search right before EXPUNGE, never by cached flags. Otherwise its flags wait, hidden
  from the list, and the caller persists `MailMoveResult.stillPending` for a later safe EXPUNGE.
- Owned UIDs travel as `OwnedDeleted`, one value binding folder, UIDVALIDITY and UIDs, so a set
  recorded under one folder or generation cannot pass a check made against another.
- `move` and `deletePermanently` first confirm that the folder and the UIDVALIDITY
  `previouslyFlagged` was recorded under still match; if not, they throw `.folderChanged` before
  COPY or STORE, and the message screen has the list reload that folder
  (`MailListViewModel.recoverFromFolderChange(_:)`) instead of retrying. An empty `uids` sends no
  command.
- That check is not the guard. Every step that can change or destroy mail carries
  `previouslyFlagged.uidValidity`, and `LiveMailClient` compares it with that command's own SELECT
  or EXAMINE response, never with a value an earlier command read.
- A failed step is not retried, since it may have started on the server
  (docs/decisions/0015-mail-held-imap-connection.md). `recoverAfterFailure` then asks the server
  once whether the `\Deleted` flag took, since a flag TigerDuck set but does not claim keeps
  `shouldExpunge` false in that folder for good: later deletes there only hide, and Trash deletes
  nothing. It claims the UID only when the server confirms the flag and the cached copy was not
  already `\Deleted`, and skips the probe after an authentication, certificate or `.folderChanged`
  failure.

## Alternatives

- A UIDVALIDITY the client caches between commands: the 60 s poll's `status(INBOX)` can store a
  recreated folder's new value mid-move, and the guard then compares that value with itself.
- Folder and UIDVALIDITY as separate parameters: a stale owned set paired with a fresh, matching
  UIDVALIDITY could sweep another client's `\Deleted` mail into an EXPUNGE.

## Consequences

- Another client can still act between the deleted-UID check and EXPUNGE, the narrowest window
  without UIDPLUS. While another client's `\Deleted` mail is in a folder, deletes there only hide.
- `swift/TigerDuckTests/SchoolMail/MailMoverTests.swift` pins each rule, including a poll mid-move.
