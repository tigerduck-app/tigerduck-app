# Spec Delta

## Purpose

How the backend collects Moodle course announcements, classifies them, extracts course changes,
make-up classes and exams, decides which extracted changes may reach `course_changes`, and what
operators see and decide in the portal.

## ADDED Requirements

### Requirement: Poll scope

The backend SHALL poll the news forum of each course of the current term that has at least one
TigerDuck user with a working Moodle token, reading it with that user's token, and SHALL NOT poll
between 00:00 and 05:00 Asia/Taipei.

#### Scenario: Maintenance window
- **WHEN** the time is 02:30 Asia/Taipei
- **THEN** no course announcement request is sent to Moodle

#### Scenario: Token stops working
- **WHEN** the token used for a course is rejected as invalid
- **THEN** that credential is marked invalid as sync jobs already do, and the next poll of the course
  uses another enrolled TigerDuck user's token

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
sync job budget, and SHALL take the most overdue courses first, so a short budget delays every course
evenly.

#### Scenario: Budget short
- **WHEN** more courses are due than the budget allows in a minute
- **THEN** the courses due longest are polled first and the rest wait for the next minute

#### Scenario: Rate limited
- **WHEN** Moodle answers a course announcement request with a rate-limit error
- **THEN** course announcement polling pauses as the sync job budget does, without pausing sync jobs

### Requirement: Announcement versions

A course announcement SHALL be identified by its Moodle discussion and first-post ids. A poll SHALL
store an announcement it has not seen, and SHALL treat one whose `modified` time changed as a new
version that replaces the stored text and repeats classification and extraction. Only the first post
of a discussion SHALL be read. One announcement SHALL belong to every course code its Moodle course
lists (merged sections).

#### Scenario: Edited announcement
- **WHEN** a stored announcement is polled with a later `modified` time
- **THEN** its text, classifier scores and extraction are replaced by those of the new version

#### Scenario: Replies
- **WHEN** a discussion has replies
- **THEN** only its first post is stored and classified

### Requirement: Stored text and who may see it

Stored announcements SHALL keep the title and the converted text the classifier returns, the post and
edit times, the attachment flag and the course codes, and SHALL NOT keep author names. Announcement
text SHALL be shown only in the portal, hidden by default on each page load like other personal data
there, and SHALL NOT be served by any public or app-facing API. Stored announcements SHALL be kept
indefinitely.

#### Scenario: App API
- **WHEN** any `/v3` or `/v4` endpoint is called
- **THEN** no course announcement text is in the response

### Requirement: Classification

Every stored announcement version SHALL receive the classifier's 20 label scores and the labels at or
above the classifier's threshold, with the model release recorded. When the classifier service cannot
be reached, the announcement SHALL be stored unclassified and classified on a later poll cycle.

#### Scenario: Classifier down
- **WHEN** the classifier service does not answer
- **THEN** the announcement is still stored and is classified once the service answers again

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
course changes in the form `course_changes` stores, make-up classes, exams, and whether it is
certain. Every fact SHALL carry evidence quoted from the text, dates SHALL be resolved against the
post time in Asia/Taipei, and each extraction SHALL record the model that produced it.

#### Scenario: Relative date
- **WHEN** an announcement posted on Friday 2026-11-13 says class is cancelled next Thursday
- **THEN** the extracted cancellation is dated 2026-11-19

### Requirement: Extraction failures

An extraction that fails after the client's retries SHALL be retried on up to 3 later poll cycles
with growing intervals and then shown as failed. An operator SHALL be able to queue any announcement
for extraction again.

#### Scenario: Extraction keeps failing
- **WHEN** extraction of an announcement fails on its first attempt and on 3 later poll cycles
- **THEN** the announcement is shown as failed with a re-extract action, and no further attempt is
  made until an operator queues one

### Requirement: Checks before a course change applies

An extracted course change SHALL pass only when every check passes for every course code of its
announcement. The checks SHALL test that the evidence occurs verbatim in the text, the dates fall
within the term and on class days of the course, a weekday the text states matches the date, the
change fits the `course_changes` rules, the classifier and the LLM agree on cancellation versus other
change, the LLM marked it certain, and the course has no change of the same kind on that day.

#### Scenario: Not a class day
- **WHEN** an extracted change falls on a Thursday and the course meets Monday and Wednesday
- **THEN** the class-day check fails and the fact waits for review

#### Scenario: Merged sections
- **WHEN** an announcement belongs to two course codes and the date is a class day of only one
- **THEN** the fact waits for review and nothing is applied to either course

#### Scenario: Existing change
- **WHEN** an operator already added a start-time change for that course on that day
- **THEN** the extracted start-time change waits for review and the existing change is not altered

### Requirement: Shadow mode and automatic apply

Automatic apply SHALL be off by default (shadow mode). In shadow mode every extracted course change
SHALL wait for review, marked when it passes every check. When an operator turns automatic apply on, a
course change that passes every check SHALL be written to `course_changes` for each course code with
the announcement as its source and `course-announcements` as the actor; every other one SHALL wait for
review.

#### Scenario: Shadow mode
- **WHEN** automatic apply is off and a cancellation passes every check
- **THEN** it waits for review, marked as passing all checks, and `course_changes` is unchanged

#### Scenario: Automatic apply on
- **WHEN** automatic apply is on and a cancellation passes every check
- **THEN** a cancelled change for that day is written with the announcement as its source

### Requirement: Edits after a change applied

When a new version of an announcement replaces an extraction whose course changes were already applied
(automatically or by approval), every course change of the new extraction SHALL wait for review and
show the applied change it differs from, and the applied rows SHALL stay as they are until an operator
acts, also when automatic apply is on.

#### Scenario: Corrected date
- **WHEN** an applied cancellation on 11/18 is followed by an edit that moves it to 11/25
- **THEN** the 11/25 cancellation waits for review next to the applied 11/18 change, which stays

### Requirement: Facts already past

A course change, make-up class or exam whose dates have all passed when it is extracted SHALL be
recorded as past and SHALL NOT wait for review or apply.

#### Scenario: Backfill of an old cancellation
- **WHEN** the history import extracts a cancellation dated three weeks before the import
- **THEN** the fact is listed as past and is not in the review queue

### Requirement: Review

Each extracted course change SHALL be its own review item. An operator SHALL be able to approve it,
which writes it to `course_changes` with the announcement as its source and records an audit entry;
to edit it in the course-changes editor before approving; or to reject it with an optional reason,
which is kept. Make-up classes and exams SHALL be shown with the announcement and SHALL NOT be review
items or change `course_changes`.

#### Scenario: Approve
- **WHEN** an operator approves a pending room change
- **THEN** the room change is in `course_changes` for the course, linked to the announcement, and the
  audit log names the operator

#### Scenario: Reject
- **WHEN** an operator rejects a pending cancellation with a reason
- **THEN** nothing is written to `course_changes` and the rejection and reason stay with the fact

### Requirement: History import

A one-time import SHALL load every past course announcement from a local export that holds no author
names, through the same storage and classification path as polling. Announcements of the current term
that meet the LLM rule SHALL be extracted, after any pending bulletin processing; no older announcement
SHALL be sent to the LLM. Imported announcements SHALL count as seen, so polling processes only new
ones and ones whose `modified` time changed.

#### Scenario: First poll after import
- **WHEN** polling first reads a course whose announcements were all imported unchanged
- **THEN** no announcement is stored again and none is sent to the LLM
