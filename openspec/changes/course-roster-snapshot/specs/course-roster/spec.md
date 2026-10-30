## Purpose

Keep the backend's record of which school courses a student is enrolled in each term equal to the
school's roster, and make every device and backend job read enrollment from that record.

## ADDED Requirements

### Requirement: A device reports a term as a roster only from an authoritative source
A course upload SHALL name a term in `roster_terms` only when its courses for that term are the
school's complete roster: course selection served the term in this fetch, or a past term was
rebuilt from the final transcript. Courses from the cache, a running term's transcript or Moodle
SHALL NOT be reported as a roster.

#### Scenario: Course selection serves the term
- **WHEN** a device fetches the current term and course selection answers with its courses
- **THEN** the device uploads those courses with the term in `roster_terms`

#### Scenario: Course selection does not answer
- **WHEN** course selection gives nothing for the term and the device builds the list from its cache, the transcript or Moodle
- **THEN** the upload carries no `roster_terms`

#### Scenario: The roster answer is empty
- **WHEN** course selection's answer for the term lists no course
- **THEN** the device sends no roster for that term

### Requirement: A roster drops the school courses it does not list
For each term in an upload's `roster_terms`, the backend SHALL set every school course of that
term that the upload does not list to `dropped`, unless the user added that course by hand. It
SHALL leave other terms, hand-added courses and courses the user hid unchanged.

#### Scenario: A course leaves the roster
- **WHEN** the backend holds courses A, B and C for term T and an upload lists A and B with T in `roster_terms`
- **THEN** C becomes `dropped` and A and B are `enrolled`

#### Scenario: A hand-added course is off the roster
- **WHEN** the user added course H by hand and a roster for its term does not list H
- **THEN** H stays `enrolled`

#### Scenario: Another term
- **WHEN** an upload names only term T in `roster_terms`
- **THEN** no course of any other term changes its enrollment

#### Scenario: A hidden course
- **WHEN** the user hid course X, so X has a tombstone, and a roster for its term lists X or leaves it out
- **THEN** the roster neither drops X nor brings it back

### Requirement: A roster brings a listed course back
For each term in `roster_terms`, the backend SHALL set every school course the upload lists, other
than one the user hid, to `enrolled`, including one that was `dropped`.

#### Scenario: A student re-enrolls
- **WHEN** course C is `dropped` and a roster for its term lists C
- **THEN** C becomes `enrolled`

### Requirement: An empty roster changes nothing
A roster term for which the upload lists no course SHALL change no enrollment.

#### Scenario: Empty roster term
- **WHEN** an upload names term T in `roster_terms` and lists no course of T
- **THEN** every course of T keeps its enrollment

### Requirement: Other uploads leave enrollment alone
An upload SHALL NOT change the enrollment of a course it lists outside its roster terms, except
that a hand-add SHALL set its course to `enrolled`. A course an upload creates SHALL start as
`enrolled`.

#### Scenario: A stale list names a dropped course
- **WHEN** course C is `dropped` and an upload without `roster_terms` lists C
- **THEN** C stays `dropped`

#### Scenario: A hand-add of a dropped course
- **WHEN** course C is `dropped` and the user adds C by hand
- **THEN** C becomes `enrolled`

#### Scenario: A released app uploads
- **WHEN** an app that does not know `roster_terms` uploads its list
- **THEN** no course's enrollment changes, and courses new to the backend are `enrolled`

### Requirement: Devices treat a dropped course as absent
An app SHALL NOT show a course whose backend row is `dropped` unless the user added it by hand
on that device, and SHALL remove such a course it merged from the backend earlier. Live
Activities, class reminders and widgets SHALL NOT be built from it.

#### Scenario: A device that did not see the drop
- **WHEN** another device's roster dropped course C and this device syncs
- **THEN** this device's class table does not show C and it files no Live Activity for C

#### Scenario: A copy merged earlier
- **WHEN** a device merged C from the backend before C was dropped
- **THEN** after its next sync C is gone from its class table

### Requirement: The backend asks for a stale roster
`/v3/sync/full` SHALL list the current term in `roster_requests` when no upload with that term in
`roster_terms` arrived for the user in the last 7 days. Otherwise `roster_requests` SHALL be empty.

#### Scenario: No recent roster
- **WHEN** the user's last roster for the current term arrived 8 days ago, or never
- **THEN** the snapshot's `roster_requests` lists the current term

#### Scenario: A recent roster
- **WHEN** a roster for the current term arrived yesterday
- **THEN** `roster_requests` is empty

### Requirement: A device answers a roster request
An app that finds a term in `roster_requests` SHALL fetch that term from course selection afresh
and, if course selection serves it with a non-empty list, upload it with the term in
`roster_terms` even when the list did not change since its last upload.

#### Scenario: Unchanged roster on request
- **WHEN** the snapshot requests term T and course selection returns the same courses the device uploaded before
- **THEN** the device uploads them again with T in `roster_terms`

#### Scenario: Course selection unavailable on request
- **WHEN** the snapshot requests term T and course selection does not answer
- **THEN** the device uploads no roster, and the request stays until a roster arrives

### Requirement: Backend jobs read enrolled courses only
Every backend job that reads a student's courses to send class reminders, build a class table or
resolve course changes SHALL read only `enrolled` courses.

#### Scenario: Class reminders
- **WHEN** a course is `dropped`
- **THEN** the class reminder scan files no reminder for it and cancels any it filed before
