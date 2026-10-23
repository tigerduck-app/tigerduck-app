# 0023. Share class tables as QR codes of packed, checksummed course codes

Status: accepted

## Context

Students share their class tables as QR codes and import each other's
(https://github.com/tigerduck-app/tigerduck-app/issues/382). A code is screenshotted and passed
on, so it never expires and has to stay small. The importer looks each course up in NTUST's course
query, as the user's own courses are looked up, so a code needs only course codes. The Android app
(https://github.com/tigerduck-app/tigerduck-app-android/issues/191) reads and writes the same
codes, and imported class tables stay on the device.

A code is also a link: scanned with the Camera or any QR app, or tapped, it opens the app at the
import (https://github.com/tigerduck-app/tigerduck-app/issues/612), and without the app the share
page (tigerduck-app/web-share) shows it.

## Decision

### The share host

- Every share link is `https://share.tigerduck.app/<TYPE>/<content>`, so a later version can share
  more than class tables. The class table's type is `CLASSTABLE`.
- Codes are written in upper case, `HTTPS://SHARE.TIGERDUCK.APP/...`: every character is then in
  the QR alphanumeric set, the smallest QR mode, and URL schemes and hosts are case-insensitive.
- A type is one or more of `A-Z` and `0-9` followed by `/`. Any type but `CLASSTABLE` is a newer
  app's. The host with no type is malformed: alone, or followed only by `/`, a query or a fragment.
  So are a type without its slash, an empty segment (`//`) and other characters (`FRI-END/`).
- A host that only starts the same, such as `SHARE.TIGERDUCK.APP.EXAMPLE.COM` or
  `SHARE.TIGERDUCK.APP@EXAMPLE.COM`, is not the share host.
- The codes versions 2.4.0 to 2.6.x wrote, on `HTTPS://TIGERDUCK.APP/T/`, are not read: no
  compatibility and no redirect. Such a code is like another app's QR code.

### The class table code, version 1

`HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/` + version + payload.

- The version is one digit: `1` is this layout, and `2` to `9` are newer versions. `0`, a letter,
  another character or none is malformed.
- The payload packs the share time, the terms, the student ID and each term's course codes into
  bits behind a CRC-32 and writes them in Base36. The layout below was agreed with the Android side
  and the share page; `swift/TigerDuckTests/ClassTableShareCodeVectors.txt` holds the test codes
  both apps pin, which a reference codec wrote and read.
- Every class table has one code. A code an encoder would have written otherwise, such as a tail
  in a later shape than fits, tails out of order or padding that is not zero, is malformed, so two
  apps can compare their encoders' output.
- Only course codes go in: no class times, course names, rooms, custom names or colours.
- The app's encoder shares one term, or every term of the user's that has courses. It upper-cases
  the student ID, terms and course codes, and leaves out codes outside NTUST's shape and terms left
  without a course. Sharing every term writes the newest 24. Any other table past a limit (a term
  of more than 64 courses, a student ID longer than 16 characters, a share time outside 2024 to
  2055) writes no code, as a table with nothing to share does.
- The checksum stops damaged codes and casual edits only. The app is open source, so anyone can
  build a code with a matching checksum; a code proves nothing about who made it.

#### Payload: bits in Base36

The payload is a bit string B = CHECK (32 bits) + DATA + padding, written in Base36:

- Split B from its start into groups of 31 bits. A full group is written as 6 base-36 digits
  (`0-9A-Z`), most significant first, with leading zeros. A last, shorter group has 5k bits
  (k = 1 to 5) and is written as k digits.
- Padding is the fewest zero bits that make the last group 31 bits or a multiple of 5: with
  r = (bits of CHECK + DATA) mod 31, padding = 31 - r when r > 25, otherwise (-r) mod 5.
- A decoder refuses a full group of 2^31 or more, a k-digit group of 2^(5k) or more, padding that
  is not exactly that length, and padding that is not zero.
- CHECK is the CRC-32 (zlib's `crc32`, the same as Java's `CRC32`) of the ASCII bytes of
  `HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/1` followed by DATA + padding written most significant
  bit first and zero-filled to a whole byte.

Codes used below:

- `u(k)`: a k-bit unsigned number, most significant bit first.
- `gamma(x)`, x >= 1: Elias gamma, (bit length of x) - 1 zero bits, then x in binary. A decoder
  refuses more than 32 leading zeros.
- `subset(S, n)`: a set S of distinct numbers in 0..n-1. First `gamma(|S| + 1)`, or `gamma(|S|)`
  where the set is never empty, then the rank in `u(b)`, where b is the bit length of the largest
  rank, C(n, |S|) - 1. The rank is the sum over i of C(s_i, i + 1) for S in ascending order (the
  combinatorial number system). A rank of C(n, |S|) or more is malformed.

#### DATA, in this order

##### 1. Share time

`u(24)`: minutes since 2024-01-01 00:00 Asia/Taipei (UTC+8), which reaches 2055-11-24 20:15. The
academic year A of the share time is its Taipei calendar year - 1911, minus 1 before August.

##### 2. Terms, 1 to 24, listed newest first

- `u(1)`: 0 regular, 1 explicit. `gamma(T)`: the number of terms.
- Regular, when every term ends in `1`, `2` or `H` and d = A - (the newest term's year) is -1 or
  more. A term's slot is year x 3 + kind, with kind 0 for `1`, 1 for `2` and 2 for `H`.
  - `gamma(c)`: c is 1 for d = 0, 2 for d = -1, 3 for d = 1, and d + 2 for d >= 2.
  - `u(2)`: the newest term's kind (3 is malformed).
  - Then for each older term, `gamma(slot of the term before it - its slot)`.
- Explicit: for each term `u(10)` its year (999 at most) and `u(6)` its last character's index in
  `0-9A-Z`, strictly newest first. A list the regular layout can hold is malformed here.

##### 3. Student ID, 1 to 16 characters of `0-9A-Z`

- `u(1)`: 0 NTUST shape, 1 any other.
- NTUST shape: a letter, a 3-digit year that is not after the oldest term's year, and 5 digits.
  - The letter: `0` B, `10` M, `110` D, `111` then `u(5)` another letter (not B, M or D).
  - `gamma(oldest term's year - the ID's year + 1)`.
  - `u(17)`: the last 5 digits (99999 at most).
- Any other: `gamma(length)`, then `u(6)` for each character's index in `0-9A-Z`. An ID the NTUST
  shape can hold is malformed here.

##### 4. Departments

A course code is its head and its tail, the 6 or 7 characters of `0-9A-Z` after it. The head is
the first of these that fits: `3` and two letters (`3CS3003302`), two letters (`CS1001301`), or
`3` and one letter, the NTU and NTNU courses (`3N1004701`, `3T5287701`).

- `subset(known heads used, 56)`, as indices into this frozen list, the heads in NTUST's public
  course lists for 1121 to 1151 and 114H:
  `3N 3NG 3T 3TG AC AD AI AS AT BA BB BE CC CE CH CI CS CT CX DT EC EE EN EO EP ES ET FB FE FL FN GD GE
  HC IB IC IM IS MA MB ME MG MI PA PE RD SD SI TB TC TE TM TU TX VE ZA`
- `gamma(u + 1)`: the number of other heads, then `u(11)` each in ascending order, with A = 0:
  two letters are 26 x (first) + (second), `3` and two letters add 676, and `3` and one letter is
  1352 + the letter. 1378 or more, or a known head, is malformed.
- The head list H is the known heads in list order, then the other heads in ascending order. It
  is never empty.

##### 5. Which terms each head appears in

Only when there are 2 or more terms and 2 or more heads: for each head in H,
`subset(the terms it appears in, T)`, never empty, with 0 the newest term. A term left without a
head is malformed. Otherwise every head appears in every term.

##### 6. Courses

For each term, newest first:

- For each head present in the term, in H order, `gamma(its number of courses)`. A term holds 64
  courses at most.
- Then for each of those heads, its tails in ascending text order, each in the first shape that
  fits. A tail equal to or before the one before it is malformed, and so is a head and tail that
  split differently by the head rule above (head `3N` with tail `G115701` is `3NG115701`, whose
  head is `3NG`).

| Prefix | Tail shape | Example | Then |
|---|---|---|---|
| `0` | 4 digits, `3` or `7`, 2 digits from 01 | `1001301` | level, `u(10)` the other 3 digits, `u(1)` 0 for `3` and 1 for `7`, `gamma(last 2 digits)` |
| `100` | 3 digits, `A` or `B`, `0`, 2 digits from 01 | `130A001` | `u(10)` the 3 digits, `u(1)` 0 for `A`, `gamma(last 2 digits)` |
| `101` | `G`, 3 digits, `3`, 2 digits from 01 | `G015301` | `u(10)` the 3 digits, `gamma(last 2 digits)` |
| `110` | 3 digits, `7`, 2 digits from 01 | `115701` | `u(10)` the 3 digits, `gamma(last 2 digits)` |
| `1110` | any other 7 digits | `1001001` | `u(24)` the number |
| `1111` | anything else | `1A01B01` | `u(1)` length - 6, `u(6)` each character's index in `0-9A-Z` |

The level is the first of the 4 digits. A head's first `0`-shape tail in a term writes it as `0`
then `u(2)` for 1 to 4, `10` for 5, or `11` then `u(4)` for 0 and 6 to 9. A later `0`-shape tail
of that head in that term writes `0` for the same level as the previous `0`-shape tail, `10` for
one more, or `11` then the level as above for any other level.

A shape that fits but is written in a later shape, a `gamma` larger than its limit (24 terms, 64
courses, 99 for the last 2 digits) and any value beyond its range are malformed, so every class
table has exactly one code.

### Reading a share code

A decoder trims surrounding whitespace, upper-cases the text, and reports the first of these that
applies:

1. Neither the share host nor TAT's prefix below: not a share code, such as another app's QR
   code. A scanner skips it without a message.
2. On the share host, another type: a newer app's code.
3. On the share host but no `CLASSTABLE/` type: malformed.
4. A version from `2` to `9`: a newer version. Any other but `1`: malformed.
5. A character outside `0-9A-Z` or a Base36 group too large for its bits: malformed.
6. A checksum that differs from the one computed, checked before any field is read: a checksum
   mismatch.
7. A field that breaks the layout's rules: malformed. Every course a valid code decodes to has
   NTUST's shape.

The import screen asks for a newer app for a newer type or version
(`share_code_needs_update_message`, under the import-failed title) and shows one message for the
rest; the cases stay apart for tests and logs. A picture that holds no readable code but a newer
one asks for the update before calling another code in it damaged.

### Links

- The app claims the whole share host as Universal Links: `applinks:share.tigerduck.app` in
  `TigerDuck.entitlements` and `TigerDuck_Mac.entitlements`. The site's
  `apple-app-site-association` lists every path with `caseSensitive: false`, for
  `43UV8F72V6.org.ntust.app.TigerDuck`.
- `tigerduck://share/<rest>`, which the share page's button opens, stands for
  `https://share.tigerduck.app/<rest>`. The scheme and host are matched as written, as the widgets'
  links are.
- A link's query and fragment, which chat apps add (`?fbclid=...`), are dropped before decoding, as
  the share page reads only the path.
- Any web page or app can open a link, so a link goes through the import's usual confirmation,
  with the nickname and the replace prompt, and never imports by itself. A link on the share host
  the decoder does not take says the code is damaged, as no camera is there to try another.
- A link opens over the class table, with no camera, which would ask for permission first. One that
  arrives while an import is open replaces what the import shows, and its earlier lookup saves
  nothing.
- While another sheet or alert is open, a link waits for it to close: SwiftUI would close a sheet
  open in a tab to show the import's, and with it anything typed there.
- A link that arrives with no one signed in, or before onboarding finishes, is held in memory only
  (`HeldShareLink`), never on disk, and opens once both are done. A newer link replaces it, and a
  sign-out drops it.

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

Measured on 200 tables each, built from NTUST's public course lists, at error correction level M:

| | Packed | QR version |
|---|---|---|
| 1 term, 10 courses | 97 characters (103 at most) | 5 at most |
| 8 terms, 10 courses each | 353 (384 at most) | 11 on average, 12 at most |
| 8 x 10, course codes of random letters and digits | 724 (738 at most) | 18 at most |

The six-field layout the app wrote before took 183 characters for one term of 10 courses and 608
for 8 terms.

## Alternatives

- Course codes in clear, or compressed with DEFLATE and written in Base32, as versions 2.4.0 to
  2.6.x did: readable or simple, and nearly twice as long once a code holds several terms.
- Courses as indices into the term's course list: about 12 bits a course instead of about 15, but
  decoding would need the list from the network, and the share page decodes offline.
- Base45 (RFC 9285) or other QR characters: `$%*+-./:` and space are unsafe in a URL path, or get
  cut off at the end of a link by messengers.
- Class times in the code: they would draw a class table before the course query answers, but
  the importer needs the query for names and rooms anyway, and they lengthen the code.
- Only the QR code's own error correction: it repairs a damaged scan, but an edited code printed
  as a new QR code passes it.

## Consequences

- A layout change takes a new version number, and decoders keep reading version 1, which is
  handed out. A decoder that meets a newer version or type asks the user to update the app.
- The 56 known heads are frozen with version 1; a head added later costs 11 bits more a code.
- Codes from versions 2.4.0 to 2.6.x no longer import, in the app or on the share page.
- Whoever sees a share code learns its sharer's student ID and courses.
