"""Push-to-Start Live Activity payload builder.

References:
  - https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications
  - https://developer.apple.com/documentation/usernotifications/sending-push-notifications-using-command-line-tools

Payload shape for a PTS push:
    {
      "aps": {
        "timestamp": <unix seconds>,
        "event": "start",
        "attributes-type": "TigerDuckActivityAttributes",
        "attributes": { "activityId": "<sourceId>" },
        "content-state": { "snapshot": {...LiveActivitySnapshot JSON...} },
        "alert": { "title": "...", "body": "..." }
      }
    }
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import StrEnum
from typing import Any

SCENARIO_CLASS_PREPARING = "classPreparing"
SCENARIO_IN_CLASS = "inClass"
SCENARIO_ASSIGNMENT_URGENT = "assignmentUrgent"

# Swift's JSONDecoder uses `.deferredToDate` by default, which encodes/
# decodes `Date` as `timeIntervalSinceReferenceDate` — seconds since
# 2001-01-01T00:00:00Z. iOS's ActivityKit uses this decoder when turning
# a PTS payload into `ContentState`, so any Date field we send as an
# ISO8601 string silently fails to decode and iOS drops the push.
#
# Reference epoch in Unix seconds:
_SWIFT_REFERENCE_EPOCH = 978307200  # 2001-01-01T00:00:00Z

# Snapshot fields typed as `Date?` on the Swift side. Must be encoded as
# Double (seconds since reference date) or null.
_DATE_FIELDS = ("countdownTarget", "progressStart")


def _to_swift_reference_seconds(value: Any) -> Any:
    """Convert ISO8601 strings or Unix-second numbers into Swift's
    `timeIntervalSinceReferenceDate` Double. Pass through None/invalid
    shapes untouched so we never crash the dispatcher on bad data."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        # Assume already in Swift reference seconds. If you later decide
        # to pass Unix seconds instead, convert with value - _SWIFT_REFERENCE_EPOCH.
        return float(value)
    if isinstance(value, str):
        # Accept both "...Z" and "...+00:00" forms.
        try:
            dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return value
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp() - _SWIFT_REFERENCE_EPOCH
    return value


def _normalize_snapshot_for_apns(snapshot: dict[str, Any]) -> dict[str, Any]:
    """Return a copy of the snapshot with Date fields converted to the
    format Swift's default JSONDecoder expects. Non-destructive."""
    out = dict(snapshot)
    for field in _DATE_FIELDS:
        if field in out:
            out[field] = _to_swift_reference_seconds(out[field])
    return out


class PushKind(StrEnum):
    """Which APNs channel this request targets.

    * `live_activity` — Push-to-Start / Live Activity updates. Topic has the
      `.push-type.liveactivity` suffix and APNs refuses delivery otherwise.
    * `alert` — standard user-facing alert/banner push. Topic is the plain
      bundle id.
    """

    live_activity = "live_activity"
    alert = "alert"


@dataclass(frozen=True)
class ApnsRequest:
    """Transport-level view of a single APNs call."""

    device_token: str
    topic: str
    expiration: int  # unix seconds
    priority: int
    message: dict[str, Any]
    # Default stays on live_activity so the PTS code path keeps working
    # without changes. Alert callers set `kind=PushKind.alert` explicitly.
    kind: PushKind = field(default=PushKind.live_activity)


def _alert_for(scenario: str, snapshot: dict[str, Any]) -> dict[str, str]:
    """User-facing title/body for lock screen / banner."""
    title = snapshot.get("title", "")
    subtitle = snapshot.get("subtitle", "")
    location = snapshot.get("locationText") or ""

    if scenario == SCENARIO_CLASS_PREPARING:
        body = f"{subtitle}{' · ' + location if location else ''}".strip()
        return {"title": f"即將上課：{title}", "body": body}
    if scenario == SCENARIO_IN_CLASS:
        body = f"{subtitle}{' · ' + location if location else ''}".strip()
        return {"title": f"上課中：{title}", "body": body}
    if scenario == SCENARIO_ASSIGNMENT_URGENT:
        return {"title": f"作業即將到期：{title}", "body": subtitle}
    return {"title": title, "body": subtitle}


def composed_activity_id(scenario: str, source_id: str) -> str:
    """Mirror of Swift's `LiveActivitySnapshot.composedActivityId`.

    Must stay in sync with `LiveActivitySnapshot.composedActivityId` on the
    client. Scoping by scenario lets a classPreparing activity and its
    follow-up inClass activity coexist distinctly so a PTS for inClass never
    collides with a still-running classPreparing activity.
    """
    return f"{scenario}::{source_id}"


def _countdown_target_unix(snapshot: dict[str, Any]) -> int | None:
    """Extract `countdownTarget` from the stored snapshot as Unix seconds.

    The snapshot may hold it as an ISO8601 string (fresh from client) or a
    Double (already normalized). Return None if the value is missing or
    unparseable — the caller decides the fallback.
    """
    value = snapshot.get("countdownTarget")
    if value is None:
        return None
    if isinstance(value, (int, float)):
        # Already in Swift reference seconds post-normalization
        return int(float(value) + _SWIFT_REFERENCE_EPOCH)
    if isinstance(value, str):
        try:
            dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    return None


def build_pts_payload(
    scenario: str,
    source_id: str,
    snapshot: dict[str, Any],
    attrs_type: str = "TigerDuckActivityAttributes",
    now: datetime | None = None,
) -> dict[str, Any]:
    """Construct the `aps` payload for a Push-to-Start."""
    timestamp = int((now or datetime.now(timezone.utc)).timestamp())
    normalized_snapshot = _normalize_snapshot_for_apns(snapshot)
    aps: dict[str, Any] = {
        "timestamp": timestamp,
        "event": "start",
        "input-push-token": 1,
        "attributes-type": attrs_type,
        "attributes": {"activityId": composed_activity_id(scenario, source_id)},
        "content-state": {"snapshot": normalized_snapshot},
        "alert": _alert_for(scenario, snapshot),
    }
    # Fix #4: auto-dismiss the Live Activity when the countdown target is
    # reached. For classPreparing, this means the activity disappears at
    # slot.start — so when the inClass PTS arrives there's no leftover
    # activity to collide with. Apple expects Unix seconds.
    dismissal_unix = _countdown_target_unix(snapshot)
    if dismissal_unix is not None:
        aps["dismissal-date"] = dismissal_unix
    return {"aps": aps}


def build_end_payload(
    snapshot: dict[str, Any],
    now: datetime | None = None,
    dismissal_date: datetime | None = None,
) -> dict[str, Any]:
    """Construct the `aps` payload that explicitly ends a Live Activity."""
    ts = now or datetime.now(timezone.utc)
    timestamp = int(ts.timestamp())
    normalized_snapshot = _normalize_snapshot_for_apns(snapshot)
    dismissal_unix = int((dismissal_date or ts).timestamp())
    return {
        "aps": {
            "timestamp": timestamp,
            "event": "end",
            "content-state": {"snapshot": normalized_snapshot},
            "dismissal-date": dismissal_unix,
        }
    }


def build_alert_request(
    *,
    device_token: str,
    bundle_id: str,
    title: str,
    body: str,
    bulletin_id: int,
    source_url: str,
    canonical_org: str,
    thread_id: str = "bulletin",
    ttl_seconds: int = 7 * 24 * 3600,
    now: datetime | None = None,
) -> ApnsRequest:
    """Build a standard alert-push APNs request for a bulletin notification.

    `apns-topic` is the plain bundle id (no `.push-type.liveactivity`
    suffix), otherwise iOS drops the push silently. `thread-id` groups
    bulletins under one notification stack on the lock screen.

    Extra keys at the top level (`bulletin_id`, `source_url`,
    `canonical_org`) ride along for the client's notification content
    extension and deep-link handler.
    """
    timestamp = int((now or datetime.now(timezone.utc)).timestamp())
    expiration = timestamp + ttl_seconds
    message: dict[str, Any] = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "badge": 1,
            "mutable-content": 1,
            "thread-id": thread_id,
        },
        "bulletin_id": bulletin_id,
        "source_url": source_url,
        "canonical_org": canonical_org,
    }
    return ApnsRequest(
        device_token=device_token,
        topic=bundle_id,
        expiration=expiration,
        priority=10,
        message=message,
        kind=PushKind.alert,
    )


@dataclass(frozen=True)
class FcmRequest:
    """Transport-level view of a single FCM call. Mirrors `ApnsRequest` so
    the dispatcher can branch on platform without leaking SDK types."""

    token: str
    title: str
    body: str
    data: dict[str, str]
    ttl_seconds: int = 7 * 24 * 3600


def build_fcm_alert_request(
    *,
    fcm_token: str,
    title: str,
    body: str,
    bulletin_id: int,
    source_url: str,
    canonical_org: str,
    ttl_seconds: int = 7 * 24 * 3600,
) -> FcmRequest:
    """Build an FCM alert request for a bulletin notification.

    FCM `data` values must all be strings; the Android client parses
    `bulletin_id` back to int. Keeps shape parity with `build_alert_request`
    for APNs.
    """
    return FcmRequest(
        token=fcm_token,
        title=title,
        body=body,
        data={
            "bulletin_id": str(bulletin_id),
            "source_url": source_url,
            "canonical_org": canonical_org,
        },
        ttl_seconds=ttl_seconds,
    )


def build_apns_request(
    *,
    device_token: str,
    bundle_id: str,
    scenario: str,
    source_id: str,
    fire_at: datetime,
    snapshot: dict[str, Any],
    attrs_type: str = "TigerDuckActivityAttributes",
    expiration_slack_seconds: int = 60,
    now: datetime | None = None,
) -> ApnsRequest:
    """Bundle everything the APNs client needs to send one PTS push.

    Fix #3: `apns-expiration` defaults to `snapshot.countdownTarget`
    (= the event moment — class start / class end / due date). That is
    the point past which the push is *meaningfully* stale; before then,
    if the phone was briefly offline and comes online, APNs should still
    deliver. Fallback to `fire_at + expiration_slack_seconds` only when
    countdownTarget is absent.
    """
    topic = f"{bundle_id}.push-type.liveactivity"
    countdown_unix = _countdown_target_unix(snapshot)
    if countdown_unix is not None:
        expiration = countdown_unix
    else:
        expiration = int(fire_at.timestamp()) + expiration_slack_seconds
    message = build_pts_payload(
        scenario=scenario,
        source_id=source_id,
        snapshot=snapshot,
        attrs_type=attrs_type,
        now=now,
    )
    return ApnsRequest(
        device_token=device_token,
        topic=topic,
        expiration=expiration,
        priority=10,
        message=message,
    )


def build_live_activity_end_request(
    *,
    update_token: str,
    bundle_id: str,
    snapshot: dict[str, Any],
    ttl_seconds: int = 4 * 3600,
    now: datetime | None = None,
) -> ApnsRequest:
    """Build an APNs request that ends one existing Live Activity."""
    ts = now or datetime.now(timezone.utc)
    topic = f"{bundle_id}.push-type.liveactivity"
    return ApnsRequest(
        device_token=update_token,
        topic=topic,
        expiration=int(ts.timestamp()) + ttl_seconds,
        priority=10,
        message=build_end_payload(snapshot=snapshot, now=ts, dismissal_date=ts),
    )
