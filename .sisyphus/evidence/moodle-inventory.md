# Moodle Network Call Inventory

Generated: 2026-04-21  
Source: MoodleService.swift (131 lines), SSOLoginService.swift (189 lines)

---

## Network Call Table

| file | line | url_pattern | return_type | consumers | webservice_replacement |
|------|------|-------------|-------------|-----------|----------------------|
| MoodleService.swift | 44 | `GET https://moodle2.ntust.edu.tw/login/index.php` | HTML page (sesskey extraction) | `fetchAssignments()` internal | N/A — sesskey scrape, no webservice equivalent |
| MoodleService.swift | 64 | `GET https://moodle2.ntust.edu.tw/login/index.php` (retry) | HTML page (sesskey extraction) | `fetchAssignments()` internal retry path | N/A — sesskey scrape, no webservice equivalent |
| MoodleService.swift | 79–86 | `POST https://moodle2.ntust.edu.tw/lib/ajax/service.php?sesskey=<sesskey>&info=core_calendar_get_action_events_by_timesort` | `[MoodleCalendarWrapper]` JSON | `fetchAssignments()` → `KMPServiceBridge.fetchAssignments()` → `CalendarViewModel.fetchMoodleEvents()` + `HomeViewModel` (via bridge) | `core_calendar_get_action_events_by_timesort` ✅ (already using this endpoint) |

---

## Call Flow Summary

```
CalendarViewModel.refresh()
  └─ fetchMoodleEvents(authService:)
       └─ KMPServiceBridge.fetchAssignments(authService:)
            └─ MoodleService.fetchAssignments(session:studentId:password:)
                 ├─ [auth check] SSOLoginService.ensureServiceLogin() if cookies invalid
                 ├─ GET moodle2.ntust.edu.tw/login/index.php  → extract sesskey
                 │    └─ [retry] ensureServiceLogin() + GET again if sesskey missing
                 └─ POST /lib/ajax/service.php?sesskey=...&info=core_calendar_get_action_events_by_timesort
                      └─ decode [MoodleCalendarWrapper] → filter assign events → [SDAssignment]

HomeViewModel (via KMPServiceBridge.fetchAssignments) also consumes the same path.
```

---

## SSOLoginService Moodle Footprint

**File:** `swift/TigerDuck/Services/Network/SSOLoginService.swift`  
**Moodle-specific code:** **None** — SSOLoginService is domain-agnostic.

The only Moodle reference is a comment at line 51:
```swift
// Step 4: Clear SSO cookies only (preserve Moodle/service cookies to avoid device-change warnings)
```

This comment documents intentional behavior: when re-authenticating via SSO, only `ssoam2.ntust.edu.tw` cookies are cleared. Moodle cookies (`moodle2.ntust.edu.tw`) are **preserved** to avoid triggering Moodle's device-change detection.

`SSOLoginService.ensureServiceLogin()` is called by `MoodleService.fetchAssignments()` with `serviceURL = moodleLoginURL` as the entry point, but the SSO service itself has no Moodle-specific logic.

---

## Webservice Replacement Analysis

| Current mechanism | Webservice equivalent | Status |
|---|---|---|
| Scrape `login/index.php` HTML for `sesskey` | N/A — sesskey is required for the AJAX endpoint | **Must keep** (or switch to token-based auth) |
| `POST /lib/ajax/service.php?info=core_calendar_get_action_events_by_timesort` | `core_calendar_get_action_events_by_timesort` | ✅ Already using the correct webservice function |
| Filter `modulename == "assign"` from calendar events | `mod_assign_get_assignments` | ⚠️ Could switch to dedicated assign endpoint for richer data |

### Known Webservice Mappings (from task spec)
- Assignments → `mod_assign_get_assignments` — **not currently used**; current code uses calendar events filtered by `modulename == "assign"`
- Calendar events → `core_calendar_get_action_events_by_timesort` — **currently used** ✅
- Course list → `core_enrol_get_users_courses` — **not used in MoodleService** (CourseService handles courses separately)
- Forum/announcements → `mod_forum_get_forum_discussions_paginated` — **not used anywhere**

---

## Notes

1. **Only one public function exists:** `MoodleService.fetchAssignments()` — the entire service is a single function.
2. **Sesskey scraping is unavoidable** with the current AJAX approach. The `service.php` endpoint requires a valid `sesskey` extracted from the authenticated HTML page. This is not replaceable with a webservice call — it's a prerequisite for calling the webservice.
3. **The calendar AJAX endpoint IS a Moodle webservice** — `core_calendar_get_action_events_by_timesort` is the official Moodle Mobile Web Service function. The current implementation already uses the correct function name.
4. **Assignment data is derived from calendar events**, not from `mod_assign_get_assignments`. This means assignment metadata (submission status, grade, etc.) is not available. Switching to `mod_assign_get_assignments` would require a token-based auth flow instead of cookie+sesskey.
5. **No Moodle calls exist outside MoodleService.swift** — confirmed by rg search across all Services/.
6. **`MoodleCalendarRequest` and `MoodleCalendarWrapper` models** are referenced but defined elsewhere (likely `MoodleAPIModels.swift` or similar).

---

## Task 6 Deletion Scope Recommendation

If Task 6 is "replace MoodleService with webservice API":
- **Delete:** `MoodleService.swift` entirely (131 lines, 1 public function)
- **Delete:** `MoodleServiceError` enum
- **Delete:** sesskey scraping logic (lines 43–73)
- **Keep/Replace:** The `core_calendar_get_action_events_by_timesort` call pattern — reuse in new implementation
- **Update:** `KMPServiceBridge.fetchAssignments()` (lines 146–171) to call new service
- **Update:** `CalendarViewModel.fetchMoodleEvents()` — no change needed if bridge interface stays same
- **Consider:** `MoodleCalendarWrapper`, `MoodleCalendarRequest` models — may need to keep or adapt for new auth flow
