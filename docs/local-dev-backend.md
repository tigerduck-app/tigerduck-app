# Local dev backend

This guide is for contributors running a **local TigerDuck backend** on their
own Mac while developing the iOS app. It is **not** for production deploys —
production lives on a separate VPS behind nginx-proxy-manager, with its own
`.env`, its own database, and its own APNs environment.

The split exists because:

- APNs has two parallel environments (sandbox / production) and a device
  token from one cannot be used to push via the other. Xcode Debug builds
  produce sandbox tokens; TestFlight / App Store builds produce production
  tokens. Talking to the wrong backend → silent push failures.
- Production database stores real device tokens for real users. Running
  schema migrations or wiping data against it during development is not OK.
- Iterating on the backend (restart, migrate, hack endpoints) should never
  affect users.

The iOS app auto-resolves which backend to talk to based on the build
configuration. There is no UI toggle, no manual switch.

## How endpoint selection works

```
Build configuration       APNs env        Backend URL
─────────────────────────────────────────────────────────────────────────────
Debug (Xcode Run)         development     Secrets.plist["DebugServerURL"]
                                          fallback: http://localhost:40000/v2
Release (TestFlight,      production      https://api.tigerduck.app/v2
         Archive,
         App Store)
```

The Debug-build resolution chain is `PushCoordinator.resolveServerURL()`:

1. `Defaults[.pushServerURLOverride]` — UserDefaults escape hatch for
   ad-hoc switching to staging. Gated by an allowlist
   (`isOverrideAllowed`) — public hosts must be `api.tigerduck.app` or
   `staging.api.tigerduck.app` over HTTPS; private targets must be
   loopback or RFC1918 IPv4 (HTTP or HTTPS).
2. `Secrets.plist["DebugServerURL"]` — your per-developer LAN backend.
3. `http://localhost:40000/v2` — Simulator-friendly fallback.

At launch `PushCoordinator.assertEnvConsistency()` crashes Debug builds if
the resolved URL and `PushAPNsEnv.resolvedForBuild` disagree (e.g. a stale
override pointing prod from a Debug build). Release builds strip the
assert under `-O`.

## One-time setup

### 1. Pick a fixed LAN IP for your Mac

Configure your router to give your Mac a static DHCP lease, or set a manual
IP under System Settings → Network. You want it to survive WiFi reconnects
and reboots without changing.

Examples that work: `192.168.1.42`, `10.0.0.50`, `172.16.5.3`.

The iOS app's override allowlist accepts anything in 10/8, 172.16/12,
192.168/16, plus `localhost` / `127.0.0.1`. No per-IP configuration on
the iOS side.

### 2. Start a local backend

The repo's prod-shaped `backend/start.sh` does not publish the backend port
to the host (it expects nginx-proxy-manager to proxy in over a docker
network). For local dev, you need the port reachable from your iPhone.

Easiest path: add a `docker-compose.override.yml` next to
`backend/docker-compose.yml`:

```yaml
services:
  backend:
    ports:
      - "40000:40000"
    networks:
      - tigerduck-db
      # drop proxy-net — there is no NPM locally
```

Then fill `backend/.env` (see `backend/.env.example`). Key values for dev:

- `TIGERDUCK_ENV=development`
- `TIGERDUCK_APNS_ENV=development` ← the critical one
- `TIGERDUCK_API_SHARED_SECRET=…` ← copy this into `DebugAPIToken` below
- `POSTGRES_PASSWORD=…` ← only used by your local stack

APNs `.p8` key file: same key works for both `development` and
`production` envs (Apple's auth keys are env-agnostic). Drop it at
`backend/server/secrets/AuthKey_<KEY_ID>.p8`.

Bring it up:

```sh
cd backend
./start.sh   # docker compose up -d --build && tails the log
```

The backend should now respond on `http://<your-mac-LAN-IP>:40000/v2`.

### 3. Fill `Secrets.plist` on the iOS side

`swift/TigerDuck/Secrets.plist` is gitignored. Copy the template:

```sh
cp swift/TigerDuck/Secrets.example.plist swift/TigerDuck/Secrets.plist
```

Edit three keys:

```xml
<key>APIToken</key>
<string>…production shared secret…</string>      <!-- from prod backend ops -->

<key>DebugAPIToken</key>
<string>…dev backend shared secret…</string>     <!-- = your TIGERDUCK_API_SHARED_SECRET -->

<key>DebugServerURL</key>
<string>http://192.168.X.X:40000/v2</string>     <!-- your Mac's LAN IP -->
```

If you only develop against the Simulator, you can omit `DebugServerURL`
— the Debug fallback `http://localhost:40000/v2` resolves to your Mac
because the Simulator shares network namespace with the host.

If you leave `DebugAPIToken` blank, `resolveSharedSecret()` falls back to
`APIToken`, matching the prior single-token workflow. Less hygienic, fine
for solo iteration.

## Running the app

- **Simulator**: `⌘R` in Xcode (Debug config). The app talks to your local
  backend automatically.
- **Physical device**: `⌘R` in Xcode with the device selected. Device must
  be on the same LAN as your Mac, and your Mac's firewall must allow
  inbound 40000 (System Settings → Network → Firewall → Options).

The Debug startup assert will fire if anything is misaligned: check the
console for "Push env mismatch:" and follow the diagnostic.

## Sanity checks before reporting "push doesn't work"

1. **Build configuration**: `defaults read org.ntust.app.TigerDuck` and look
   for `pushServerURLOverride`. If set to a prod URL while building Debug,
   the override wins — clear it (`defaults delete org.ntust.app.TigerDuck
   pushServerURLOverride`) or stop the override.
2. **APNs env on device side**: open the app, go to push diagnostics. The
   reported APNs env should be `development` for Debug, `production` for
   TestFlight / App Store.
3. **APNs env on backend side**: `docker compose exec backend env | grep
   APNS_ENV` should report `development` on your local stack. If it says
   `production`, you forgot to flip `.env`.
4. **Token round-trip**: enable push in the app once, then `docker compose
   exec backend psql ... -c "select apns_env, created_at from devices order
   by created_at desc limit 3;"`. The newest row should be `development`.

Mismatches across these four are the entire population of "why didn't my
push arrive" failures we have seen.

## What lives where

| Concern | iOS-side | Backend-side |
|---|---|---|
| URL resolution | `PushCoordinator.resolveServerURL` | n/a |
| Shared secret read | `PushCoordinator.resolveSharedSecret` | `TIGERDUCK_API_SHARED_SECRET` |
| APNs env constant | `PushAPNsEnv.resolvedForBuild` | `TIGERDUCK_APNS_ENV` |
| ATS exception | `swift/TigerDuck/Info.plist` (`NSAllowsLocalNetworking`) | n/a |
| Production endpoint | `AppConstants.productionPushServerURL` | nginx-proxy-manager → tigerduck-internal:40000 |
| Per-dev override | `Secrets.plist["DebugServerURL"]` | n/a |
