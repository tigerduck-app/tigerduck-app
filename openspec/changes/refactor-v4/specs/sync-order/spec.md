# Spec Delta

## Purpose

Keeps every device that shares an account converging on one state: each refresh reads the backend
before it sends what it learned from the school, and no edit is lost to the order of the two.

## ADDED Requirements

### Requirement: A refresh reads the backend before it uploads school data
On launch, on return to the foreground and after a sign-in, the app SHALL apply the backend's state
before it applies school data fetched in the same refresh, and SHALL send changes derived from
school data only after that. Values SHALL merge per field by their stamps, so an edit this device
has not sent yet survives the pull. A local edit SHALL be sent at once, without waiting for a pull.

#### Scenario: The school answers first
- **WHEN** the school fetch finishes before the backend pull
- **THEN** its result is applied, and its upload sent, only after the pull has been applied

#### Scenario: An edit made offline
- **WHEN** this device changed a course colour while offline, and another device changed the same colour earlier
- **THEN** after the pull this device still shows its own colour and sends it

#### Scenario: The backend is unreachable
- **WHEN** the backend pull fails
- **THEN** the fetched school data is shown, and nothing derived from it is sent until a pull succeeds

#### Scenario: A new sign-in
- **WHEN** a device signs in and fetches the school roster before its first pull has finished
- **THEN** it sends no course upload until that pull has been applied

### Requirement: Every edit is sent with its own time
Each write of a user's edit to the backend SHALL carry the time the edit was made (`hlc`), however
late it is sent, so the backend keeps the newest edit across devices.

#### Scenario: A queued edit sent late
- **WHEN** device B's mark edit waits in its outbox while device A makes a newer edit of the same mark, and B's edit is sent afterwards
- **THEN** the backend keeps A's edit

### Requirement: A synced document merges per field
A write of a synced document SHALL change only the fields this device changed since the last
version it synced, and SHALL take every other field from the server's current version.

#### Scenario: Two devices change one section
- **WHEN** device B has an unsent change to one live activity setting and device A changed another setting in the same section
- **THEN** after B's write the document holds both changes

#### Scenario: A switch turned back on
- **WHEN** a sync switch is turned back on after another device changed that section
- **THEN** the device applies the server's section before it sends anything

### Requirement: A user's edit is never dropped
An edit that keeps failing to send SHALL be kept and sent again after the next pull or upload that
can make it succeed. It SHALL leave the queue only when it is sent, superseded by a newer edit, or
cleared by a sign-out.

#### Scenario: The course is not on the backend yet
- **WHEN** a course rename keeps getting 404 because the course upload has not landed
- **THEN** the rename is sent again after the next course upload

### Requirement: One send per channel at a time
A channel SHALL have at most one request in flight. A newer state SHALL wait for that request's
reply and then be sent, and no reply SHALL replace local state newer than what that request sent.

#### Scenario: Two saves in a row
- **WHEN** the user edits bulletin subscriptions twice within one save's round trip
- **THEN** the second edit stays on screen and is saved after the first reply
