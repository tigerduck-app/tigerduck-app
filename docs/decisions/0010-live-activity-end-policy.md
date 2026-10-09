# 0010. End Live Activities only for expiry, duplicates, quiet days or unavailability

Status: accepted

## Context

Identity is the scenario-scoped `snapshot.composedActivityId` on the device and in the
backend's push path alike, so several activities can run at once: the backend pre-starts later
slots by push-to-start (a classPreparing activity and its inClass follow-up are distinct) and
ends each with the end job it files when the device registers its update token
(`server/routes/live_activities_v3.py` in `tigerduck-app/tigerduck-backend`), while the
resolver returns one snapshot at a time. ActivityKit does not end an activity when its
`staleDate` passes. The backend checks holidays only when a start push fires
(`server/push/pipeline.py`), so a holiday published later, or "still have class" switched off
after an activity appeared, never reaches one already running. While Live Activity is
unavailable (`effectiveLiveActivityEnabled` is false), the backend can still start activities
from a schedule uploaded earlier.

## Decision

- Not being the current resolved target is never a reason to end an activity; it ends by its
  backend end job or its own countdown (`scheduleAutomaticEnd`).
- `LiveActivityCoordinator.pruneRunningActivities` runs on every `apply` and for each element
  of `Activity.activityUpdates`, and ends only:
  - activities whose countdown target has passed;
  - extra live copies of one `activityId`, keeping the one with an APNs update token, else the
    lowest `Activity.id`;
  - class activities on a day classes do not meet, by the academic calendar and the user's
    "still have class" choices; assignment activities stay;
  - every activity while Live Activity is unavailable, with no update token registered.
- The rules are static functions over `RunningActivityFacts`, testable without ActivityKit:
  `endReason` (`instanceIdsToEnd` is its batch form) and `duplicateInstanceIdsToEnd`. `apply`
  asks `canStart` after the prune's await, since its snapshot was resolved before it.

## Alternatives

- Ending every activity that is not the current target: it ended every pre-started activity
  when the app came to the foreground, which
  https://github.com/tigerduck-app/tigerduck-app/pull/65 and
  https://github.com/tigerduck-app/tigerduck-app/pull/196 each fixed by removing the rule.
- No prune, leaving expiry to `staleDate` and end jobs: expired activities lingered on screen,
  so https://github.com/tigerduck-app/tigerduck-app/pull/76 restored the prune, and the rule
  with it.

## Consequences

- `LiveActivityCoordinatorTests` pins these functions, not the loop: a branch such as
  `else if !isCurrentTarget { await end(...) }` added to it would pass every test, so review
  loop changes against this record.
- A new end reason goes into `endReason`, and into `canStart` if it should also stop a start.
