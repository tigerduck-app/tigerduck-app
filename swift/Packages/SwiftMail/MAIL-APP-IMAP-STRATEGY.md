# Mail.app IMAP Connection + IDLE Strategy (Gmail vs mail.drobnik.com)

## Purpose
This document captures observed Mail.app behavior from real protocol logs, with concrete timings and transcript excerpts, so SwiftMail can replicate proven patterns.

## Data Sources

- Gmail IMAP log (port 993):
  - `/Users/oliver/Library/Containers/com.apple.mail/Data/Library/Logs/Mail/imap.gmail.com-0B0C5F6C-D6FE-4D55-A41F-E62385675829.txt`
- mail.drobnik.com IMAP log (port 993):
  - `/Users/oliver/Library/Containers/com.apple.mail/Data/Library/Logs/Mail/mail.drobnik.com-96933E76-C4A2-4C8F-85BB-3D348EF77914.txt`
- Not included in this analysis:
  - `mail.drobnik.com-7385EE75-...txt` (SMTP log on port 587, not IMAP)

All counts are from the current log snapshot at analysis time. Logs are actively appended by Mail.app, so numbers can drift slightly.

---

## Executive Summary

- Both providers: Mail.app uses **IDLE as primary near-real-time mechanism**, with explicit `DONE` exits and immediate follow-up sync work.
- Gmail profile: mostly `IDLE` on `[Gmail]/All Mail`, no IMAP `NOOP`, no `CHECK`, no `ENABLE QRESYNC`.
- drobnik profile: always `ENABLE QRESYNC`, IDLE mostly on `INBOX`, uses `CHECK`, and occasional IMAP `NOOP` (mostly right after `DONE`).
- In both logs: no `* BYE` from server side was observed; reconnect is client-driven.

---

## 1. Gmail Strategy

### 1.1 Connection and Authentication Pattern

Observed startup command pattern is very stable:

1. `CAPABILITY`
2. `ID`
3. `AUTHENTICATE OAUTHBEARER`
4. `CAPABILITY`

Protocol excerpt (startup):

```text
[imap.gmail.com:1-37]
1   INITIATING CONNECTION ... host:imap.gmail.com -- port:993
3   CONNECTED ... [TLSv1_2]
6   * OK Gimap ready for requests ...
9   1.854 CAPABILITY
16  2.854 ID ("name" "Mac OS X Mail" ...)
23  5.854 AUTHENTICATE OAUTHBEARER ...
26  * CAPABILITY ... UIDPLUS ... CONDSTORE ...
30  6.854 CAPABILITY
37  7.854 LOGOUT
```

### 1.2 IDLE Strategy and Timing

Raw counters:

- `INITIATING CONNECTION`: 6781
- `CONNECTED`: 5456
- `IDLE`: 2895
- `DONE`: 2284
- `+ idling`: 2895
- `OK IDLE terminated`: 2224
- `NOOP`: 0
- `CHECK`: 0
- `ENABLE QRESYNC`: 0
- `SELECT ... (CONDSTORE)`: 6601
- `CHANGEDSINCE`: 2734
- `STATUS ... HIGHESTMODSEQ`: 15622
- `LOGOUT`: 4792
- `* BYE`: 0

Computed IDLE cycle stats (`+ idling -> DONE -> OK IDLE terminated`):

- Complete cycles: 2223
- With mailbox-change events during IDLE (`EXISTS/EXPUNGE/FETCH`): 100
- Without events: 2123
- Duration (seconds):
  - min 0.0
  - p50 159.101
  - p90 299.092
  - p95 300.300
  - max 894.394
  - mean 157.918
- Buckets:
  - `<5s`: 757
  - `5-60s`: 138
  - `1-3m`: 244
  - `3-4m`: 80
  - `4-5.5m`: 977
  - `5.5-15m`: 27

Interpretation:

- Strong periodic refresh near 5 minutes.
- Frequent short cycles (`<5s`) happen when Mail exits IDLE immediately to run work.

### 1.3 What Mail Does After IDLE Ends

Most common first command after IDLE completion:

- `UNSELECT` 1327
- `UID` 383
- `SELECT` 115
- `FETCH` 100
- `CLOSE` 88
- `LIST` 86

Event-driven exits (mailbox change seen in IDLE):

- `FETCH` 98
- `UID` 1
- `UNSELECT` 1

Timeout/maintenance exits:

- overwhelmingly `UNSELECT -> SELECT -> UID/STATUS/...`

Protocol excerpt (periodic timeout branch):

```text
[imap.gmail.com:182-234]
182 DONE
196 90.835 OK IDLE terminated (Success)
199 91.835 UNSELECT
219 92.835 SELECT "[Gmail]/All Mail" (CONDSTORE)
234 93.835 UID FETCH 1:35436 ... (CHANGEDSINCE 1433050)
```

Protocol excerpt (event branch):

```text
[imap.gmail.com:349358-349398]
349358 168.2875 IDLE
349361 + idling
349364 * 877 EXISTS
349367 DONE
349370 168.2875 OK IDLE terminated (Success)
349373 169.2875 FETCH 877 (...)
349398 170.2875 IDLE
```

### 1.4 Reconnect and Rotation Behavior

Connect timing:

- paired `INITIATING CONNECTION -> CONNECTED` latency:
  - min 0.090s, p50 0.153s, p90 0.332s, p95 1.987s, max 19.769s, mean 0.440s
- paired connections: 5456
- unpaired `INITIATING CONNECTION` attempts: 1325

Long-IDLE session rotation (sessions with IDLE lifetime >= 30m):

- delay from session end to next `INITIATING CONNECTION`:
  - min 0.0s, p50 1.067s, p90 322.797s, p95 642.228s, max 1353.346s, mean 112.057s

Auth-failure handling example (immediate recovery):

```text
[imap.gmail.com:3116-3172]
3116 5.875 NO [AUTHENTICATIONFAILED] Invalid credentials
3128 6.875 BAD Invalid SASL argument
3159 7.875 NO [AUTHENTICATIONFAILED] Invalid credentials
3162 10.875 LOGOUT
3167 INITIATING CONNECTION ...
3169 CONNECTED ...
3172 * OK Gimap ready for requests ...
```

Graceful close + immediate reopen example:

```text
[imap.gmail.com:57473-57504]
57474 183.2926 CLOSE
57480 184.2926 LOGOUT
57496 INITIATING CONNECTION ...
57498 CONNECTED ...
57504 1.2970 CAPABILITY
```

Server-side disconnects:

- `* BYE`: 0 observed.
- In this sample, reconnect is initiated by Mail.app, not by explicit server BYE.

---

## 2. mail.drobnik.com Strategy

## 2.1 Connection and Authentication Pattern

Primary startup pattern:

1. `CAPABILITY`
2. `ID`
3. `AUTHENTICATE PLAIN`
4. `ENABLE QRESYNC`

Protocol excerpt (Zimbra backend):

```text
[mail.drobnik.com:1-36]
1   INITIATING CONNECTION ... host:mail.drobnik.com -- port:993
3   CONNECTED ... [TLSv1_2]
6   * OK zimbra.vm.drobnik.com Zimbra IMAP4rev1 server ready
9   1.853 CAPABILITY
16  2.853 ID (...)
23  3.853 AUTHENTICATE PLAIN (... hidden ...)
29  4.853 ENABLE QRESYNC
32  * ENABLED QRESYNC
36  5.853 LOGOUT
```

### 2.2 Backends Observed Behind mail.drobnik.com

Both server signatures appear in the same log:

- Zimbra greeting count: 3872
- Dovecot greeting count: 1471

Dovecot example:

```text
[mail.drobnik.com:45521096-45521117]
45521097 * OK [CAPABILITY ...] Dovecot (Ubuntu) ready.
45521100 1.3383 ID (...)
45521107 2.3383 AUTHENTICATE PLAIN
45521113 3.3383 ENABLE QRESYNC
45521116 * ENABLED QRESYNC
```

### 2.3 IDLE Strategy and Timing

Raw counters:

- `INITIATING CONNECTION`: 6837
- `CONNECTED`: 5342
- `IDLE`: 5489
- `DONE`: 4776
- `+ idling`: 5489
- `OK Idle completed`: 4766
- `NOOP`: 40
- `CHECK`: 154
- `ENABLE QRESYNC`: 5342
- `SELECT ... (CONDSTORE)`: 5295
- `CHANGEDSINCE`: 3731
- `QRESYNC` appearances: 19900
- `STATUS ... HIGHESTMODSEQ`: 14210
- `LOGOUT`: 4126
- `* BYE`: 0
- `* OK Still here`: 2855

Computed IDLE cycle stats (`+ idling -> DONE -> OK Idle completed/IDLE completed`):

- Complete cycles: 4725
- With mailbox-change events in IDLE: 261
- Without events: 4464
- Duration (seconds):
  - min 0.0
  - p50 93.451
  - p90 299.873
  - p95 301.463
  - max 1813.538
  - mean 151.673
- Buckets:
  - `<5s`: 1810
  - `5-60s`: 381
  - `1-3m`: 471
  - `3-4m`: 156
  - `4-5.5m`: 1823
  - `5.5-15m`: 43
  - `>=15m`: 41

Interpretation:

- Also shows near-5-minute cadence, but with more very short cycles and more sub-3-minute exits than Gmail.
- Server emits frequent untagged keepalive lines while idling (`* OK Still here`).

Keepalive excerpt:

```text
[mail.drobnik.com:45959990-45959994]
* OK Still here
* OK Still here
```

### 2.4 What Mail Does After IDLE Ends

Most common first command after IDLE completion:

- `UNSELECT` 2357
- `UID` 761
- `SELECT` 648
- `LIST` 340
- `FETCH` 201
- `EXPUNGE` 193
- `CHECK` 149
- `NOOP` 22

Event-driven exits:

- `FETCH` 198 (dominant)
- `UNSELECT` 29
- `UID` 27

Early in the log, Mail often does `CHECK` + large `STATUS` sweeps after IDLE completion:

```text
[mail.drobnik.com:45-69]
45  134.821 OK IDLE completed
48  135.821 CHECK
57  135.821 OK CHECK completed
60  136.821 STATUS Cocoanetics (... HIGHESTMODSEQ)
63  137.821 STATUS Archive (... HIGHESTMODSEQ)
66  138.821 STATUS Notes/Haus (... HIGHESTMODSEQ)
69  139.821 STATUS Notes (... HIGHESTMODSEQ)
```

### 2.5 When NOOP Is Used

NOOP is occasional and contextual (not the primary sync mechanism):

- Total NOOP: 40
- `OK NOOP completed`: 22
- Context classification:
  - `post_idle_done`: 22
  - `startup_after_ENABLE`: 7
  - `noop_chain`: 7
  - `mid_status`: 4

Most important pattern:

- `IDLE -> DONE -> OK Idle completed -> NOOP -> OK NOOP completed`

Example (post-IDLE NOOP, then later `UNSELECT`):

```text
[mail.drobnik.com:45959996-45960024]
45959997 DONE
45960000 18.445 OK Idle completed (...)
45960003 19.445 NOOP
45960006 19.445 OK NOOP completed (...)
...
45960021 20.445 UNSELECT
```

Example (post-IDLE NOOP, then immediate re-IDLE):

```text
[mail.drobnik.com:45538512-45538531]
45538513 DONE
45538516 17.4194 OK Idle completed (...)
45538519 18.4194 NOOP
45538522 18.4194 OK NOOP completed (...)
45538528 19.4194 IDLE
45538531 + idling
```

Observed startup-adjacent NOOP with no visible response in same session:

```text
[mail.drobnik.com:258846-258850]
258847 DONE
258850 5.6213 NOOP
# then new INITIATING CONNECTION / CONNECTED follows
```

Distribution by day in this log:

- Mar 06: 15
- Mar 05: 14
- Mar 07: 5
- Mar 04: 3
- Mar 01: 2
- Feb 26: 1

### 2.6 Reconnect and Rotation Behavior

Connect timing:

- paired `INITIATING CONNECTION -> CONNECTED` latency:
  - min 0.050s, p50 0.117s, p90 0.449s, p95 2.292s, max 19.849s, mean 0.487s
- paired connections: 5341
- unpaired `INITIATING CONNECTION` attempts: 1496
- unmatched `CONNECTED`: 1

Long-IDLE session rotation (sessions with IDLE lifetime >= 30m):

- delay from session end to next `INITIATING CONNECTION`:
  - min 0.0s, p50 183.200s, p90 1213.122s, p95 1308.187s, max 10598.600s, mean 553.748s

Server-side disconnects:

- `* BYE`: 0 observed.
- Similar to Gmail, transitions are mostly client-driven (`DONE`, `UNSELECT`, `LOGOUT`, reconnect).

---

## 3. Side-by-Side Comparison

| Area | Gmail | mail.drobnik.com |
|---|---:|---:|
| `INITIATING CONNECTION` | 6781 | 6837 |
| `CONNECTED` | 5456 | 5342 |
| `IDLE` | 2895 | 5489 |
| `DONE` | 2284 | 4776 |
| Complete IDLE cycles (parsed) | 2223 | 4725 |
| IDLE p50 / p95 | 159.1s / 300.3s | 93.5s / 301.5s |
| Event-driven IDLE exits | 100 | 261 |
| `NOOP` | 0 | 40 |
| `CHECK` | 0 | 154 |
| `ENABLE QRESYNC` | 0 | 5342 |
| `* OK Still here` | 0 | 2855 |
| `* BYE` | 0 | 0 |

Main strategic differences:

- Gmail profile is simpler: OAUTHBEARER + `UNSELECT/SELECT/UID FETCH CHANGEDSINCE` + IDLE.
- drobnik profile is extension-heavy: `ENABLE QRESYNC`, broader mailbox fan-out, `CHECK`, occasional `NOOP` after IDLE exits, and server keepalive chatter.

---

## 4. Authenticated Connection Concurrency (Is it one connection?)

Parsed concurrency metrics from the current snapshot:

| Metric | Gmail | mail.drobnik.com |
|---|---:|---:|
| Connected sessions (parsed) | 5460 | 5340 |
| Authenticated sessions | 5317 | 5331 |
| Authenticated sessions that entered IDLE | 965 | 814 |
| Authenticated sessions without IDLE | 4352 | 4517 |
| Max concurrent authenticated sessions | 4 | 4 |
| Mean concurrent authenticated sessions | 0.426 | 0.794 |
| p50 concurrent authenticated sessions | 0 | 0 |
| p90 concurrent authenticated sessions | 1 | 2 |
| `FETCH` while another authenticated session was idling | 123 | 261 |
| `UID FETCH` while another authenticated session was idling | 2909 | 19359 |

Conclusion:

- It is not a strict single-connection model.
- Mail.app keeps an authenticated IDLE connection active, while separate authenticated worker connections run sync commands (`UID FETCH`, `STATUS`, `SELECT`, etc.).
- Concurrency is low but real: usually 0-2 authenticated sockets active, with bursts up to 4.

Concrete overlap proof (IDLE on one socket, fetch on another):

```text
[imap.gmail.com:330-352]
READ ... socket:0x60000191a640
+ idling
 ...
 WROTE ... socket:0x60000191bc60
 8.859 UID FETCH 1:6131 (FLAGS UID) (CHANGEDSINCE 1433050)
```

```text
[mail.drobnik.com:932-939]
+ idling                                  (socket:0x6000019a1200)
...
WROTE ... socket:0x6000019f1e00
196.821 UID FETCH 1:918045 (FLAGS UID) (CHANGEDSINCE 3124051 VANISHED)
```

How this answers the architecture question:

- The IDLE socket is primarily a push/listener channel.
- Fetching work is often dispatched on separate authenticated sockets in parallel.
- This is why you see IDLE continue while other authenticated sessions perform heavy mailbox deltas.

---

## 5. Replication Guidance for SwiftMail

Implement one core state machine with provider capability profiles.

### Core (both)

- Keep one long-lived sync connection in IDLE.
- Exit IDLE with `DONE` for periodic maintenance and for event handling.
- On event (`EXISTS/EXPUNGE/FETCH`), fetch/update quickly, then return to IDLE.
- Use additional short-lived worker sessions for non-IDLE tasks.

### Gmail profile

- Auth: OAUTHBEARER.
- Prefer `[Gmail]/All Mail` as primary IDLE target.
- No provider-specific `NOOP` loop needed.
- Refresh using `UNSELECT -> SELECT (CONDSTORE) -> UID FETCH ... CHANGEDSINCE` plus `STATUS` sweep.

### drobnik profile

- Auth: PLAIN (as observed) and immediately `ENABLE QRESYNC` when supported.
- IDLE target often `INBOX` (and specific folders depending on workload).
- Support `CHECK` after IDLE completion.
- Support optional post-IDLE `NOOP` probe behavior (but keep it profile/capability gated).
- Expect and ignore untagged `* OK Still here` while idling.

---

## 6. Enhanced Blueprint for SwiftMail (Toward a "Perfect" Strategy)

This section turns observed Mail.app behavior into an implementation-grade strategy.

### 6.1 Design Targets

- Keep one account-level near-real-time channel (`IDLE`) active whenever online.
- Keep sync latency low: when IDLE receives `EXISTS/EXPUNGE/FETCH`, start delta sync quickly.
- Limit open authenticated sockets while preserving responsiveness.
- Recover from transport/auth failures without account stalls.
- Avoid provider-specific behavior leakage by putting differences behind profiles.

### 6.2 Connection Topology (Recommended)

Use role-based connections per account:

- `idleOwner` (exactly 1): long-lived authenticated session, selected mailbox, mostly in `IDLE`.
- `workerPool` (0..N): short/medium-lived authenticated sessions for `UID FETCH`, `STATUS`, `LIST`, mailbox fan-out.
- `bootstrap` (ephemeral): optional one-shot connection for capability/auth warm-up.

Recommended limits from observed concurrency:

- Default hard cap: `maxAuthenticatedConnections = 3` per account (`1 idle + 2 workers`).
- Temporary burst cap: `4` (matches observed Mail.app peak in both logs).
- Worker idle TTL: close worker sessions after short inactivity window to reduce server load.

Evidence that this model matches Mail.app:

- Gmail and drobnik both show one socket in `+ idling` while another authenticated socket issues `UID FETCH ... CHANGEDSINCE` (see section 4 excerpts).

### 6.3 Timer and Threshold Defaults

Use profile defaults, then tune with telemetry:

| Setting | Gmail | mail.drobnik.com | Why |
|---|---:|---:|---|
| `idleRenewInterval` | 285s | 285s | Both logs cluster around 5-minute IDLE churn (p95 around 300s). |
| `idleDoneAckTimeout` | 15s | 15s | Detect stuck `DONE -> OK` transitions early. |
| `taggedCommandTimeout` | 60s | 60s | Bound long operations while tolerating slower server responses. |
| `eventBatchWindow` | 250ms | 250ms | Coalesce event bursts into one delta fetch pass. |
| `postIdleNoop` | disabled | enabled (conditional) | Gmail shows zero NOOP usage; drobnik occasionally uses NOOP post-IDLE. |
| `postIdleNoopDelay` | n/a | 0.5-1.0s | Keep behavior close to observed post-`DONE` probes. |
| `initialReconnectDelay` | 1s | 1s | Fast recovery baseline. |
| `maxReconnectDelay` | 120s | 120s | Prevent tight retry loops. |
| `reconnectJitter` | +/-20% | +/-20% | Avoid synchronized reconnect storms. |
| `workerIdleTTL` | 120s | 120s | Preserve responsiveness without keeping many workers open. |
| `statusSweepInterval` | 120-180s | 120-180s | Mirrors observed frequent `STATUS ... HIGHESTMODSEQ` sweeps. |

### 6.4 Provider Profiles and Capability Gating

Define explicit provider/capability behavior:

- Gmail profile:
  - Prefer OAUTHBEARER.
  - No `NOOP` loop in steady-state IDLE flow.
  - Use CONDSTORE-based delta (`CHANGEDSINCE`) after `SELECT`.
  - Primary IDLE target can be `[Gmail]/All Mail`.
- mail.drobnik.com profile:
  - Authenticate with PLAIN (as observed in current logs).
  - Send `ENABLE QRESYNC` immediately post-auth when advertised.
  - Treat `* OK Still here` as benign IDLE keepalive noise.
  - Allow optional post-IDLE `NOOP` probe and optional `CHECK` branch.

Never hardcode by hostname alone when avoidable. Prefer:

- `CAPABILITY`-driven feature flags (`IDLE`, `CONDSTORE`, `QRESYNC`, `UIDPLUS`, etc.).
- Host-specific overrides only where telemetry proves persistent behavior differences.

### 6.5 IDLE Loop State Machine (Account-Level)

```text
Disconnected
  -> Connecting
  -> Authenticating
  -> SelectingIdleMailbox
  -> Idling
       on mailbox event         -> LeaveIdleForEvent
       on renew timer           -> LeaveIdleForMaintenance
       on queued high-prio work -> LeaveIdleForWork
       on EOF/error             -> Reconnecting
  -> Resyncing
  -> SelectingIdleMailbox
  -> Idling
```

Core loop logic:

1. Ensure `idleOwner` is authenticated and mailbox-selected.
2. Enter `IDLE`; arm renew timer.
3. Exit with `DONE` on event, maintenance interval, or urgent queued work.
4. Require tagged completion (`OK IDLE terminated/completed`) within timeout.
5. Dispatch delta sync work to workers when possible.
6. Re-enter IDLE quickly after sync branch completes.

### 6.6 Work Scheduling Model

Use three priority lanes:

- `P0 event lane`: immediate delta sync from IDLE signals (`EXISTS/EXPUNGE/FETCH`).
- `P1 consistency lane`: periodic `STATUS`/checkpoint refresh for watched mailboxes.
- `P2 background lane`: deep folder scans, older message hydration, body fetches.

Rules:

- P0 can preempt P1/P2.
- Avoid running heavy fetches on `idleOwner` unless no worker is available.
- Debounce repeated event bursts per mailbox before issuing delta fetch.
- Coalesce mailbox work so one worker command fetches all currently pending deltas.

### 6.7 Reconnect and Recovery Matrix

| Trigger | Detection | Action |
|---|---|---|
| Socket EOF / transport error | Read/write failure | Mark connection dead, requeue in-flight work, reconnect with backoff+jitter. |
| `DONE` ack timeout | No tagged `OK` after `DONE` | Force-close connection, reopen, replay mailbox checkpoint sync. |
| Tagged command timeout | Command exceeds timeout | Cancel command, close worker, retry command on fresh worker (bounded retries). |
| Auth failure (`NO [AUTHENTICATIONFAILED]`) | Tagged auth `NO`/`BAD` | Refresh credentials/token, reconnect immediately, then exponential backoff if repeated. |
| `UIDVALIDITY` change | `SELECT` response changed | Drop stale UID mapping for mailbox; run full mailbox resync. |
| Repeated `BAD` protocol errors | N errors in rolling window | Reset session state and reconnect cleanly. |

Additional safeguards:

- Circuit breaker per account after repeated short-fail loops.
- Global reconnect budget to avoid local network storms.

### 6.8 Delta Sync Strategy (QRESYNC/CONDSTORE First)

Per mailbox checkpoint:

- `UIDVALIDITY`
- `HIGHESTMODSEQ`
- `UIDNEXT`
- last successful delta timestamp

Sync branch:

1. `SELECT mailbox (CONDSTORE)`; when supported, include QRESYNC path.
2. Prefer `UID FETCH ... (CHANGEDSINCE modseq)` (plus `VANISHED` handling where available).
3. Apply adds/flag updates/deletes atomically to local store.
4. Persist updated checkpoints only after successful apply.

Fallback branch:

- If no CONDSTORE/QRESYNC, use `UID SEARCH`/`UID FETCH` windows from last known UID.

### 6.9 NOOP Policy (Precise)

`NOOP` should be a tactical probe, not the primary sync heartbeat.

- Gmail:
  - Disable NOOP in normal IDLE loop.
  - Only use NOOP as emergency liveness check when IDLE is not active and no safe alternative exists.
- mail.drobnik.com:
  - Optional `NOOP` immediately after `DONE` in low-work branches.
  - Skip NOOP when event-driven work is already queued (go directly to delta fetch).
  - Skip NOOP when server is already sending untagged keepalive chatter and connection is healthy.

Concrete observed post-IDLE NOOP pattern:

```text
[mail.drobnik.com:45959996-45960024]
DONE
... OK Idle completed
NOOP
... OK NOOP completed
UNSELECT
```

### 6.10 Server-Disconnect Handling Reality

In this dataset:

- No explicit `* BYE` was observed for either provider.
- Many transitions are client-driven (`DONE`, `UNSELECT`, `LOGOUT`, reconnect).

Therefore SwiftMail should not depend on `BYE` to detect dead sessions.

Required liveness detection:

- Read/write error detection.
- Command timeout watchdog.
- IDLE renew watchdog.
- Optional low-frequency synthetic liveness probe when session appears silent beyond normal profile behavior.

### 6.11 Observability and Telemetry (Must-Have)

Track at least these metrics per account and provider:

- `imap_authenticated_connections_current`
- `imap_idle_sessions_current`
- `imap_idle_cycle_duration_seconds` (histogram)
- `imap_idle_exit_reason_total{event,maintenance,work,reconnect}`
- `imap_reconnect_total{cause}`
- `imap_command_timeout_total{command}`
- `imap_auth_fail_total`
- `imap_delta_sync_latency_seconds` (event receipt -> local apply complete)
- `imap_worker_queue_depth`

Useful structured log fields:

- account id
- provider profile id
- socket id / connection id
- mailbox
- command tag + command name
- state machine state
- reconnect attempt + backoff

### 6.12 SwiftMail Implementation Roadmap

Suggested order:

1. Add provider profile model and capability map.
2. Add account-level `ConnectionCoordinator` actor with role-based connections.
3. Implement robust IDLE owner state machine with renew/done/watchdog timers.
4. Add worker scheduler with priority lanes and bounded pool.
5. Add reconnect engine (backoff, jitter, auth-refresh hooks, replay queue).
6. Add checkpointed delta sync engine (CONDSTORE/QRESYNC first, fallback branch).
7. Add telemetry counters/histograms and structured logs.
8. Add stress/integration tests for concurrency and reconnect behavior.

Likely touch points in current SwiftMail tree:

- `Sources/SwiftMail/IMAP/IMAPConnection.swift`
- `Sources/SwiftMail/IMAP/IMAPIdleSession.swift`
- `Sources/SwiftMail/IMAP/IMAPIdleConfiguration.swift`
- `Sources/SwiftMail/IMAP/IMAPCommandQueue.swift`
- `Sources/SwiftMail/IMAP/IMAPServer.swift`

### 6.13 Acceptance Criteria for "Production-Ready" IDLE

- Sustains long-running account sessions without manual restart.
- Recovers automatically from transient auth/network failures.
- Handles event bursts without connection explosion.
- Maintains mailbox consistency across reconnects and UIDVALIDITY changes.
- Produces enough telemetry to tune profile defaults per provider over time.
