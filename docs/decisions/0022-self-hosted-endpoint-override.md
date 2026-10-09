# 0022. Accept any backend host as an endpoint override, with HTTPS for routable hosts

Status: accepted

## Context

TigerDuck's backend is open source and self-hostable, and every build lets the user point the
app at another backend: `DebugEndpointStore` keeps a user-set endpoint in the Keychain, set in
Settings → Other settings → API endpoint or on onboarding's sign-in page. Debug builds also
read `Defaults[.pushServerURLOverride]` and `Secrets.plist["DebugServerURL"]`. Requests to the
backend carry the Bearer token from `AuthTokenManager`.

## Decision

- `PushServerConfig.isOverrideAllowed(_:)`, the gate every override passes, does not restrict
  the host. It checks transport only: an `http` or `https` scheme, a non-empty host and a port
  in 1...65535.
- Private, loopback and link-local hosts (`PushServerConfig.isPrivateOrLoopbackHost(_:)`) may
  use `http://`: a backend on the user's LAN or in the Simulator usually terminates no TLS and
  its traffic never leaves the local link, so requiring a certificate there would block the
  common self-hosting case for no real gain. CGNAT `100.64.0.0/10`, which the carrier routes,
  and `*.local` mDNS names, which are names rather than IP ranges, need HTTPS.
- Every other host, public IP literals and hostnames alike, must use `https://`: cleartext to
  a routable address puts the Bearer token on the wire for anyone on the path.
- `PushServerConfig.normalize(_:)` rewrites `https://` to `http://` for private hosts only,
  which fixes the common LAN typo that fails the handshake with `WRONG_VERSION_NUMBER`.
- `DebugEndpointStore.setOverride(_:)` stores an endpoint only after
  `EndpointHealthCheck.probe(_:)` finds a TigerDuck backend there, and `currentOverride()`
  checks the stored value against the gate again on every read.
- `PushCoordinator.assertEnvConsistency()` skips its host check while a user-set endpoint is
  active: a self-hosted backend cannot be enumerated, and a launch crash would leave no UI to
  clear the Keychain entry.

## Alternatives

- A host allowlist of `api.tigerduck.app` and its subdomains. It also kept a Keychain value
  seeded by a restored backup or MDM from redirecting the app off TigerDuck's own hosts, but it
  rules out self-hosting.

## Consequences

- A seeded Keychain value can redirect the app to any host that passes the gate; only the
  HTTPS floor for routable hosts applies to it, because the probe runs only when the app writes.
- When the transport rules tighten, `currentOverride()` ignores a stored value that no longer
  passes, and `storedButRejectedOverride()` lets the UI explain why.
