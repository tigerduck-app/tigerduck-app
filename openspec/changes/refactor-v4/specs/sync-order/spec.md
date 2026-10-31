# Spec Delta

## Purpose

Keeps every device that shares an account converging on one state: each refresh reads the backend
before it sends what it learned from the school, and no edit is lost to the order of the two.

## ADDED Requirements

### Requirement: A refresh reads the backend before it uploads school data
On launch, on return to the foreground and after a sign-in, the app SHALL apply the backend's state
before it applies school data fetched in the same refresh, and SHALL send changes derived from
school data only after that. Values SHALL merge per field by their stamps, so an edit this device
has not sent yet survives the pull. A local edit SHALL be sent at once, without waiting for a pull.

#### Scenario: The school answers first
- **WHEN** the school fetch finishes before the backend pull
- **THEN** its result is applied, and its upload sent, only after the pull has been applied

#### Scenario: An edit made offline
- **WHEN** this device changed a course colour while offline, and another device changed the same colour earlier
- **THEN** after the pull this device still shows its own colour and sends it

#### Scenario: The backend is unreachable
- **WHEN** the backend pull fails
- **THEN** the fetched school data is shown, and nothing derived from it is sent until a pull succeeds

#### Scenario: A new sign-in
- **WHEN** a device signs in and fetches the school roster before its first pull has finished
- **THEN** it sends no course upload until that pull has been applied
