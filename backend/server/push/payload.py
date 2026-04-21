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

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

SCENARIO_CLASS_PREPARING = "classPreparing"
SCENARIO_IN_CLASS = "inClass"
SCENARIO_ASSIGNMENT_URGENT = "assignmentUrgent"


@dataclass(frozen=True)
class ApnsRequest:
    """Transport-level view of a single APNs call."""

    device_token: str
    topic: str
    expiration: int  # unix seconds
    priority: int
    message: dict[str, Any]


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


def build_pts_payload(
    scenario: str,
    source_id: str,
    snapshot: dict[str, Any],
    attrs_type: str = "TigerDuckActivityAttributes",
    now: datetime | None = None,
) -> dict[str, Any]:
    """Construct the `aps` payload for a Push-to-Start."""
    timestamp = int((now or datetime.now(timezone.utc)).timestamp())
    return {
        "aps": {
            "timestamp": timestamp,
            "event": "start",
            "attributes-type": attrs_type,
            "attributes": {"activityId": source_id},
            "content-state": {"snapshot": snapshot},
            "alert": _alert_for(scenario, snapshot),
        }
    }


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

    `expiration_slack_seconds`: if the device is offline past fire_at + slack,
    APNs discards the push. Keeps stale Live Activities from popping up hours late.
    """
    topic = f"{bundle_id}.push-type.liveactivity"
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
