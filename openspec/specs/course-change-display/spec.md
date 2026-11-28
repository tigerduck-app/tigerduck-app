# course-change-display Specification

## Purpose
How the Apple apps show an assessment and an online class on every surface that draws one day's
class, so a student sees an exam or an online class without opening the course.

## Requirements

### Requirement: The app asks for the new kinds

The iOS, iPadOS and macOS app SHALL request course changes with `kinds=assessment,online` and SHALL
read both kinds. A change of a kind the app does not know SHALL be ignored, as today.

#### Scenario: First launch after the update
- **WHEN** the app updated from 4.0.2 holds the term's changes as notes and requests them again
- **THEN** it replaces them with the assessments and online changes the response carries

### Requirement: Assessment underline

A class meeting that has an `assessment` on its day SHALL draw its course name with a dashed
underline in the assessment color, a muted red with a light and a dark variant, whatever the
course's color and the app's theme. Only that day's meeting SHALL be marked.

#### Scenario: Midterm this week
- **WHEN** this week's Monday class of a course has an assessment and its Wednesday class does not
- **THEN** the Monday cell's course name is underlined and the Wednesday cell's is not

#### Scenario: Exam with a room change
- **WHEN** a meeting has an assessment and a room change
- **THEN** the course name is underlined and the new room is shown as a room change

### Requirement: Cancellation wins

A cancelled meeting SHALL show as cancelled with no underline, even when it has an assessment.

#### Scenario: Cancelled exam
- **WHEN** a meeting has both an assessment and a cancellation
- **THEN** it is drawn as cancelled, without the underline

### Requirement: Underline surfaces

The underline SHALL appear in the class table (iPhone, iPad and Mac), Home's course cards and the
time machine, the Home Screen and Lock Screen widgets, the Mac widget cards, and the class Live
Activity. It SHALL NOT appear on the Watch. An assessment SHALL NOT add the note bubble to a class
table cell.

#### Scenario: Live Activity for an exam
- **WHEN** a class Live Activity shows a meeting that is an assessment
- **THEN** its course name is underlined

### Requirement: Online class in place of the room

A class meeting that has an `online` change on its day SHALL show `course_change_online` (線上 /
Online) where its room is shown, styled as a room change, on the underline's surfaces and on the
Watch.

#### Scenario: Widget for an online class
- **WHEN** today's next class has an online change
- **THEN** the widget shows 線上 in place of its room

### Requirement: Course sheet

The course sheet's list of changes SHALL show an assessment as `course_change_assessment` · its name
(評量 · 期中考) and an online change as `course_change_online`, followed by ` · ` and its
description when there is one.

#### Scenario: Online with description
- **WHEN** a course has an online change described 請自行學習 Module 5
- **THEN** its row reads 線上 · 請自行學習 Module 5

### Requirement: VoiceOver

VoiceOver SHALL read `course_change_assessment` (評量 / Assessment) right after the course name of an
underlined class, and `course_change_online` where it reads the room. No other text SHALL be added
to the screen for an assessment.

#### Scenario: Class table cell
- **WHEN** VoiceOver focuses the underlined cell of a course named 作業系統
- **THEN** it reads 作業系統, 評量, then the rest of the cell
