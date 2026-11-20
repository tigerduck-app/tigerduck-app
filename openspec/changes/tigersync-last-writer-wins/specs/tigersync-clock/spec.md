# Spec Delta

## Purpose

Give every TigerSync edit a time that both apps and the backend compare the same way: the
backend's own time when the edit arrives less the edit's age, which the device measures, so a
wrong device clock cannot move an edit on the backend's time line.

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

### Requirement: The backend stamps each user edit from its age
A device SHALL send each user edit with `age_ms`, the milliseconds from the edit to this send,
and SHALL NOT send a device time. The backend SHALL stamp the edit at its own time when the
request arrives less the age, the age clamped to between 0 and 365 days. No code SHALL compare a
device time with a backend time.

#### Scenario: Device clock an hour ahead
- **WHEN** a device whose clock runs an hour ahead sends an edit made two seconds before the send
- **THEN** the backend stamps it two seconds before the request arrived

#### Scenario: Retry after a lost response
- **WHEN** an edit is stored but its response is lost, another device then changes the same field, and the first device sends the edit again
- **THEN** the retry is stamped at about the first send's stamp, loses, and the other device's value stays

### Requirement: A device measures an edit's age at every send
A device SHALL measure the age again for every send and every retry. When the edit and the send
happen in the same boot it SHALL use the clock since boot, which counts sleep and does not move
when the time is set; otherwise it SHALL use the difference of the wall clock. A negative age
SHALL be sent as 0.

#### Scenario: Time set back between edit and send
- **WHEN** the user makes an edit, sets the device time back an hour, and the edit is sent ten seconds later in the same boot
- **THEN** it is sent with an age of ten seconds

#### Scenario: Restart before the send
- **WHEN** an edit is queued at 09:00, the device restarts, and the edit is sent at 09:30 by the wall clock
- **THEN** it is sent with an age of thirty minutes

### Requirement: An edit made during an earlier send of its field ages from that send's answer
When the answer to an earlier send of the same field arrives after an edit is made, the device
SHALL measure that edit's age from the answer's arrival, so the edit is stamped after the
earlier one whatever the two network delays.

#### Scenario: Second colour while the first is in flight
- **WHEN** the user picks red, then blue while red's request is in flight, and red's answer arrives after blue was picked
- **THEN** blue is sent with its age counted from red's answer and the backend keeps blue

### Requirement: Only user edits are stamped
A view appearing, a school or Moodle fetch, an automatically assigned course colour, a roster
upload and a snapshot applied from the server SHALL NOT produce a clock value or change a
stamped value on the device.

#### Scenario: Automatic colour
- **WHEN** the app assigns a palette colour to a course the user never coloured
- **THEN** no clock value is issued and the colour reaches the backend only as an oldest value

### Requirement: The backend reports its clock on every response
Every response under `/v3` and `/v4` SHALL carry the header `X-TigerSync-Clock` with the
backend's current time as a clock value, read after the request's writes commit. A snapshot's
`server_hlc` SHALL be read before its first query.

#### Scenario: Snapshot after a write
- **WHEN** a snapshot's `server_hlc` is later than the header of a write's response
- **THEN** the snapshot includes that write

#### Scenario: Error response
- **WHEN** the backend answers 404 or 422
- **THEN** the response still carries `X-TigerSync-Clock`

### Requirement: The backend refuses clock values from the future
Until every client sends `age_ms`, the backend SHALL refuse an `hlc` later than its own time plus
five seconds with `409 clock_ahead`, writing nothing, and SHALL keep earlier values, however
old, unchanged. An edit sent with `age_ms` SHALL never be refused as ahead.

#### Scenario: Device clock a day ahead
- **WHEN** an edit arrives stamped one day after the backend's time
- **THEN** it is refused with `clock_ahead` and the stored value stays

#### Scenario: Offline edit from last week
- **WHEN** an edit stamped a week ago arrives
- **THEN** it is compared with its own stamp

### Requirement: Queued edits keep their edit time
An edit waiting in a device's outbox SHALL keep the time it was made across relaunches, and one
queued before the update that sends `age_ms` SHALL age by the wall clock from the time it was
queued.

#### Scenario: Upgrade with a queued mark
- **WHEN** a mark queued at 09:00 is still in the outbox after the app updates, and is sent at 12:00
- **THEN** it is sent with an age of three hours
