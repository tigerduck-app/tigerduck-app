# 0031. The course change feed sends each client only the kinds it reads

Status: accepted

## Context

`GET /calendar/course-changes` serves the backend's course changes to the iOS and Android apps. It
is public, unauthenticated and cached for five minutes. Released apps drop a change whose kind they
do not know. In November 2026 two kinds joined the five (`assessment` and `online`), and most of
the changes they replace were stored as notes that every released app already shows as text.

## Decision

- A client lists the kinds it reads beyond `cancelled`, `room`, `start`, `end` and `note` in the
  `kinds` query parameter (`kinds=assessment,online`). Unknown values are ignored.
- A change of a kind beyond those five that the request did not list goes out as a `note` with the
  same id and class days, its text being what that kind carries (an assessment's name; an online
  change's description, or 線上 / Online). The five original kinds always go out as they are.
- The ETag covers the listed kinds, so a client that starts listing a kind gets the whole term
  again instead of a 304 for the copy it stored before.
- A later kind follows the same rule: it is added to the parameter's vocabulary, given a note
  fallback, and sent only to clients that list it.

## Alternatives

- Send the new kinds to everyone: released apps would lose the rows, and with them the exam notes
  they show today.
- Read the app version from `User-Agent`: the platforms format it differently, the endpoint knows
  no user, and a wrong guess fails silently.
- A new endpoint or API version: one field's vocabulary does not justify a second route, and both
  apps already read `/v4`.

## Consequences

- An app shows a new kind only from the version that lists it; older apps and Android keep notes.
- The backend keeps a fallback for each kind for as long as a client may omit it.
- A shared cache keys on the query string, so the two forms of the answer never mix.
