# Spec Delta

## Purpose

How the backend collects Moodle course announcements, classifies them, extracts course changes,
make-up classes and exams, decides which extracted changes may reach `course_changes`, and what
operators see and decide in the portal.

## ADDED Requirements

### Requirement: Poll scope

The backend SHALL poll the news forum of each current-term Moodle course that has at least one
eligible holder: a TigerDuck user enrolled in that Moodle course, with an active Moodle credential and
a device the sync worker would sync for. It SHALL poll only while Moodle traffic is allowed, the same
rule sync jobs follow (the maintenance window and an operator's manual suspend).

#### Scenario: Maintenance window
- **WHEN** the time is 02:30 Asia/Taipei
- **THEN** no course announcement request is sent to Moodle

#### Scenario: Manual suspend
- **WHEN** an operator has suspended Moodle traffic in the portal
- **THEN** no course announcement request is sent until the suspension ends

#### Scenario: Holder turned sync off
- **WHEN** the only enrolled user of a course has no device the sync worker would sync for
- **THEN** the course is not polled with that user's token

### Requirement: Token holders

A poll SHALL use one eligible holder's token. When Moodle rejects the token or refuses access to the
course, the next poll of that course SHALL use another eligible holder. Polling SHALL NOT mark a
credential invalid; that stays with the sync job.

#### Scenario: Token stops working
- **WHEN** the token used for a course is rejected
- **THEN** the credential is left as it is and the next poll of the course uses another eligible
  holder

#### Scenario: Holder dropped the course
- **WHEN** Moodle refuses the course to the holder whose token was used
- **THEN** the next poll of the course uses another eligible holder

### Requirement: Poll interval

Each course SHALL be due again after an interval set by its most recent announcement: 15 minutes
when the last one is under 7 days old, 3 hours from 7 to 14 days, 12 hours beyond 14 days, and once
a day when the course has none.

#### Scenario: Active course
- **WHEN** a course's latest announcement was posted 2 days ago and it was polled 15 minutes ago
- **THEN** it is due and is polled in the next budget slot

#### Scenario: Quiet course
- **WHEN** a course has never posted and was polled 6 hours ago
- **THEN** it is not polled again until 24 hours after that poll

### Requirement: Poll budget

Polling SHALL use its own request budget of at most 20 Moodle requests a minute, separate from the
sync job budget and counted on its own metric, and SHALL take the most overdue courses first. Because
both budgets share one Moodle limit, polling SHALL pause while either budget is paused for a rate
limit, and a rate limit polling meets SHALL pause both.

#### Scenario: Budget short
- **WHEN** more courses are due than the budget allows in a minute
- **THEN** the courses due longest are polled first and the rest wait for the next minute

#### Scenario: Rate limited
- **WHEN** Moodle answers a course announcement request with a rate-limit error
- **THEN** polling and sync jobs both pause for the rate-limit period

### Requirement: Announcement versions

A course announcement SHALL be identified by its Moodle discussion and first-post ids, and only the
first post of a discussion SHALL be read. An announcement with a later `modified` time than the stored
one SHALL replace the stored version and repeat classification and extraction; an equal or earlier
one SHALL change nothing, whichever of polling or the import stores first. One announcement SHALL
belong to every course code its Moodle course lists (merged sections).

#### Scenario: Edited announcement
- **WHEN** a stored announcement is polled with a later `modified` time
- **THEN** its text, classifier scores and extraction are replaced by those of the new version

#### Scenario: Older copy arrives later
- **WHEN** the import brings a version older than the one polling already stored
- **THEN** the stored version and its extraction stay as they are

#### Scenario: Replies
- **WHEN** a discussion has replies
- **THEN** only its first post is stored and classified

### Requirement: Newer versions retire older results

Storing a newer version SHALL at once supersede the pending items and unfinished extractions of older
versions, whatever the new version's route.

#### Scenario: Edit no longer about classes
- **WHEN** an announcement with a pending cancellation is edited and the new version is not sent to
  the LLM
- **THEN** the pending cancellation is superseded and can no longer be approved

### Requirement: Stored announcement fields

Stored announcements SHALL keep the title and the converted text the classifier returns, the post and
edit times, the attachment flag, the Moodle group and visibility start, and the course codes, and
SHALL NOT keep author names. The raw subject and message SHALL be kept only until the announcement is
classified. Stored announcements SHALL be kept indefinitely.

#### Scenario: Classified
- **WHEN** an announcement has been classified
- **THEN** its raw subject and message are no longer stored and its converted text is

### Requirement: Who may see announcement text

Announcement text and evidence SHALL be shown only in the portal, hidden by default on each page load
like other personal data there, and SHALL NOT be served by any public or app-facing API, written to
logs, or stored in error fields.

#### Scenario: App API
- **WHEN** any `/v3` or `/v4` endpoint is called
- **THEN** no course announcement text is in the response

#### Scenario: LLM error
- **WHEN** the LLM returns output that fails the schema
- **THEN** the log line and the stored error hold an error code and no announcement text

### Requirement: Classification

Every stored announcement version SHALL receive the classifier's 20 label scores, the labels at or
above the threshold the service reports, and the model release the service reports. When the service
cannot be reached, the announcement SHALL be stored with its raw subject and message and classified on
a later poll tick.

#### Scenario: Classifier down
- **WHEN** the classifier service does not answer
- **THEN** the announcement is still stored and is classified once the service answers again, without
  fetching it from Moodle again

### Requirement: When an announcement goes to the LLM

An announcement version SHALL be sent to the LLM for extraction when any of `exam_info`,
`exam_change`, `exam_seating`, `exam_review`, `exam_prep`, `grade_release`, `class_cancel` or
`class_change` scores in [0.10, 0.90), or when any of `class_cancel`, `class_change`, `exam_info`,
`exam_change` or `exam_seating` scores 0.90 or more. Other announcements SHALL be stored as not sent.

#### Scenario: Confident cancellation
- **WHEN** `class_cancel` scores 0.98 and every other exam or class label scores below 0.10
- **THEN** the announcement is sent to the LLM to extract the date

#### Scenario: Materials only
- **WHEN** `materials` scores 0.97 and every exam or class label scores below 0.10
- **THEN** the announcement is not sent and is listed as not sent

### Requirement: Extraction output

The LLM SHALL return, under a JSON schema the server enforces, the exam and class labels that apply,
course changes in the form `course_changes` stores, dates stated to be held as usual, make-up classes,
exams, and whether it is certain. Every fact SHALL carry one evidence span quoted from the text it was
given, dates SHALL be resolved against the post time in Asia/Taipei, and each extraction SHALL record
the model that produced it.

#### Scenario: Relative date
- **WHEN** an announcement posted on Friday 2026-11-13 says class is cancelled next Thursday
- **THEN** the extracted cancellation is dated 2026-11-19

#### Scenario: Held as usual
- **WHEN** an announcement only says class is held as usual next Monday (labelled `class_change` by
  the classifier's guide)
- **THEN** the extraction has no course change and lists that Monday as held as usual

### Requirement: Extraction failures

An extraction that fails after the client's retries SHALL be retried on up to 3 later ticks with
growing intervals and then shown as failed; one interrupted by a restart SHALL be retried the same
way. An operator SHALL be able to queue any announcement for extraction again, and a command SHALL
queue every current-term announcement the route rule selects, for a model change.

#### Scenario: Restart during extraction
- **WHEN** the backend restarts while an extraction is waiting on the LLM
- **THEN** that extraction is attempted again on a later tick and counts as one failed attempt

### Requirement: Stored extraction results

A result SHALL be stored only if the announcement is still at the version that was sent, and each
stored result SHALL supersede the pending items of every earlier extraction of the announcement.

#### Scenario: Re-extracted with another model
- **WHEN** an announcement with pending items is extracted again at the same version
- **THEN** its earlier pending items become superseded and only the new items can be approved

#### Scenario: Extraction keeps failing
- **WHEN** extraction of an announcement fails on its first attempt and on 3 later ticks
- **THEN** the announcement is shown as failed with a re-extract action, and no further attempt is
  made until an operator queues one

#### Scenario: Edited during extraction
- **WHEN** an announcement is edited while its previous version is being extracted
- **THEN** the previous version's result is discarded and the new version is extracted

### Requirement: Review items

Each extraction SHALL turn into review items, one per course change and course code, each with an
action: add (no applied change of this announcement covers it), replace (it differs from this
announcement's applied change on the same day and kind), or remove (an applied change of this
announcement that the latest extraction lacks, or whose day this or a later announcement of the
course says is held as usual).

#### Scenario: Corrected date
- **WHEN** an applied cancellation on 11/18 is followed by an edit that moves it to 11/25
- **THEN** a remove item for 11/18 and an add item for 11/25 wait for review, and the 11/18 change
  stays until an operator approves its removal

#### Scenario: Withdrawn cancellation
- **WHEN** a cancellation on 11/18 was applied and a later announcement of the course says 11/18 is
  held as usual
- **THEN** a remove item for the 11/18 change waits for review

### Requirement: Later announcements retire earlier pending items

When an announcement is stored with a held-as-usual date, pending items of earlier announcements of
the same course for that day SHALL be superseded; when it is stored with a course change, pending
items of earlier announcements of the same course for that day and kind SHALL be superseded.

#### Scenario: Withdrawn before review
- **WHEN** a cancellation on 11/18 from one announcement waits for review in shadow mode and a later
  announcement of the course says 11/18 is held as usual
- **THEN** the pending cancellation is superseded and can no longer be approved

### Requirement: Skipped codes and informational facts

A course code that no TigerDuck student has a schedule for SHALL get no item and SHALL be listed as
skipped. Make-up classes and exams SHALL be shown with the announcement and SHALL NOT be review items
or change `course_changes`.

#### Scenario: Exam
- **WHEN** an extraction holds a midterm date
- **THEN** the exam is shown with the announcement and nothing waits for review

#### Scenario: Merged sections
- **WHEN** an announcement belongs to two course codes and only one has TigerDuck students with a
  schedule
- **THEN** one add item exists, for that code, and the other code is listed as skipped

### Requirement: Checks before an add item applies

An add item SHALL pass only when every check passes. The checks SHALL test that the evidence occurs
verbatim in the text given to the LLM, the dates fall within the term and on class days of the course,
a weekday the text states matches the date, the change fits the `course_changes` rules including
clashes with existing changes, the classifier and the LLM agree on cancellation versus other change,
the LLM marked it certain, and the post is visible to the whole course from its post time.

#### Scenario: Not a class day
- **WHEN** an extracted change falls on a Thursday and the course meets Monday and Wednesday
- **THEN** the class-day check fails and the item waits for review

#### Scenario: Clash with an existing change
- **WHEN** an operator's room change for 11/1 to 11/30 covers the day of an extracted room change
- **THEN** the item waits for review and shows the existing change, which is not altered

#### Scenario: Group post
- **WHEN** the post is limited to one Moodle group
- **THEN** its items wait for review

### Requirement: Shadow mode

Automatic apply SHALL be off unless the `TIGERDUCK_COURSE_ANNOUNCEMENTS_AUTO_APPLY` setting is true.
With it off, every item SHALL wait for review, and an add item that passes every check SHALL be marked
as such.

#### Scenario: Shadow mode
- **WHEN** automatic apply is off and a cancellation passes every check
- **THEN** it waits for review, marked as passing all checks, and `course_changes` is unchanged

### Requirement: Automatic apply

With automatic apply on, an add item SHALL be written to `course_changes` with the announcement as its
source, `course-announcements` as the actor and an audit entry, only when every add item of the same
announcement passes every check, the announcement has no replace or remove item, and no item of this
announcement for that course, day and kind was rejected or removed before. Replace and remove items
SHALL always wait for review.

#### Scenario: Corrected date with automatic apply on
- **WHEN** automatic apply is on and an edit moves an applied cancellation from 11/18 to 11/25
- **THEN** the remove item for 11/18 and the add item for 11/25 both wait for review

#### Scenario: Automatic apply on
- **WHEN** automatic apply is on and a cancellation passes every check
- **THEN** a cancelled change for that day is written with the announcement as its source

#### Scenario: One fact of the announcement fails
- **WHEN** automatic apply is on and one of an announcement's two add items fails a check
- **THEN** both wait for review

#### Scenario: Operator deleted an automatic change
- **WHEN** an operator deleted an automatically applied change and the announcement is extracted again
- **THEN** the same change waits for review instead of applying again

### Requirement: Review actions

An operator SHALL be able to approve a pending item (add writes the change, replace updates the
applied change, remove deletes it, each with the announcement as source and an audit entry), edit an
add or replace item in the course-changes editor before approving it, or reject it with an optional
reason, which is kept. An action SHALL apply only to an item that is still pending, and an edit or
deletion of a sourced change in Course changes SHALL be recorded on its item.

#### Scenario: Approve
- **WHEN** an operator approves a pending room change
- **THEN** the room change is in `course_changes` for the course, linked to the announcement, and the
  audit log names the operator

#### Scenario: Double approve
- **WHEN** an operator approves an item twice, from two tabs
- **THEN** the change is written once and the second request is refused

#### Scenario: Stale page
- **WHEN** an operator approves an item that a newer version of the announcement replaced
- **THEN** the request is refused and nothing is written

#### Scenario: Reject
- **WHEN** an operator rejects a pending cancellation with a reason
- **THEN** nothing is written to `course_changes` and the rejection and reason stay with the item

### Requirement: Items already past

An item, make-up class or exam whose dates have all passed in Asia/Taipei SHALL be recorded as past,
whether at extraction or later while it waits, and SHALL NOT wait for review or apply.

#### Scenario: Backfill of an old cancellation
- **WHEN** the history import extracts a cancellation dated three weeks before the import
- **THEN** the item is listed as past and is not in the review queue

#### Scenario: Waited too long
- **WHEN** a pending cancellation's date passes while it waits for review
- **THEN** on the next day it is listed as past and leaves the review queue

### Requirement: History import

A one-time import SHALL load every past course announcement from a local export that holds no author
names, through the same storage and classification path as polling, safely alongside polling and when
run again. Announcements of the current term that meet the LLM rule SHALL be extracted, after any
pending bulletin processing; no older announcement SHALL be sent to the LLM.

#### Scenario: Import run twice
- **WHEN** the import runs again with the same export
- **THEN** nothing is stored again and nothing is queued again

#### Scenario: Author field in the export
- **WHEN** a record of the export carries an author field
- **THEN** the import stops before storing anything
