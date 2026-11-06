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

### Requirement: A device ahead of the backend caps its stamps
A device SHALL take its current time as no later than its estimate of the backend's time plus
five seconds, the estimate being the last `X-TigerSync-Clock` value it heard plus the device
time elapsed since. A device that has not heard the backend SHALL stamp uncapped.

#### Scenario: Device clock a minute ahead
- **WHEN** the device clock reads 10:01:00 and it heard the backend's 10:00:00 at that moment
- **THEN** the edit is stamped 10:00:05 plus one microsecond

#### Scenario: Retry after a lost response
- **WHEN** a device whose clock runs a minute ahead makes an edit, the write is stored but its response is lost, another device then changes the same field, and the first device sends the edit again
- **THEN** the retry loses and the other device's value stays

### Requirement: A device re-stamps an edit refused as ahead
When the backend refuses an edit with `409 clock_ahead`, the device SHALL re-stamp that edit at
the `X-TigerSync-Clock` value the refusal carries plus one tick and send it again. A device that
keeps a last issued value SHALL NOT lower it to re-stamp, unless the refusal's clock shows it more
than two minutes past the backend's limit (see the requirement on a clock past the backend's reach). A refusal whose
clock is before 2026 or from 2100 on SHALL NOT be re-stamped.

#### Scenario: Edit made before the device heard the backend
- **WHEN** a device whose clock runs a minute ahead stamps an edit before it has heard the backend, and the backend refuses the edit as ahead with its clock at 10:00:00
- **THEN** the device re-stamps it at 10:00:00 plus one microsecond and sends it again, and its last issued value stays the value it first stamped

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
current time as a clock value, read after the request's writes commit. A snapshot's
`server_hlc` SHALL be read before its first query. The client that sends a device's stamped
edits SHALL raise its last seen server value to the header of every response it reads and to
every clock value in a snapshot or write response, and never lower it but as a clock past the
backend's reach requires.

#### Scenario: Snapshot after a write
- **WHEN** a snapshot's `server_hlc` is later than the header of a write's response
- **THEN** the snapshot includes that write

#### Scenario: Learning from a snapshot
- **WHEN** a snapshot holds a field stamped later than the response header
- **THEN** the client's last seen server value becomes that field's stamp

#### Scenario: Error response
- **WHEN** the backend answers 404 or 422
- **THEN** the response still carries `X-TigerSync-Clock`

### Requirement: The backend refuses clock values from the future
The backend SHALL refuse a received clock value later than its own time plus five seconds with
`409 clock_ahead`, writing nothing. It SHALL keep earlier values, however old, unchanged.

#### Scenario: Device clock a day ahead
- **WHEN** an edit arrives stamped one day after the backend's time
- **THEN** it is refused with `clock_ahead` and the stored value stays

#### Scenario: Offline edit from last week
- **WHEN** an edit stamped a week ago arrives
- **THEN** it is compared with its own stamp

### Requirement: Queued edits keep their queue time
An edit that was waiting in a device's outbox before the update that introduces the clock SHALL
be sent with the time it was queued, converted to a clock value, rather than restamped.

#### Scenario: Upgrade with a queued mark
- **WHEN** a mark queued at 09:00 is still in the outbox after the app updates at 12:00
- **THEN** it is sent stamped 09:00

### Requirement: A client brings a clock past the backend's reach back
A header SHALL bring a client's last seen value that is more than two minutes past the header
plus five seconds back to the header, and such a last issued value back to the header plus five
seconds. A client SHALL ignore a header before 2026 or from 2100 on, and the header of a response
from another host or with a status other than 2xx or 409.

#### Scenario: Device clock set a year ahead and back
- **WHEN** a device stamps an edit while its clock is a year ahead, and a response then carries the backend's clock
- **THEN** the device's next edit is stamped at most five seconds past that clock, also after its clock is set right

### Requirement: A client moves the times it kept with a clock it brings back
When a header brings a client's last issued value back, every time the client took before then,
more than five seconds past the new value, SHALL move down by as much as that value did, keeping
its order, whether the client kept it then or stores or compares it later.

#### Scenario: Edits queued while the clock was a year ahead
- **WHEN** edits are queued while the device clock is a year ahead, the clock is set right and a response carries the backend's clock
- **THEN** a later discard drops them, and none is sent stamped more than five seconds past that clock

#### Scenario: A setting changed while a full sync's answer brings the clock back
- **WHEN** a full sync starts while the last issued value is a year ahead, its answer carries the backend's clock, and a setting is changed before the sync applies what it fetched
- **THEN** the sync keeps the changed setting
