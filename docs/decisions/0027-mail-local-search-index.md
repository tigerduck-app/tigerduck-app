# 0027. Search School Mail through an index on the phone

Status: accepted

## Context

School Mail searched with `UID SEARCH` on the school's Mail2000 server, with `CHARSET UTF-8` for a
query in Chinese. The Android app found that the server answers `NO [BADCHARSET]` to any non-ASCII
`SEARCH`, so a search in Chinese found nothing, and every search waited on the server
(https://github.com/tigerduck-app/tigerduck-app/issues/850,
https://github.com/tigerduck-app/tigerduck-app/issues/553). Android now downloads every mail into
a local index and searches that (https://github.com/tigerduck-app/tigerduck-app-android/pull/444).
The mail page shares one IMAP connection, whose `AsyncSerialLock` was strictly first in, first out
(docs/decisions/0015-mail-held-imap-connection.md).

## Decision

- `MailSearchIndex` (`swift/TigerDuck/Mail/Store/MailSearchIndex.swift`) is one SQLite
  file in `MailCache`'s directory, left out of backups. Each row is a mail's UID and its text:
  sender name and address, subject and the first text part (plain before HTML, at most 32,000
  characters), lowercased.
  It records the account it belongs to and each folder's UIDVALIDITY; another account or a new
  UIDVALIDITY empties it. It has the protection class of the other mail caches.
- `MailCache.clearAll()`, which School Mail's sign-out and Clear Cache run, closes and deletes it.
  Every write is refused once `MailCache.wipeCount` has moved since the download began.
- `MailIndexer` (`swift/TigerDuck/Mail/Sync/MailIndexer.swift`) downloads while the mail
  page is on screen and the app is active: Inbox and Sent first, then the other folders. A pass
  first lists every folder's undeleted UIDs and drops the mail the server no longer has, then
  fetches what is missing, newest first, 20 mails per command. A pass that got through holds off
  the next for 15 minutes, unless the list found new mail.
- Through a pass the mail page's status dot spins, and its School Mail row shows the mail fetched
  of the pass's total, such as "120/3,456", or "Syncing…" while the folders are still being
  listed, as the Android app's does.
- A search looks in the index and in the mail the list has loaded, a folder at a time, and stops
  mid-scan once a newer search replaces it. It then fetches the newest 50 matches' summaries from
  the server, which drops mail deleted since. While the index is still filling, it shows what it
  has found, with no note. Offline, it shows the matches among the loaded mail, as the server
  search's fallback did.
- The index's two commands, `undeletedUIDs` and `searchTexts`, take `commandLock` as `yielding`:
  they wait behind every other command, and a batch lets a command that queued meanwhile go
  before each mail's text part, so a mail the user opens waits at most for one fetch
  (https://github.com/tigerduck-app/tigerduck-app/issues/817).
- A pass that fails waits 1, 2, 4, 8 and then 15 minutes before the next try. A batch whose
  answer will not parse is fetched a mail at a time; a mail whose own answer will not parse
  twice is skipped until the account changes or the app quits, so the rest of its folder still
  downloads.
  A lost connection counts against no mail.
- Low Data Mode (`NetworkMonitor.isConstrained`) keeps a pass from starting and stops one after
  its batch in flight; the page's poll starts it again once Low Data Mode is off. Cellular
  without Low Data Mode downloads as Wi-Fi does. Search reads what is indexed either way.
- A file SQLite cannot read, on opening or in a later query, is deleted and the index starts
  over. Sign-out closes and deletes the file under the lock a search opens it with.

## Consequences

- The school's server never sees what the user searches for; `search(folder:query:)` is gone.
- The first download of a large mailbox takes minutes on the mail page, and pauses whenever the
  page goes away or the app leaves the foreground, as the page's poll does.
- A mail's text part over 256 KB, or one that will not decode, is found by sender and subject only.
- `MailSearchIndexTests`, `MailIndexerTests` and `AsyncSerialLockTests` pin the matching, the
  incremental download, UIDVALIDITY and deletion handling, the wipe, the retries and skips, the
  Low Data Mode pause, the progress, the interrupted scan, the unreadable file and the yielding
  order.
