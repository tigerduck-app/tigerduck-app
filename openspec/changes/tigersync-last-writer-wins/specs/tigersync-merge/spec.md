# Spec Delta

## Purpose

Decide every disagreement between a user's devices the same way on the backend and in both
apps: per item and per field, the edit made last wins, deletions and resets win the same way,
and nobody is asked to choose.

## ADDED Requirements

### Requirement: Each synced field resolves on its own
The backend SHALL resolve these independently: an assignment's mark, an assignment's note, a
course's colour, a course's name in each locale, a course's ignore-assignments setting, a
course's membership in the user's timetable, and a holiday's notify setting. An edit to one
SHALL never change another.

#### Scenario: Colour and name from two devices
- **WHEN** a phone sets a course's colour and a Mac, later and without having synced, renames it
- **THEN** the course keeps both the phone's colour and the Mac's name

#### Scenario: Two locales
- **WHEN** one device sets the Chinese name and another, earlier, sets the English name
- **THEN** both names are kept

### Requirement: The later edit wins
An edit SHALL replace the stored value only when its clock value is later than the
stored value's. On equal clock values the stored value SHALL stay. A field the backend holds no
stamp for SHALL take any stamped edit, even one stamped 0.

#### Scenario: Offline edit arrives late
- **WHEN** a mark stamped 09:00 arrives after a mark stamped 09:30 for the same assignment
- **THEN** the 09:30 mark stays

#### Scenario: Equal stamps
- **WHEN** two edits with the same clock value arrive for one field
- **THEN** the first one stored stays

### Requirement: Compare and write are atomic per user
The backend SHALL compare and write every TigerSync edit of a user while holding that user's
sync lock, so concurrent requests are applied as if one after another and the stored value is
always the latest-stamped edit received.

#### Scenario: Two requests at once
- **WHEN** two devices send a colour for the same course at the same moment, stamped 10:00 and 10:01
- **THEN** the stored colour is the 10:01 one whichever request the backend takes first

### Requirement: Same content is not a conflict
An edit whose value equals the stored value SHALL raise the stored stamp to the edit's stamp if
the edit's is later, and SHALL otherwise change nothing. Neither case SHALL add a change log
entry, queue a sync push or cause any prompt.

#### Scenario: Same colour twice
- **WHEN** a course is red stamped 10:00 and another device sends red stamped 10:05
- **THEN** the colour stays red stamped 10:05 and no change log entry is written

#### Scenario: Later stamp protects the value
- **WHEN** after that a blue colour stamped 10:03 arrives
- **THEN** the colour stays red

### Requirement: Writes report the winner
A write response SHALL return, for every field the request named, the value and clock value the
backend holds after the request and whether the request's value was applied. A refused edit
SHALL answer 200, not an error.

#### Scenario: Refused edit
- **WHEN** a client sends an ignore mark older than the stored "done" mark
- **THEN** the response says the edit was not applied and returns "done" with its stamp

### Requirement: Only real changes notify other devices
The backend SHALL add a change log entry and queue a sync trigger push only when an edit
changes a stored value. A refused edit and a same-content edit SHALL do neither.

#### Scenario: Refused edit
- **WHEN** an edit is refused as older
- **THEN** the user's revision does not change and no sync trigger push is queued

### Requirement: A cleared mark stays as a stamped none
Clearing an assignment mark SHALL store the mark `none` with the clear's stamp instead of
deleting the record, so a mark stamped before the clear is refused when it arrives later.

#### Scenario: Late ignore after a clear
- **WHEN** a mark is cleared at 10:00 and an ignore stamped 09:50 arrives afterwards
- **THEN** the assignment stays unmarked

### Requirement: Hiding a course binds every device and the school roster
A hide stamped later than the course's last add, hide, removal and reset SHALL remove the
course from the user's timetable on every device. A roster upload SHALL NOT bring a hidden
course back; only a later add can.

#### Scenario: Roster lists a hidden course
- **WHEN** a course is hidden and a device then uploads a fresh roster that lists it
- **THEN** the course stays hidden

#### Scenario: Delete queued before a re-add elsewhere
- **WHEN** a phone hides a course at 09:00 offline, a Mac adds it back at 09:30, and the phone's hide arrives at 10:00
- **THEN** the course stays in the timetable

### Requirement: Adding a course wins over an earlier hide
An add stamped later than the course's last add, hide, removal and reset SHALL put the course in
the user's timetable on every device and retire the earlier tombstone. An older add SHALL be
refused and SHALL leave the stored add stamp unchanged.

#### Scenario: Re-add after delete
- **WHEN** a course hidden at 09:00 is added at 09:10
- **THEN** every device shows the course after its next sync

#### Scenario: Older add arriving late
- **WHEN** an add stamped 10:00 is stored, an add stamped 09:00 arrives, and then a hide stamped 09:30
- **THEN** the course stays in the timetable

### Requirement: Removing a hand-added course leaves the roster in charge
Removing a course the user added by hand SHALL clear the user's choice for that course with a
stamped tombstone that refuses older adds and hides but does not bind roster uploads. A roster
that lists the course SHALL show it and SHALL keep the tombstone's stamp, whichever of the
removal and the roster arrives first.

#### Scenario: Removal arriving after the roster
- **WHEN** a hand-added course is removed at 10:00 on an offline device, another device uploads a roster that lists it, and the removal then arrives
- **THEN** the course shows from the roster

#### Scenario: Enrolled later
- **WHEN** a hand-added course is removed and the student later enrolls, so the roster lists it
- **THEN** the course shows from the roster

#### Scenario: Older hide after the roster lists a removed course
- **WHEN** a hand-added course is removed at 10:00, a roster then lists it, and a hide stamped 09:00 arrives
- **THEN** the hide is refused and the course shows from the roster

### Requirement: A term reset clears the user's choices for that term
A term reset SHALL clear the user's adds, hides, removals, colours, names and ignore settings
for that term's courses that are stamped at or before it, SHALL keep those stamped after it,
and SHALL refuse any such edit stamped at or before the reset. A reset older than the term's stored
reset SHALL change nothing. A reset of every term SHALL do the same for all terms. The school
roster SHALL stay.

#### Scenario: Reset arriving last
- **WHEN** a reset stamped 09:00 arrives after a hide of one course and a colour of a school course, both stamped 10:00
- **THEN** the hide and the colour stay, and the term's other choices are cleared

#### Scenario: Edit stamped at the reset
- **WHEN** a term reset stamped 09:00 is stored and a colour of one of its courses stamped 09:00 arrives
- **THEN** the colour is refused

#### Scenario: Older reset
- **WHEN** a term reset stamped 10:00 is stored and a reset stamped 09:00 arrives
- **THEN** the stored reset stays at 10:00 and nothing is cleared

#### Scenario: Stale device after a reset
- **WHEN** a term is reset at 10:00 and a device that last synced at 09:00 sends a hide stamped 08:30
- **THEN** the hide is refused

#### Scenario: Roster after a reset
- **WHEN** any device uploads the term's roster after the reset
- **THEN** the roster's courses show on every device

### Requirement: A reset clears the hand-added courses it covers
A term reset SHALL clear a hand-added course whose add is stamped at or before it, with the
course's colour and name, even those stamped after the reset.

#### Scenario: Newer colour on an older hand-add
- **WHEN** a course is added by hand at 08:00, the term is reset at 09:00 on an offline device, and a colour of that course stamped 10:00 arrives before the reset
- **THEN** the reset clears the course and its colour

### Requirement: Tombstones and resets are kept
The backend SHALL keep every course tombstone and reset marker, with its stamp and kind, for
as long as the account syncs courses, and the snapshot SHALL return all of them, not only the
last 30 days.

#### Scenario: Tombstone older than 30 days
- **WHEN** a course hidden 40 days ago is in a roster a device uploads
- **THEN** the course stays hidden and the snapshot still lists its tombstone

### Requirement: The snapshot carries every stamp
`/v3/sync/full` SHALL return, beside each synced field, tombstone and reset marker, its clock
value as an integer, `null` for a field the backend holds no stamp for.

#### Scenario: Course override
- **WHEN** a device reads a course override with a colour and a Chinese name
- **THEN** the row carries the colour's clock value and a clock value for the Chinese name

### Requirement: Released apps keep working
A request without the `X-TigerSync-Protocol: 2` header SHALL be served as today, except that
an edit carrying a stamp is compared by it. A single edit without a stamp (an override, a course
delete, a holiday setting) SHALL be stamped with the time it arrives; values in its bulk uploads
SHALL count as oldest.

#### Scenario: Old Android after a new iPhone
- **WHEN** an iPhone sets a colour stamped 10:00 and an app without the header sets another colour at 10:02
- **THEN** the second colour wins

#### Scenario: Old roster upload
- **WHEN** an app without the header uploads a roster carrying course colours
- **THEN** a colour is stored only for a course that has none

### Requirement: New clients send a stamp with every edit
A write carrying `X-TigerSync-Protocol: 2` SHALL carry a clock value for each edit it makes. The
backend SHALL answer 422 for such a write without one.

#### Scenario: Missing stamp
- **WHEN** a request with the protocol header patches a course colour without a clock value
- **THEN** the backend answers 422 and stores nothing

### Requirement: A client keeps unsent edits over the snapshot
Applying a snapshot, a client SHALL keep its own value for a field it has an unsent edit for,
or whose last acknowledged write answered with an `X-TigerSync-Clock` value not earlier than the
snapshot's `server_hlc`, and SHALL take the snapshot's value for every other field, including
its absence. Applying a write response, a client SHALL keep a field it edited again after the
edit the response answers.

#### Scenario: Colour removed by a hide
- **WHEN** a device's colour write is acknowledged, the course is then hidden elsewhere, and a snapshot with a later `server_hlc` lacks the colour
- **THEN** the device drops the colour

#### Scenario: Edit while a write is in flight
- **WHEN** a red colour is being sent and the user picks blue before the response arrives
- **THEN** the device keeps blue and sends it

#### Scenario: Edit during a pull
- **WHEN** the user marks an assignment while a snapshot is downloading
- **THEN** the mark stays after the snapshot is applied and is sent

#### Scenario: Snapshot read before an acknowledged write
- **WHEN** a snapshot fetched before a colour write landed is applied after the write's response
- **THEN** the device keeps the acknowledged colour

### Requirement: Edits made while sync is off are kept and sent later
A device SHALL keep each user edit, stamped, while TigerSync or that edit's category is off,
and SHALL send it once both are on. The comparison then decides it like any other edit.
Signing out SHALL discard the unsent edits.

#### Scenario: Colour changed with TigerSync off
- **WHEN** a course colour is changed at 09:00 with TigerSync off and it is turned on at 12:00
- **THEN** the colour is sent stamped 09:00 and wins only over colours stamped before 09:00

### Requirement: Nobody is asked to choose between devices
The apps SHALL NOT show a per-item conflict alert after a sync. The comparison decides every
field.

#### Scenario: Two devices marked one assignment differently
- **WHEN** one device marked an assignment done and another ignored it
- **THEN** both devices show the later mark and no alert appears

### Requirement: Turning sync on merges without a prompt
Turning TigerSync or one of its categories on SHALL send the device's stamped unsent edits and
apply the snapshot as any sync does, without asking whether to keep this device's or the
server's data.

#### Scenario: Category turned back on
- **WHEN** course names sync is turned back on with a name edited locally while it was off
- **THEN** the edit is sent and the later name wins on every device, with no prompt

### Requirement: Existing server data is migrated in place
The migration SHALL keep every stored stamp, SHALL stamp a stored value that has none with its
row's last update time, SHALL stamp each Chinese and English name with the name's existing stamp,
and SHALL turn the reset tombstones of a term into that term's reset marker at their latest time.

#### Scenario: Colour without a stamp
- **WHEN** a course override row holds a colour but no colour stamp
- **THEN** after the migration the colour's stamp is the row's last update time

### Requirement: Existing device data counts as oldest
After the update, a stored local value without a stamp SHALL count as oldest. For a category
the device has synced before, such values SHALL NOT be sent and the snapshot SHALL replace them.
For a category it never synced, they SHALL be sent stamped 0, filling only fields the backend
holds nothing for.

#### Scenario: Upgraded device that synced marks before
- **WHEN** an upgraded device holds a mark the server no longer has
- **THEN** the mark is dropped on that device at the next sync

#### Scenario: First sync of a category
- **WHEN** a device that never synced course colours turns them on
- **THEN** its colours fill the courses the backend holds no colour for and change no other
