# 0008. Announce every device without a session, beside the signed-in registration

Status: accepted

## Context

The backend keeps two rows per device. `POST /devices/register` needs a session and writes
`user_devices`; `POST /devices/anonymous` (`PushAPIClient.registerAnonymousDevice`) needs none
and writes `device_registrations`. Operator (custom) push reaches a signed-in device through
`user_devices` and any other device only through `device_registrations`
(`portal/app/routes/custom_push.py` and `server/push/custom_push_targeting.py` in
`tigerduck-app/tigerduck-backend`). Through `/devices/register` alone, a device is invisible to
custom push while signed out or if nobody ever signed in on it, and while signed out that call
can only 401 into the retry ladder.

## Decision

- On iPhone and iPad, `PushRegistrationService.performRegister` announces the device on every
  registration attempt, and so on every launch, signed in or not, before the authenticated
  registration. The announce is best effort and sits outside the registration's do/catch, so
  its failure never marks the registration failed or starts its backoff.
- The server links the two rows on sign-in and unlinks them on sign-out (`linked_user_id` in
  `server/routes/user_devices.py`), and custom push targeting skips linked
  `device_registrations` rows, so neither state pushes a device twice.
- Every announce carries `server_push_enabled`, not only when it changes: signed out, the
  announced row is what targeting filters on and the preferences PATCH has no session, so the
  announce is the opt-out's only path to the server.
- `updateServerPushOptOut` announces unconditionally, so the signed-out row is right now and
  after a later sign-out, and PATCHes `user_devices` only when there is a session; signed out
  that PATCH is a certain 401.
- The bulletin switch (`bulletin_push_enabled`) is held only by `user_devices`, and every
  request the bulletin settings page makes needs a session, so `updateBulletinPushEnabled`
  announces nothing.

## Alternatives

- Registering only through `/devices/register`: a device that is signed out, or was never
  signed in, is invisible to custom push.

## Consequences

- A per-device flag that operator targeting filters on must travel on the announce as well as
  on the authenticated PATCH.
