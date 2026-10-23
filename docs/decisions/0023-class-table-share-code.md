# 0023. Share class tables as QR codes of compressed, checksummed course codes

Status: accepted

## Context

Students share their class tables as QR codes and import each other's
(https://github.com/tigerduck-app/tigerduck-app/issues/382). A code is screenshotted and passed
on, so it never expires and has to stay small. The importer looks each course up in NTUST's course
query, as the user's own courses are looked up, so a code needs only course codes. The Android app
(https://github.com/tigerduck-app/tigerduck-app-android/issues/191) reads and writes the same
codes, and imported class tables stay on the device.

## Decision

### The share code, version 1

`HTTPS://TIGERDUCK.APP/T/1.<student ID>.<share time>.<terms>.<payload>.<checksum>`

- Every character is in the QR alphanumeric set (`0-9`, `A-Z`, space and `$%*+-./:`), so a QR
  encoder keeps the code in alphanumeric mode. URL schemes and hosts are case-insensitive, so the
  code is also the URL `https://tigerduck.app/T/...`, which a later version can open in the app,
  for example to add a friend.
- After the prefix `HTTPS://TIGERDUCK.APP/T/` come six fields separated by `.`:
  1. The format version, `1`.
  2. The sharer's student ID, `[A-Z0-9]+`.
  3. The share time, `yyyyMMddHHmm`, in the Gregorian calendar and Taipei time (`Asia/Taipei`).
  4. The shared terms: one or more distinct semester codes joined by `-`. A semester code is the
     ROC year and the term, `[0-9]{3}[0-9A-Z]`: `1151`, `1142`, or `114H` for a summer term.
  5. The payload: Base32 (RFC 4648 section 6, upper case, no `=` padding) of raw DEFLATE (RFC
     1951, with no zlib or gzip wrapper) of an ASCII text. The text holds each term's course codes
     joined by `,`, the terms in the order of field 4 joined by `;`.
  6. The checksum: the CRC-32 that zlib's `crc32()` computes (CRC-32/ISO-HDLC, whose check value
     for `123456789` is `CBF43926`) over the ASCII bytes of everything before the last `.`, the
     prefix included, written as 4 bytes big-endian in Base32 without padding: 7 characters.
- Each term lists at least one course and no course code twice. A course code has NTUST's shape,
  the one the app reads from the course-selection list: a head, then six or seven characters of
  `0-9A-Z`. The head is `3` and two letters, two letters, or `3` and one letter, the last for a
  course taken at NTU or NTNU (`3N1010001`); as a whole,
  `(3[A-Z]{2}|[A-Z]{2}|3[A-Z])[A-Z0-9]{6,7}`.
- Only course codes go in: no class times, course names, rooms, custom names or colours.
- The app's encoder shares one term, or every term of the user's that has courses. It upper-cases
  the student ID, terms and course codes, sorts each term's course codes, and leaves out codes
  outside the shape and terms left without a course.
- The checksum stops damaged codes and casual edits only. The app is open source, so anyone can
  build a code with a matching checksum; a code proves nothing about who made it.

### Reading a share code

A decoder trims surrounding whitespace, upper-cases the text, and reports the first of these that
applies:

1. Neither this prefix nor the one below: not a share code, such as another app's QR code. A
   scanner skips it without a message.
2. Text up to the first `.` after the prefix that is digits but not `1`: a newer version.
   Anything else there that is not `1` is malformed.
3. Other than six fields: malformed.
4. A checksum field that differs from the checksum computed, compared as text before any later
   field is read: a checksum mismatch.
5. A student ID, share time (an impossible date included), term list or payload that breaks the
   rules above, or a payload that inflates to 64 KiB or more: malformed.
6. A course code outside NTUST's shape: an invalid course code.

The import screen shows one message for all but the first; the cases stay apart for tests and
logs. DEFLATE encoders differ, so two platforms may write different payloads for one class table;
interop is tested by decoding the vectors below, never by comparing encoder output. On Android,
`java.util.zip.Deflater(level, true)` writes raw DEFLATE and `Inflater(true)` reads it; on Apple
platforms `COMPRESSION_ZLIB` does both.

| Code | Reads as |
|---|---|
| `HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151.OMHDMNBQGQYDAMGUOGDLFDDULROWCYV6RYYFMACMBQAA.E2YUDIQ` | B11300001, shared 2026-10-13 14:05 Taipei time. 1151: CS1010001, CS1010002, EE1010001, MA1010001, PE1010001 |
| `HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151.AEYQBTX7INJTCMBRGAYDAMJMINJTCMBRGAYDAMRMIVCTCMBRGAYDAMJMJVATCMBRGAYDAMJMKBCTCMBRGAYDAMI.Y4XVOOA` | The same, its payload a stored (uncompressed) DEFLATE block |
| `HTTPS://TIGERDUCK.APP/T/1.M11300002.202602200930.1151-114H-1142.GN3A4NRUGA2DAMBQ2KA3CDDV3RO2CLDLL5D2RLBVJTLFRR6VCWTMGHOOBKALCAA.XSAWPTA` | M11300002, shared 2026-02-20 09:30. 1151: 3CS1010002, CS1010001, GE1010001. 114H: MA1010002. 1142: CS1010003, EE1010002, GE1010002, PE1010002 |
| The first code with its payload's first `O` changed to `P` | Checksum mismatch |
| `HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151.OMHDMNBQGQYDAMGUOGDLAAA.5GDOVTY` | Invalid course code `CS10100` |
| `HTTPS://TIGERDUCK.APP/T/2.B11300001.202610131405.1151.OMHDMNBQGQYDAMAEAA.O6Y5T6Y` | Newer version |

The first two payloads inflate to `CS1010001,CS1010002,EE1010001,MA1010001,PE1010001`, the third
to `3CS1010002,CS1010001,GE1010001;MA1010002;CS1010003,EE1010002,GE1010002,PE1010002`. These codes
were written by an encoder other than the app's; `swift/TigerDuckTests/ClassTableShareCodeTests.swift`
decodes them, with more malformed ones.

### TAT's share code

The app also reads TAT's share code, versions 1 and 2, and writes version 2 for one term:

- `HTTPS://NTUST-TAT.WEB.APP/S/`, then `TAT2` or `TAT1`, the 4-character term, the student ID
  padded with spaces to 9 characters, and the courses joined by `-`. It has no share time and no
  checksum.
- A course is its 9-character course code and, in version 2, a part for each weekday it meets:
  `.`, the weekday from `1` for Monday to `7` for Sunday, and one character per period, earliest
  first, from `1234N56789ABCD`. `N` is the noon period, the app's period 5, so `5` to `9` are the
  app's periods 6 to 10; `1` to `4` and `A` to `D` match the app's.
- The decoder keeps the term, the student ID (none when blank) and the course codes, and checks
  the weekday parts without keeping them; version 1 has none. A course code of another length or
  listed twice, or a weekday or period outside these, is malformed; a 9-character code outside
  NTUST's shape is an invalid course code; `TAT` and another digit is a newer version. A code with
  no courses may end inside the student ID, its padding trimmed with the surrounding whitespace.
- The encoder takes each course's weekdays and periods from the user's class table and leaves out
  course codes that are not 9 characters long. It writes no code for a student ID longer than 9
  characters or a term with no course left.
- `HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001CS1010001.267-EE1010002.13.5N-MA1010003` reads as
  B11300001, 1151: CS1010001, EE1010002, MA1010003, and
  `HTTPS://NTUST-TAT.WEB.APP/S/TAT11142B11300002CS1010004-PE1010005` as B11300002, 1142:
  CS1010004, PE1010005.

### Imported class tables

- `ImportedClassTableStore` keeps the people imported, in import order, in one file in
  Application Support that is excluded from backups. None of it goes to TigerSync, the backend,
  the App Group or the Watch.
- A person has an id, the student ID when the code has one, a nickname, which is required, the
  import time, the share time when the code has one, and each term's course codes with the course
  details from NTUST's course query.
- Importing a student ID that is already there replaces that person's terms and share time and
  stamps the new import time, keeping the nickname, the entry and its place in the list.
- The person whose class table is shown is kept in memory only, so every launch opens on the
  user's own class table.
- The store empties when the user signs out (`AppState.logoutNTUST()`) and when a student ID other
  than the one the people were imported under signs in (`AuthService.login`). A session renewed
  in the background (`AuthService.ensureAuthenticated()`) and TigerSync turned off leave it alone.

## Size

8 terms of 10 courses each, the course codes made of random digits, make a code of 785
characters: a version 18 QR code, 89 by 89 modules, at error correction level M. The same course
codes in clear would take 888 characters.

## Alternatives

- Course codes in clear: readable at a glance, and longer once a code holds several terms.
- Base45 (RFC 9285), which fits QR alphanumeric mode more tightly than Base32. Its alphabet holds
  `.`, `-` and space, so a Base45 payload could not sit between `.`-separated fields.
- Class times in the code: they would draw a class table before the course query answers, but
  the importer needs the query for names and rooms anyway, and they lengthen the code.
- Only the QR code's own error correction: it repairs a damaged scan, but an edited code printed
  as a new QR code passes it.

## Consequences

- A layout change takes a new version number, and decoders keep reading version 1, which is
  already handed out. A decoder that meets a newer version can ask the user to update the app.
- Whoever sees a share code learns its sharer's student ID and courses.
- Decoders from before the `3` and one-letter head was allowed
  (https://github.com/tigerduck-app/tigerduck-app/issues/766) refuse a code that holds such a
  course as an invalid course code.
