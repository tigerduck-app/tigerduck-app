# Spec Delta

## Purpose

Give every TigerSync edit a time that both apps and the backend compare the same way: a hybrid
logical clock that follows the device clock, never runs behind the server time the device has
seen, and cannot be pushed far ahead by a wrong device clock.

## ADDED Requirements

### Requirement: Clock values are integer microseconds
A TigerSync clock value SHALL be a signed 64-bit integer counting microseconds since
1970-01-01T00:00:00Z. One tick is one microsecond. On the wire it SHALL be a JSON integer, and
the backend SHALL store it exactly in its microsecond timestamp columns.

#### Scenario: Round trip
- **WHEN** a client sends the clock value 1792888799123456
- **THEN** the backend stores 2026-10-25T00:39:59.123456Z and returns 1792888799123456 for it

#### Scenario: Zero is the oldest value
- **WHEN** a client sends the clock value 0
- **THEN** the backend treats it as older than every value it has stored

### Requirement: A device stamps each user edit when it is made
When the user makes an edit, the device SHALL stamp it with the larger of its current time, the
last server clock value it has seen and the last value it issued, plus one tick, and SHALL record
that value as the last it issued. Two edits on one device SHALL never get the same value.

#### Scenario: Device clock behind the server
- **WHEN** the device clock reads 10:00:00 and the last server clock value it saw is 10:05:00
- **THEN** the edit is stamped 10:05:00 plus one microsecond

#### Scenario: Two edits in the same microsecond
- **WHEN** the user makes two edits before the device clock advances
- **THEN** the second edit's value is the first edit's value plus one microsecond

### Requirement: Only user edits are stamped
A view appearing, a school or Moodle fetch, an automatically assigned course colour, a roster
upload and a snapshot applied from the server SHALL NOT produce a clock value or change a
stamped value on the device.

#### Scenario: Automatic colour
- **WHEN** the app assigns a palette colour to a course the user never coloured
- **THEN** no clock value is issued and the colour reaches the backend only as an oldest value

### Requirement: The clock state survives relaunch
Each device SHALL persist the last value it issued and the last server value it saw, and SHALL
read them back before stamping the first edit after a launch. Signing out SHALL NOT reset them.

#### Scenario: Relaunch with a slow clock
- **WHEN** the app relaunches on a device whose clock is now behind the last value it issued
- **THEN** the next edit is stamped after that last issued value

### Requirement: The backend reports its clock on every response
Every response under `/v3` SHALL carry the header `X-TigerSync-Clock` with the backend's
current time as a clock value. A client SHALL raise its last seen server value to that header
and to every clock value in a snapshot or write response it reads, and never lower it.

#### Scenario: Learning from a snapshot
- **WHEN** a snapshot holds a field stamped later than the response header
- **THEN** the client's last seen server value becomes that field's stamp

#### Scenario: Error response
- **WHEN** the backend answers 404 or 422
- **THEN** the response still carries `X-TigerSync-Clock`

### Requirement: The backend clamps clock values from the future
The backend SHALL replace a received clock value later than its own time plus five seconds with
its own time plus five seconds before comparing or storing it. It SHALL keep earlier values,
however old, unchanged.

#### Scenario: Device clock a day ahead
- **WHEN** an edit arrives stamped one day after the backend's time
- **THEN** it is compared and stored as the backend's time plus five seconds

#### Scenario: Offline edit from last week
- **WHEN** an edit stamped a week ago arrives
- **THEN** it is compared with its own stamp

### Requirement: Queued edits keep their queue time
An edit that was waiting in a device's outbox before the update that introduces the clock SHALL
be sent with the time it was queued, converted to a clock value, rather than restamped.

#### Scenario: Upgrade with a queued mark
- **WHEN** a mark queued at 09:00 is still in the outbox after the app updates at 12:00
- **THEN** it is sent stamped 09:00
