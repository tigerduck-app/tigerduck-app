# Spec Delta

## Purpose

Decide which iPhones and iPads get a class Live Activity start before and at each class, built by
the backend from the timetable it stores, what each start shows, when it is dropped, and how class
reminders end on iOS.

## ADDED Requirements

### Requirement: A device reports its Live Activity profile

An iPhone or iPad app SHALL send the backend its Live Activity profile whenever any part of it
changes and when an earlier send did not land: the in-app Live Activity switch, whether iOS allows
the app's Live Activities, whether the class-preparing and in-class scenarios are on, the class
lead time, and the Live Activity accent. A released app sends none.

#### Scenario: The user changes the lead time

- **WHEN** the user sets the class-preparing lead time to 30 minutes
- **THEN** the device's next preferences request carries the profile with a 30-minute lead time

#### Scenario: Live Activities turned off in iOS Settings

- **WHEN** the app becomes active after the user turned its Live Activities off in iOS Settings
- **THEN** the device sends a profile saying iOS does not allow them

#### Scenario: A send fails

- **WHEN** the preferences request with a changed profile fails
- **THEN** the device sends the profile again on its next launch or sync

### Requirement: The backend serves a device's class starts

The backend SHALL file class starts for a device only when it is an iPhone or iPad that has
reported a profile with the in-app switch on and iOS allowing Live Activities, has cloud sync and
course sync on, and has an active push-to-start token. Every other device SHALL keep the schedule
its app uploads.

#### Scenario: A released app

- **WHEN** a device has never reported a profile
- **THEN** the backend files no class start for it and keeps using the class events it uploads

#### Scenario: Course sync off

- **WHEN** a device reports a profile but has course sync off
- **THEN** the backend files no class start for it and keeps using the class events it uploads

#### Scenario: No push-to-start token

- **WHEN** a served device has no active push-to-start token
- **THEN** the backend files no class start for it and counts it

### Requirement: Class starts follow the stored timetable

For a served device the backend SHALL file a `classPreparing` start at the class start minus the
device's lead time and an `inClass` start at the class start, for each scenario the device has on,
for every class of the user's enrolled courses on a class day, with the school's course changes,
the user's skipped days and holiday choices applied, whether or not the app has run.

#### Scenario: App not opened for a week

- **WHEN** a served device's app has not run for 7 days and the user has a class tomorrow at 10:20 with a 60-minute lead time
- **THEN** a `classPreparing` start goes to that device at 09:20 and an `inClass` start at 10:20

#### Scenario: A holiday

- **WHEN** a holiday covers the day and the user has not said they still have class
- **THEN** no start is filed or sent for that day

#### Scenario: Skipped class

- **WHEN** the user skipped the class that day
- **THEN** no start is filed or sent for that class

#### Scenario: Lead time already passed

- **WHEN** a class is filed less than the lead time before it starts and more than a minute before it
- **THEN** its `classPreparing` start goes out within the next pipeline tick

### Requirement: A class start matches the app's own

A start the backend builds SHALL carry the activity id the app would give the same class, which is
the scenario and the course number, day and first period of the meeting or of its fragment when a
course change cancels or moves part of it, together with the times, room, change markers and
countdown the app would show.

#### Scenario: A room change for part of a meeting

- **WHEN** a course change gives periods 5 and 6 of a periods 3 to 6 meeting a new room
- **THEN** the backend files one start for periods 3 and 4 and one for periods 5 and 6, each with the app's id, room and times

#### Scenario: The app starts the same activity

- **WHEN** the app in the foreground started the class's activity and registered it before the start fired
- **THEN** the backend's start is cancelled as already running

### Requirement: One source of class starts per device

For a served device the backend SHALL ignore the class events its app uploads and SHALL NOT cancel
the class starts it filed when that upload leaves them out. For other devices an upload SHALL keep
today's behaviour. A class SHALL never have two pending starts of one scenario on one device.

#### Scenario: Upload from a served device

- **WHEN** a served device uploads a list with class events for today and tomorrow and none for the day after
- **THEN** the backend keeps its own class starts for all three days and files none of the uploaded class events

#### Scenario: A device becomes served

- **WHEN** a device with uploaded class starts pending reports a profile that makes it served
- **THEN** the backend takes those pending starts over under the same keys and files no second start for those classes

### Requirement: A class start is checked right before sending

Before its first delivery the backend SHALL drop a start it filed when the device is no longer
served, the scenario is off, the course is no longer an enrolled course of the user, the user
skipped the day, classes do not meet that day, or the class was cancelled, and SHALL drop it when
the check cannot answer.

#### Scenario: Live Activities turned off since filing

- **WHEN** the device's profile turned the in-app switch off after the start was filed
- **THEN** the start is cancelled and nothing is sent

#### Scenario: Course hidden since filing

- **WHEN** the user hid the course on a device after the start was filed
- **THEN** the start is cancelled and nothing is sent

#### Scenario: The check fails

- **WHEN** the database query of the check fails
- **THEN** the start is cancelled and nothing is sent

### Requirement: Shadow comparison

While the backend runs in shadow mode it SHALL send no start it built and SHALL compare, for each
schedule upload, the class starts it would build for that device over the upload's window with the
uploaded class events, and count matches, events only one side has and differences per field.

#### Scenario: Server misses a class

- **WHEN** an upload holds a class event the backend's build for that device and window does not
- **THEN** the comparison counts one app-only event and the upload is filed as today

#### Scenario: Different room

- **WHEN** an uploaded event and the backend's build of the same id differ only in the room
- **THEN** the comparison counts one difference in the room field

### Requirement: No class reminder setting on iOS

The iOS app SHALL show no class reminder setting, SHALL neither read nor write the `courses`
section of the `notification` document, and SHALL leave that section as it is for other clients.

#### Scenario: Settings after the update

- **WHEN** a user opens the class table settings in iOS 4.0.0
- **THEN** there is no class reminder row

#### Scenario: The document keeps the section

- **WHEN** iOS 4.0.0 writes the `notification` document that holds a `courses` section
- **THEN** the section keeps its values

### Requirement: Class reminders end

The backend SHALL send no class reminder to a device that reports a profile once the owner turns
that on, and SHALL send no class reminder at all from the date the owner sets for released apps.
It SHALL keep sending nothing on the `course` channel to Android, as today.

#### Scenario: Device on iOS 4.0.0

- **WHEN** the owner has turned reminders off for profile devices and a user's only iPhone runs iOS 4.0.0
- **THEN** no class reminder is filed or sent to it

#### Scenario: Released app before the date

- **WHEN** a user's only iPhone runs a released app and the owner's date has not come
- **THEN** class reminders are sent to it as today
