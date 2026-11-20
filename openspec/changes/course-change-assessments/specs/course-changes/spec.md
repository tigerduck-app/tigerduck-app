# Spec Delta

## Purpose

The kinds of course change the backend stores, what each carries, how the course change feed serves
them to clients that do and do not understand a kind, how the portal and the course announcement
extraction write them, and how the class pushes apply them.

## ADDED Requirements

### Requirement: Kinds

A course change SHALL be one of `cancelled`, `room`, `start`, `end`, `assessment`, `online` or
`note`. An `assessment` marks a class meeting in which every student of the course is assessed at
the same time. An `online` change marks a class meeting held online instead of in its room.

#### Scenario: Unknown kind
- **WHEN** a writer stores a change of kind `exam`
- **THEN** the database rejects the row

### Requirement: Assessment values

An `assessment` SHALL carry a non-blank Chinese name and a non-blank English name, in `note_zh` and
`note_en`, and no room or times.

#### Scenario: Assessment without an English name
- **WHEN** a writer stores an `assessment` whose English name is blank
- **THEN** the database rejects the row

### Requirement: Online values

An `online` change SHALL carry no room or times, and MAY carry a description in `note_zh`, with an
optional English one in `note_en`.

#### Scenario: Online class with no description
- **WHEN** a writer stores an `online` change with neither description
- **THEN** the row is stored

### Requirement: Clashes

Two changes of one course that cover the same class day in a common period, or in any period when
either names none, SHALL clash when they are of the same kind other than `note`, or when one is
`room` and the other `online`. Notes SHALL never clash, and an `assessment` SHALL clash with no
other kind.

#### Scenario: Room and online on the same meeting
- **WHEN** an operator adds an `online` change for a day and periods that a `room` change of the same
  course already covers
- **THEN** the portal refuses it as a clash with that room change

#### Scenario: Exam moved to another room
- **WHEN** a course has an `assessment` and a `room` change on the same day and periods
- **THEN** both are kept

### Requirement: Feed kinds parameter

`GET /calendar/course-changes` SHALL accept a `kinds` query parameter, a comma-separated list of the
kinds beyond `cancelled`, `room`, `start`, `end` and `note` that the client reads, and SHALL ignore
values it does not know.

#### Scenario: App that reads the new kinds
- **WHEN** a client requests with `kinds=assessment,online`
- **THEN** assessments and online changes come with their own kinds

### Requirement: Note fallback

A change whose kind the request did not list SHALL be sent as a `note` with the same id and class
days. An `assessment` SHALL carry its names as the note's texts. An `online` change SHALL carry its
description, or without one the shared string `course_change_online` in zh-Hant and en.

#### Scenario: Released app
- **WHEN** a client requests without `kinds` and the term holds an assessment named 期中考 / Midterm
  exam
- **THEN** the response lists that change with kind `note`, `note_zh` 期中考 and `note_en` Midterm
  exam

#### Scenario: Online without description for a released app
- **WHEN** a client requests without `kinds` and a change is `online` with no description
- **THEN** it is a `note` with `note_zh` 線上 and `note_en` Online

### Requirement: ETag by kinds

The feed's ETag SHALL differ between requests that list different kinds.

#### Scenario: Upgrade keeps no stale copy
- **WHEN** a client sends the ETag of a response without `kinds` in `If-None-Match` on a request
  with `kinds=assessment,online`
- **THEN** the response is 200 with the whole term, not 304

### Requirement: Converting the stored notes

The migration that adds the kinds SHALL convert these notes of term 1151, each only while its id,
kind and Chinese text still match:

- 14, 17, 18, 19, 20, 21 and 33 (期中考 / Midterm exam) and 23 (期末考 / Final exam) to `assessment`;
- 16 (期中分組簡報) to `assessment` named 期中分組簡報 / Midterm group presentation;
- 54 (期末報告 / Final Presentation) to `assessment` named 期末簡報 / Final presentation;
- 35 and 36 to `online`, their text kept as the description.

#### Scenario: A database without those rows
- **WHEN** the migration runs on a database where those ids hold other rows or none
- **THEN** no row changes

### Requirement: Reverting the conversion

The migration's downgrade SHALL restore the converted rows as the notes they were.

#### Scenario: Rollback
- **WHEN** the migration is downgraded after converting the 12 rows
- **THEN** they are notes again with their original texts

### Requirement: Portal kinds

The portal's change dialog SHALL offer `assessment`, requiring both names, and `online`, with an
optional description in both languages.

#### Scenario: Assessment without English
- **WHEN** an operator saves an assessment with only a Chinese name
- **THEN** the dialog does not save it

### Requirement: Portal presets

The assessment presets SHALL be 期中考 / Midterm exam, 期末考 / Final exam, 小考 / Quiz, 期中簡報 /
Midterm presentation and 期末簡報 / Final presentation. The note's only preset SHALL be 補課 /
Make-up class.

#### Scenario: Picking a preset
- **WHEN** an operator picks 期中考 for an assessment
- **THEN** the dialog fills 期中考 and Midterm exam, and either can still be edited

### Requirement: Extracted exams

An extracted exam whose date is a class day of the course SHALL become a pending review item adding
an `assessment` on that day, named 期中考 / Midterm exam, 期末考 / Final exam or 小考 / Quiz by its
exam kind. An exam of another kind SHALL carry the extracted Chinese name and an empty English name.
An exam without a date or off a class day SHALL stay information.

#### Scenario: Midterm announced for a class day
- **WHEN** a course announcement says the midterm is in class on a date the course meets
- **THEN** a pending `assessment` item named 期中考 / Midterm exam is queued for that date

#### Scenario: Exam on a day without class
- **WHEN** the extracted exam date is not a class day of the course
- **THEN** no review item is made and the exam stays in the announcement's information

### Requirement: Extracted online classes

A class the extraction finds moved online SHALL become an `online` review item, not a note.

#### Scenario: Class moved online
- **WHEN** a course announcement says next Monday's class is online
- **THEN** a pending `online` item is queued for that Monday

### Requirement: Automatic apply of assessments

Automatic apply of an `assessment` item SHALL require `exam_info` or `exam_change` from both the
classifier and the extraction, in place of `class_change`, and SHALL never apply an item whose
English name is empty.

#### Scenario: Exam of another kind
- **WHEN** automatic apply is on and an `assessment` item has an empty English name
- **THEN** the item waits for an operator

### Requirement: Online class in pushes

When a meeting has an `online` change, a class reminder and a class Live Activity start SHALL show
`course_change_online` in the receiving device's language where the room was.

#### Scenario: Online class Live Activity in English
- **WHEN** a class Live Activity start is sent for an online meeting to a device set to English
- **THEN** its location reads Online

### Requirement: Assessment in pushes

When a meeting has an `assessment`, a class reminder's body SHALL begin with the assessment's name in
the device's language (Chinese for a Chinese locale, else English) followed by ` · `, and a class
Live Activity start SHALL say that the class is an assessment. A `cancelled` change SHALL still drop
both.

#### Scenario: Reminder for an exam in another room
- **WHEN** a class reminder is sent to a device set to Traditional Chinese for a meeting at 09:10
  with an assessment 期中考 and a room change to IB-101
- **THEN** its body is 期中考 · 09:10 · IB-101
