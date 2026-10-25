# Spec Delta

## Purpose

Fix the order in which a refresh reads the device, TigerSync and the school, and keep the
school's data as a base layer that the user's choices sit on, so no fetch order and no TigerSync
failure can let school data replace something the user chose.

## ADDED Requirements

### Requirement: A refresh runs local state, then TigerSync, then the school
A refresh that fetches school data (launch, return to the app, pull to refresh, the Mac's
Refresh) SHALL first show the device's stored data, then run TigerSync (send unsent edits, then
pull), and SHALL start the course selection, Moodle and grade fetches only once TigerSync has
finished or failed.

#### Scenario: Pull to refresh on Home
- **WHEN** the user pulls to refresh Home with TigerSync on
- **THEN** the course selection and Moodle fetches start after the TigerSync pull returns

#### Scenario: Backend unreachable
- **WHEN** the TigerSync pull fails
- **THEN** the school fetches start right after the failure and the refresh completes

#### Scenario: TigerSync off
- **WHEN** TigerSync is off
- **THEN** the school fetches start right after the stored data is shown

### Requirement: One refresh at a time
A refresh started while another is running SHALL join the running one instead of starting a
second TigerSync pull or a second school fetch.

#### Scenario: Two pulls in a row
- **WHEN** the user pulls to refresh twice within a second
- **THEN** one TigerSync pull and one round of school fetches run

### Requirement: TigerSync-only triggers fetch nothing from the school
A revision change seen by polling and a sync push SHALL run TigerSync alone.

#### Scenario: Sync push
- **WHEN** a sync push arrives
- **THEN** the device pulls from the backend and makes no course selection or Moodle request

### Requirement: School data is a base layer
A course selection, Moodle or grade fetch SHALL write only school data: courses and their
schedule, assignments, submissions and grades. It SHALL NOT write or clear a user choice:
a course's colour, name or ignore setting, an assignment mark, or a course the user added, hid
or removed.

#### Scenario: Hidden course in a fresh roster
- **WHEN** the user hid a course and the next course selection fetch lists it
- **THEN** the course stays hidden

#### Scenario: Renamed course
- **WHEN** the school returns a new title for a course the user renamed
- **THEN** the class table shows the user's name

### Requirement: User choices apply on top whatever TigerSync did
The apps SHALL show school data with the user choices the device holds applied on top, whether
the last TigerSync pull succeeded, failed or has not returned.

#### Scenario: Slow TigerSync
- **WHEN** a mark set on this device is unsent and the TigerSync pull has not returned when the Moodle fetch finishes
- **THEN** the assignment still shows the mark

### Requirement: Roster uploads are base data on the backend
A roster or assignment upload SHALL update only the backend's school rows and SHALL NOT change
a stored user choice, except that its colours fill a course that has none, as oldest values.

#### Scenario: Roster upload with colours
- **WHEN** a roster upload carries a colour for a course the user coloured on another device
- **THEN** the backend keeps the user's colour
