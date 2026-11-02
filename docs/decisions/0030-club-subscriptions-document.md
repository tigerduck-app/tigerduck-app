# 0030. Club subscriptions sync as a document merged value by value

Status: accepted

## Context

A user subscribes to clubs of clubs.ntust.edu.tw, puts them in a priority order and may change
each club's color; the class table draws the subscribed clubs' activities. The choices belong to
the account and sync between its devices, the iOS app's and the Android app's, through TigerSync.
The club data itself comes from one public source, so only the user's choices travel. Two devices
may change different clubs, or different values of one club, while one of them is offline.

## Decision

- The choices are the settings document `club_subscriptions`, read and written through
  `SettingsDocumentClient` like `notification`:

  ```json
  {"clubs": {"93": {"subscribed": true, "subscribed_at": "2026-11-02T14:00:00.000Z",
                    "color": "#D35400", "color_at": "2026-11-02T14:00:00.000Z"}},
   "order": {"ids": [93, 33], "at": "2026-11-02T14:05:00.000Z"}}
  ```

  Keys of `clubs` are decimal club ids. Stamps are ISO 8601 times; the app writes them in UTC to
  the millisecond and reads any offset or precision.
- Each value carries its own stamp, and a merge takes per club `subscribed` and `color`, and the
  document's `order`, from the side that set it later; a tie keeps the server's
  (`ClubSubscriptionsDocument.merged`). A value that is unreadable, or lacks its stamp, counts as
  absent, so another writer's mistake cannot erase a choice.
- An edit is stamped with the device's time, or 1 ms after the latest stamp the device's copy
  holds when that is later (`ClubSubscriptionsDocument.stamp(at:)`), so a value stamped ahead by
  another device's wrong clock cannot outlast the edits made after it.
- A push and a pull are one step (`ClubSubscriptionsSync.sync`): merge the device's copy with the
  server's, write the result with the server's revision when it differs, merge once more with the
  copy a 409 carries, and keep the result on the device. The write splices the merged values over
  the document read (`SettingsDocument.merging`), so keys this build does not know survive.
- Unsubscribing keeps the color and its stamp for a later subscription. Subscribing puts the club
  last in `order` and, if it never had a color, writes its default with a stamp, so every device
  shows the color the first one chose. The default is the 32-bit FNV-1a hash of the decimal id's
  UTF-8 bytes, modulo the course palette (`ClubSubscriptions.defaultColor`).
- The shown order is `order.ids` filtered to subscribed clubs, then subscribed clubs it lacks by
  `subscribed_at`, then by id.
- `order` is one value: after a reorder on one device and a subscription made offline on another,
  only the later order stays, and a club the earlier one placed shows after the ordered ones.
- Subscriptions are not tied to a term; they carry over to the next one.
- A change marks the document unsent until a sync leaves nothing to send; the next full sync or
  change-feed pull sends it again. A sync that fails, reading or writing, is owed until one
  lands, and every poll runs it again, as a change it failed to read is not marked unsent.

## Alternatives

- A list of subscribed ids replaced whole, as `reminder_offsets_minutes` is: two devices
  subscribing at once would drop one subscription.
- Stamping the whole document once: a color change on one device would undo a subscription made
  on another.

## Consequences

- A field added later needs its own stamp and a case in the merge; older builds keep it through
  the JSON splice but do not merge it.
- The Android app must read and write the same shape, stamps and default color.
