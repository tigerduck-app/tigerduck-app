# 0015. Hold one IMAP connection and run its commands one at a time, to completion

Status: accepted

## Context

School Mail talks IMAP to the school's Mail2000 server directly from the phone, and one
`LiveMailClient` serves both the mail page's 60 s poll and the message screen. A multi-step
operation such as `MailMover.move` depends on which folder each of its commands selects. Actor
isolation excludes only synchronous execution, so at an `await` a second call's SELECT can land
between a first call's SELECT and the STORE, COPY or EXPUNGE it guards: `expunge(Trash)` selects
Trash, an interleaved `setFlag(.seen, INBOX)` selects INBOX read-write, and EXPUNGE then removes
INBOX's `\Deleted` mail, another client's included
(docs/decisions/0014-mail-delete-without-uidplus.md). The SwiftMail calls `LiveMailClient` makes
ignore cancellation.

## Decision

- `LiveMailClient` (`swift/TigerDuck/Services/Mail/Transport/LiveMailClient.swift`) holds one IMAP
  connection for its lifetime; SMTP connects per send, and both verify TLS through
  `MailTLSVerifier` (docs/decisions/0001-tls-pinning.md). Host, port and transport come from
  `MailServerConfig` once, at `init`, so no configuration change moves a live connection; the
  DEBUG server override takes effect through a sign-out and a new client
  (docs/decisions/0007-dev-mail-server-override.md).
- Every `run` call holds `commandLock`, a private FIFO `AsyncSerialLock`, across the liveness probe,
  any reconnect and the command. It calls `acquire()` and `release()` rather than `withLock`, so the
  body keeps the actor's isolation to read `imap`, `credentials` and `connectionGeneration`.
- The probe is a NOOP, never a STATUS that reselects a folder. A dead connection gets one reconnect
  and login; then the command runs once and to completion, even for a cancelled caller. A command
  that may have started (COPY, STORE, APPEND, EXPUNGE, a streaming download) is never retried and
  never abandoned: stopping `MailMover.move` between COPY and STORE, or between STORE and the
  ownership check that guards EXPUNGE, is worse than letting it finish.
- A network or certificate failure closes the socket so the next call reconnects; any other failure
  leaves it open. In a reconnect only an authentication rejection clears the credentials, and a
  login that did not complete always closes the socket, so the next NOOP probe cannot take it for a
  live session.
- `logout()` never waits on `commandLock`, though LOGOUT and the disconnect still queue behind the
  command in flight on SwiftMail's per-connection `commandQueue`. It bumps `connectionGeneration`
  and clears `credentials` before its first `await`, so a probe or reconnect that finishes later
  closes its connection instead of handing it to the command.
- `LiveMailClient` does not decide how long the connection stays open: `MailPageSession` closes
  the mail page's connection about 30 s after the page goes away, and `MailChecker` logs out a
  client it opened for a check.

## Consequences

- Commands wait in FIFO order behind a long one, such as a download.
- `AsyncSerialLockTests` pins exclusion, FIFO order and release after a throw; `FakeMailClient`'s
  `hold`, `waitForArrival` and `release` replay interleavings such as a poll between mover steps.
