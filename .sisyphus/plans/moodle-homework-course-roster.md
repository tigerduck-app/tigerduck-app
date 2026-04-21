# Moodle Homework + Unified Course Roster Migration

## TL;DR

> **Quick Summary**: Replace the calendar-events homework source with `mod_assign_*` APIs, add a NTUST-course-selection ∪ Moodle-enrolled-courses roster with current + past semester support, introduce a liquid-glass semester picker on the Class Table page, rename "待辦作業" to "作業" with a 全部/未完成 toggle on Home, and reorganize the network layer into `Services/API/...` domain folders.
>
> **Deliverables**:
> - Delete `core_calendar_get_action_events_by_timesort` entirely
> - Switch homework data source to `mod_assign_get_assignments` + `mod_assign_get_submission_status`
> - Add `core_enrol_get_users_courses` for OR-union course roster (captures audit/listener courses)
> - Semester-aware `DataCache` (`courses_<semester>.json`)
> - Liquid glass `.pickerStyle(.menu)` semester picker in Class Table
> - Home "作業" rename + segmented 全部/未完成 toggle, latest-semester-only
> - Folder reorg: `Services/API/{NTUST,Moodle,Library,Calendar}` + `Services/Core/`
> - One-shot section-title migration placed in `Services/Migrations/`
> - GPG-signed commits per phase
>
> **Estimated Effort**: Large
> **Parallel Execution**: YES — 3 waves
> **Critical Path**: Phase 0 POC → Phase 1 reorg → Phase 2 cache/union → Phase 5 homework switch → Phase 6 verify

---

## Context

### Original Request

User reported Moodle homework behavior is wrong on Swift. Progressive refinement:
1. "已經繳交的作業刷新後不消失" — fixed by diagnosis: calendar API does filter submitted work, but Swift's original mapping kept them visible due to stale cache logic
2. Asked which APIs Moodle offers for assignments, courses, discovery
3. Approved migrating off calendar API entirely
4. Added UI asks: semester picker on Class Table, 作業 rename + 全部/未完成 toggle on Home, best-practice network folder reorg

### Interview Summary

**Key Decisions**:
- **Delete** `core_calendar_get_action_events_by_timesort` — other Moodle APIs cover all use cases including Live Activity / reminders
- Semester picker must be **native iOS liquid glass** via `.pickerStyle(.menu)` — no hand-rolled styling
- Semester switch is **pure cache-read + silent background refresh** (open `courses_<semester>.json` immediately, network runs in background and silently overwrites if differs)
- Migration code (e.g. section title rename) **must live in `Services/Migrations/`**, not inline in feature code
- All commits **GPG-signed** via existing git config (already verified)

**Research Findings**:
- Token has 200+ functions available (confirmed via `core_webservice_get_site_info`); relevant ones:
  - Assignments: `mod_assign_get_assignments`, `mod_assign_get_submission_status`, `mod_assign_get_grades`
  - Enrolment: `core_enrol_get_users_courses`, `core_course_get_enrolled_courses_by_timeline_classification`
  - Discovery: `core_webservice_get_site_info`
- Moodle `idnumber` format for NTUST: `{4-digit-semester}{courseNo}` (e.g. `1142EC1013701`)
- `userid` required for `mod_assign_get_submission_status` and `core_enrol_get_users_courses` — get from `core_webservice_get_site_info`
- Home section titles persist in `Defaults[.homeSectionLayout]` → rename needs migration
- App uses `Defaults` library for UserDefaults; `AppConstants.UserDefaultsKeys` + `AppDefaults.swift` pattern

### Metis Review

**Identified Gaps** (addressed):
- Completion state previously derived from local override; now will come directly from server submission status
- Calendar API retention risk (now explicitly removed per user decision)
- Home section title migration risk (solved via dedicated migration file)
- Need token-memoized userid cache to avoid redundant `site_info` calls

---

## Work Objectives

### Core Objective

Migrate TigerDuck's Moodle integration from the single calendar-events probe to a proper assignment-domain API surface, producing a correct homework list driven by server-side submission state, an OR-union course roster covering audit courses, and semester-scoped UX throughout Class Table and Home.

### Concrete Deliverables

**Backend (POC validation only)**:
- `backend/api/moodle/site_info.py`
- `backend/api/moodle/enrolled_courses.py`
- `backend/api/moodle/assignments.py`
- `backend/api/moodle/submission_status.py`

**Swift production**:
- New `Services/API/{NTUST,Moodle,Library,Calendar}/` + `Services/Core/` folder structure
- New: `MoodleSiteInfoService`, `MoodleEnrolledCoursesService`, `MoodleAssignmentService` (replaces `MoodleAssignmentBridgeService`), `MoodleAPIModels`
- Split `CourseService` → `CourseSelectionService` + `CourseLookupService`
- `SDCourse.semester` field; `DataCache.saveCourses(_:semester:)` + `loadCourses(semester:) -> [SDCourse]`
- Updated `AppServiceBridge` (renamed from `KMPServiceBridge`): `fetchCourses(semester:)` with OR-union; `fetchAssignments()` via `mod_assign_*`
- `ClassTableView`: liquid-glass `.pickerStyle(.menu)` semester picker sharing the credits row, cache-first switch, background refresh, Defaults-persisted selection
- `HomeViewModel` + `HomeView`: "作業" rename, segmented 全部/未完成 toggle, latest-semester filter, two-stage fetch, cold-load shows cache instantly
- `Services/Migrations/HomeSectionTitleMigration.swift` — one-shot rename
- Regression tests in `swift/TigerDuckTests/MoodleHomeworkRegressionTests.swift`

**Deleted**:
- All code paths invoking `core_calendar_get_action_events_by_timesort`
- Orphaned Moodle models in `NTUSTAPIModels.swift`

### Definition of Done

- [ ] `xcodebuild test -project "swift/TigerDuck.xcodeproj" -scheme "TigerDuck" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` → `** TEST SUCCEEDED **`
- [ ] `rg "core_calendar_get_action_events_by_timesort" swift/ | wc -l` → 0
- [ ] `rg "core_calendar_get_action_events_by_timesort" backend/api | wc -l` → 1 (only the legacy `homework_sso.py`, already marked legacy)
- [ ] All new `.swift` files exist in the proposed folder layout; no stray Moodle code in `Bridge/` except orchestrator
- [ ] Each phase has an individual GPG-signed commit (verified via `git log --show-signature`)

### Must Have

- Homework list reflects real server submission status — submitted items disappear even without manual toggling
- Moodle-only enrolled courses (audit/listener) appear in Class Table when switched to the relevant semester
- Semester switch is instantaneous (cache read) with silent background update
- Current + past semester course data cached independently (`courses_1142.json`, `courses_1141.json`, ...)
- Home section is titled "作業" for both new installs and upgraders
- Picker uses native `.pickerStyle(.menu)` with no custom chrome
- All commits GPG-signed

### Must NOT Have (Guardrails)

- No call to `core_calendar_get_action_events_by_timesort` anywhere in Swift
- No inline section-title rename in `HomeViewModel` — migration must live in `Services/Migrations/`
- No hand-rolled picker styling / HStack chevron / custom background
- No past-semester courses leaking into `CanonicalCourseProvider` → Live Activity / reminders
- No additional `Task { }` spawned per-view — reuse existing orchestration entry points
- No removal of `legacy/homework_sso.py` (kept for A/B parity diff)
- No new dependencies added; `Defaults` lib already present, keep using it
- No commit without `-S` / GPG signature

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** — ALL verification is agent-executed.

### Test Decision

- **Infrastructure exists**: YES (Swift Testing via `@Test` already used in `swift/TigerDuckTests/`)
- **Automated tests**: YES (tests-after for most; TDD for pure-logic helpers)
- **Framework**: Swift Testing (`import Testing`, `#expect`)
- **Target**: `TigerDuckTests`

### QA Policy

Every task includes agent-executed QA. Evidence saved to `.sisyphus/evidence/task-{N}-{slug}.{ext}`.

- **Backend POC (Phase 0)**: `Bash` running `.venv/bin/python -m api.moodle.<module>`; stdout captured as JSON evidence
- **Swift logic**: `Bash` running `xcodebuild test ... -only-testing:TigerDuckTests/<TestSuite>`; log captured
- **Swift UI (picker, toggle)**: `xcodebuild test` covers view-model logic; Playwright/tmux not applicable to SwiftUI previews → rely on LSP diagnostics + test assertions on view-model state
- **Folder structure**: `Bash rg` / `fd` asserting presence/absence of files
- **GPG commits**: `Bash git log --show-signature -1` evidence per commit

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately — foundation + backend probing):
├── Task 1: Backend POC: site_info + enrolled_courses [quick]
├── Task 2: Backend POC: assignments + submission_status [quick]
└── Task 3: Swift folder restructure (file moves + rename KMPServiceBridge) [unspecified-high]

Wave 2 (After Wave 1 — semester-aware cache + services):
├── Task 4: SDCourse.semester + semester-scoped DataCache [deep]
├── Task 5: MoodleSiteInfoService (userid memoization) [quick]
├── Task 6: MoodleEnrolledCoursesService [quick]
├── Task 7: Split CourseService into CourseSelectionService + CourseLookupService [quick]
├── Task 8: MoodleAssignmentService (new mod_assign_* path) [deep]
└── Task 9: Consolidate MoodleAPIModels, purge orphaned calendar DTOs [quick]

Wave 3 (After Wave 2 — orchestration + UI + migration):
├── Task 10: AppServiceBridge.fetchCourses(semester:) union merge [deep]
├── Task 11: AppServiceBridge.fetchAssignments() via mod_assign_* + DELETE calendar path [deep]
├── Task 12: ClassTable picker (liquid glass) + Defaults persistence + warm cache [visual-engineering]
├── Task 13: Home 作業 rename + toggle + two-stage fetch + latest-semester filter [visual-engineering]
├── Task 14: HomeSectionTitleMigration (Services/Migrations/) [quick]
├── Task 15: CanonicalCourseProvider current-semester scope [quick]
└── Task 16: Regression tests (MoodleHomeworkRegressionTests additions) [unspecified-high]

Wave FINAL (After ALL tasks — 4 parallel reviews, then user okay):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Code quality review (unspecified-high)
├── Task F3: Real manual QA (unspecified-high)
└── Task F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay

Critical Path: 1 → 4 → 8 → 11 → 13 → F1-F4 → user okay
Parallel Speedup: ~55% vs sequential
Max Concurrent: 6 (Wave 2), 7 (Wave 3)
```

### Dependency Matrix

- **1, 2**: — → 3, 5, 6, 8
- **3**: — → 4, 5, 6, 7, 8, 9 (folder layout must exist first)
- **4**: 3 → 10, 11, 12, 15
- **5**: 1, 3 → 6, 8
- **6**: 1, 5 → 10
- **7**: 3 → 10
- **8**: 2, 5 → 11
- **9**: 3 → 11
- **10**: 4, 6, 7 → 12
- **11**: 4, 8, 9 → 13, 15, 16
- **12**: 4, 10 → 16
- **13**: 11, 14 → 16
- **14**: 3 → 13
- **15**: 4, 11 → 16
- **16**: 11, 12, 13, 15 → F1-F4

### Agent Dispatch Summary

- **Wave 1**: **3** — T1, T2 → `quick`, T3 → `unspecified-high`
- **Wave 2**: **6** — T4, T8 → `deep`, T5-T7, T9 → `quick`
- **Wave 3**: **7** — T10, T11 → `deep`, T12, T13 → `visual-engineering`, T14, T15 → `quick`, T16 → `unspecified-high`
- **FINAL**: **4** — F1 → `oracle`, F2, F3 → `unspecified-high`, F4 → `deep`

---

## TODOs

- [ ] 1. Backend POC — `site_info` + `enrolled_courses`

  **What to do**:
  - Create `backend/api/moodle/site_info.py` that calls `core_webservice_get_site_info` and prints JSON to stdout
  - Create `backend/api/moodle/enrolled_courses.py` that chains `site_info` → `core_enrol_get_users_courses(userid=...)` and prints the course list JSON
  - Both scripts reuse `MoodleOidcAuthClient` from `api.moodle.auth`; no new deps
  - Run each via `uv run python -m api.moodle.site_info` and `uv run python -m api.moodle.enrolled_courses`, capture stdout to `.sisyphus/evidence/task-1-*.json`

  **Must NOT do**:
  - Do not modify `api.moodle.auth` or touch Swift code
  - Do not call `core_calendar_get_action_events_by_timesort`
  - Do not print credentials

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Two small scripts; template already exists in `api.moodle.homework`
  - **Skills**: `git-master`
    - `git-master`: commit scripts per phase with GPG sign

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Task 2, 3)
  - **Blocks**: 5, 6, 8
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `backend/api/moodle/homework.py:1-52` — shape of a Moodle wsfunction probe script
  - `backend/api/moodle/auth.py:140-150` — `MoodleOidcAuthClient.call(wsfunction, **args)` interface
  - `backend/api/AGENTS.md:29-42` — running convention (`uv run python -m api.moodle.<module>`)

  **API/Type References**:
  - `core_webservice_get_site_info` → `{userid, functions[], sitename, release, ...}`
  - `core_enrol_get_users_courses(userid)` → `[{id, fullname, idnumber, shortname, startdate, enddate, ...}]`

  **WHY Each Reference Matters**:
  - `homework.py` is the exact template to copy (structure, `main()`, error handling). Do not invent a new pattern.
  - `auth.py:140` is how to call any wsfunction — no new HTTP code needed.

  **Acceptance Criteria**:

  **If TDD**: N/A (shell scripts only)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Site info returns userid + functions list
    Tool: Bash
    Preconditions: backend/.env contains valid NTUST credentials; `uv sync` previously run
    Steps:
      1. Run: uv run python -m api.moodle.site_info > /tmp/site_info.json
      2. Verify exit code == 0
      3. jq '.userid' /tmp/site_info.json → must be a positive integer
      4. jq '.functions | length' /tmp/site_info.json → must be > 100
      5. jq -r '.functions[].name' /tmp/site_info.json | grep -qx mod_assign_get_assignments
      6. jq -r '.functions[].name' /tmp/site_info.json | grep -qx core_enrol_get_users_courses
    Expected Result: userid is int; functions list contains both mod_assign_get_assignments and core_enrol_get_users_courses
    Failure Indicators: userid missing, non-integer, or list omits either required function
    Evidence: .sisyphus/evidence/task-1-site-info.json

  Scenario: Enrolled courses returns idnumber in expected format
    Tool: Bash
    Preconditions: Same as above
    Steps:
      1. Run: uv run python -m api.moodle.enrolled_courses > /tmp/courses.json
      2. Verify exit code == 0
      3. jq '. | length' /tmp/courses.json → must be > 0
      4. jq -r '.[].idnumber' /tmp/courses.json | head -1 | grep -E '^[0-9]{4}[A-Z]{2}[A-Z0-9]{6,7}$'
    Expected Result: Returns ≥1 course; first idnumber matches {4-digit}{course-code} format
    Failure Indicators: Empty array, non-matching idnumber, or missing idnumber field
    Evidence: .sisyphus/evidence/task-1-enrolled-courses.json
  ```

  **Commit**: YES (groups with Task 2)
  - Message: `feat(Backend): add Moodle assignment/course POC probes`
  - Files: `backend/api/moodle/site_info.py`, `enrolled_courses.py`, `assignments.py`, `submission_status.py`
  - Pre-commit: `uv run python -m api.moodle.site_info > /dev/null` (sanity smoke)
  - **GPG**: `git commit -S`

---

- [ ] 2. Backend POC — `assignments` + `submission_status`

  **What to do**:
  - Create `backend/api/moodle/assignments.py` calling `mod_assign_get_assignments` with optional `courseids[]`
  - Create `backend/api/moodle/submission_status.py` calling `mod_assign_get_submission_status(assignid=, userid=)`; when invoked without arg, resolve the first assignment id from `assignments.py` for smoke use
  - Both scripts print JSON to stdout

  **Must NOT do**:
  - Do not call calendar APIs
  - Do not hardcode credentials

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Symmetrical probe scripts, template is `api.moodle.homework`
  - **Skills**: `git-master`

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 1, 3)
  - **Parallel Group**: Wave 1
  - **Blocks**: 8
  - **Blocked By**: None

  **References**:
  - `backend/api/moodle/homework.py` — probe template
  - `backend/api/moodle/auth.py:140` — webservice call interface
  - `mod_assign_get_assignments` response: `{courses: [{id, fullname, assignments: [{id, cmid, name, duedate, allowsubmissionsfromdate, grade, intro, nosubmissions}]}]}`
  - `mod_assign_get_submission_status` response: `{lastattempt: {submission: {status, timemodified}, gradingstatus, ...}, feedback, warnings}`

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Assignments probe returns courses + assignments arrays
    Tool: Bash
    Preconditions: valid creds
    Steps:
      1. uv run python -m api.moodle.assignments > /tmp/assign.json
      2. jq '.courses | length' /tmp/assign.json → > 0
      3. jq '[.courses[].assignments[]] | length' /tmp/assign.json → > 0
      4. jq '.courses[0].assignments[0] | keys' /tmp/assign.json → contains "id", "duedate", "name"
    Expected Result: ≥1 course with ≥1 assignment; expected keys present
    Failure Indicators: Empty courses, missing keys, errorcode field present
    Evidence: .sisyphus/evidence/task-2-assignments.json

  Scenario: Submission status probe returns lastattempt object
    Tool: Bash
    Preconditions: valid creds + at least 1 assignment exists
    Steps:
      1. uv run python -m api.moodle.submission_status > /tmp/status.json
      2. Verify exit code == 0
      3. jq '.lastattempt' /tmp/status.json → not null
      4. jq '.lastattempt.submission.status // empty' /tmp/status.json → string value
    Expected Result: Non-null lastattempt object with readable submission.status
    Failure Indicators: null lastattempt, errorcode field, non-zero exit
    Evidence: .sisyphus/evidence/task-2-submission-status.json
  ```

  **Commit**: Grouped with Task 1 (`feat(Backend): add Moodle assignment/course POC probes`)

---

- [ ] 3. Swift folder restructure — move files into `Services/API/{NTUST,Moodle,Library,Calendar}` + `Services/Core/`, rename `KMPServiceBridge` → `AppServiceBridge`

  **What to do**:
  - Create folders in Xcode project (groups must map to filesystem): `Services/API/NTUST`, `Services/API/Moodle`, `Services/API/Library`, `Services/API/Calendar`, `Services/Core`
  - Move files (update both filesystem and Xcode project references in `swift/TigerDuck.xcodeproj/project.pbxproj`):
    - `Services/Network/NTUSTSessionManager.swift` → `Services/API/NTUST/`
    - `Services/Network/SSOLoginService.swift` → `Services/API/NTUST/`
    - `Services/Network/CourseService.swift` → `Services/API/NTUST/` (will split in Task 7)
    - `Services/Network/NTUSTAPIModels.swift` → `Services/API/NTUST/` (will clean in Task 9)
    - `Services/Network/LibraryService.swift` → `Services/API/Library/`
    - `Services/Network/LibraryAPIModels.swift` → `Services/API/Library/`
    - `Services/Network/CalendarService.swift` → `Services/API/Calendar/`
    - `Services/Network/DataCache.swift` → `Services/Core/`
    - `Services/Network/NetworkMonitor.swift` → `Services/Core/`
    - `Services/Network/HTMLParser.swift` → `Services/Core/`
    - `Services/Auth/MoodleTokenService.swift` → `Services/API/Moodle/`
    - `Services/Auth/MoodleWebserviceError.swift` → `Services/API/Moodle/`
    - `Bridge/MoodleAssignmentBridgeService.swift` → `Services/API/Moodle/MoodleAssignmentService.swift` (rename + move; body changes come in Task 8)
  - Rename `Bridge/KMPServiceBridge.swift` → `Bridge/AppServiceBridge.swift` (enum rename `enum KMPServiceBridge` → `enum AppServiceBridge`; update all call sites)
  - NO behavior changes in this task — pure moves + rename

  **Must NOT do**:
  - Do not change any logic or function signatures
  - Do not touch test target in this task
  - Do not delete anything yet (calendar API removal happens in Task 11)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Needs careful `project.pbxproj` editing; high churn, low logic
  - **Skills**: `git-master`

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 1 with Task 1, 2)
  - **Blocks**: 4, 5, 6, 7, 8, 9
  - **Blocked By**: None

  **References**:
  - `swift/TigerDuck/Services/AGENTS.md` — current layout conventions
  - `swift/TigerDuck.xcodeproj/project.pbxproj` — add/rename/remove PBXFileReference and PBXGroup entries
  - `swift/TigerDuck/Bridge/KMPServiceBridge.swift` — every static method is called via `KMPServiceBridge.xxx(...)`; grep & rename callers

  **WHY Each Reference Matters**:
  - `project.pbxproj` is not auto-managed; moving files on disk without updating the pbxproj will break the build
  - AGENTS.md conventions must be respected (shared session, DataCache, AppLogger)

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Project still builds cleanly after reorg
    Tool: Bash
    Preconditions: clean working tree
    Steps:
      1. xcodebuild build -project "swift/TigerDuck.xcodeproj" -scheme "TigerDuck" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | tee /tmp/build.log
      2. grep -q "BUILD SUCCEEDED" /tmp/build.log
      3. rg "KMPServiceBridge" swift/TigerDuck | wc -l → 0 (all renamed)
      4. rg "AppServiceBridge" swift/TigerDuck | wc -l → > 0
    Expected Result: BUILD SUCCEEDED; no stale references; Bridge/AppServiceBridge.swift exists
    Failure Indicators: build failure, any remaining KMPServiceBridge reference
    Evidence: .sisyphus/evidence/task-3-build.log

  Scenario: All expected files exist in new locations
    Tool: Bash
    Steps:
      1. test -f swift/TigerDuck/Services/API/NTUST/NTUSTSessionManager.swift
      2. test -f swift/TigerDuck/Services/API/Moodle/MoodleTokenService.swift
      3. test -f swift/TigerDuck/Services/API/Moodle/MoodleAssignmentService.swift
      4. test -f swift/TigerDuck/Services/Core/DataCache.swift
      5. test -f swift/TigerDuck/Bridge/AppServiceBridge.swift
      6. ! test -f swift/TigerDuck/Bridge/MoodleAssignmentBridgeService.swift
      7. ! test -f swift/TigerDuck/Bridge/KMPServiceBridge.swift
    Expected Result: All test commands exit 0
    Failure Indicators: Any file in wrong location
    Evidence: .sisyphus/evidence/task-3-layout.txt
  ```

  **Commit**: YES
  - Message: `refactor(Services): reorganize network layer into Services/API domain folders`
  - Files: all moved files + `swift/TigerDuck.xcodeproj/project.pbxproj`
  - Pre-commit: xcodebuild build succeeds
  - **GPG**: `git commit -S`

---

- [ ] 4. `SDCourse.semester` + semester-scoped `DataCache`

  **What to do**:
  - Add `var semester: String` to `SDCourse` (`Models/SwiftData/SDCourse.swift`); default empty string; update `init(...)` to accept `semester: String = ""`
  - Add `semester: String?` to `CachedCourse` DTO in `DataCache.swift` (optional for back-compat decode)
  - Replace `saveCourses(_:)` / `loadCourses()` with `saveCourses(_:semester:)` / `loadCourses(semester:) -> [SDCourse]`; filename becomes `courses_<semester>.json`
  - Update `clearUserScopedData()` to glob-delete all `courses_*.json` + `assignments.json` + other existing entries
  - Migration: if legacy `courses.json` exists on load with no semester filter, one-shot read + rewrite into `courses_<currentSemester>.json`, then delete legacy (keep this migration inside DataCache init for now; document as "legacy cache absorb" — not the Home section rename which stays in Migrations/)
  - Update every call site: `HomeViewModel`, `ClassTableViewModel`, `CanonicalCourseProvider`, `AppServiceBridge`
  - Initially all call sites pass `CourseService.currentSemesterCode()`; semester awareness gets wired in Wave 3

  **Must NOT do**:
  - Do not remove `assignments.json` handling (no semester split for assignments)
  - Do not add semester to `SDAssignment`
  - Do not break existing SwiftData migrations (test that `sharedModelContainer` still boots)

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Touches models + cache + many call sites; needs careful migration handling

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 5-9)
  - **Blocks**: 10, 11, 12, 15
  - **Blocked By**: 3

  **References**:
  - `swift/TigerDuck/Services/Core/DataCache.swift` (post-move location) — `save<T>(_:to:)` / `load<T>(from:)` helpers
  - `swift/TigerDuck/Models/SwiftData/SDCourse.swift` — current init signature
  - `swift/TigerDuck/Bridge/AppServiceBridge.swift:125-149` (post-rename) — cache write site

  **Acceptance Criteria**:

  **If TDD**:
  - [ ] Add test: `saveCourses([a, b], semester: "1142")` followed by `loadCourses(semester: "1142")` returns [a, b]
  - [ ] Add test: `saveCourses([], semester: "1141")` does not affect "1142" bucket
  - [ ] Add test: legacy `courses.json` present → absorb migration writes `courses_<current>.json` and removes legacy file

  **QA Scenarios**:

  ```
  Scenario: Semester isolation — saving 1141 does not affect 1142
    Tool: Bash (xcodebuild test)
    Steps:
      1. xcodebuild test ... -only-testing:TigerDuckTests/MoodleHomeworkRegressionTests/semester_cache_isolation
    Expected Result: test passes
    Evidence: .sisyphus/evidence/task-4-semester-isolation.log

  Scenario: Legacy absorb — courses.json becomes courses_<current>.json
    Tool: Bash (xcodebuild test)
    Steps:
      1. Test fixture: write a legacy courses.json into a tmp caches dir
      2. Trigger DataCache init
      3. Assert: courses_<current>.json exists with same contents; courses.json removed
    Evidence: .sisyphus/evidence/task-4-legacy-absorb.log
  ```

  **Commit**: YES (groups with Task 7)
  - Message: `feat(DataCache): make course cache semester-aware`

---

- [ ] 5. `MoodleSiteInfoService` (userid memoization)

  **What to do**:
  - Create `Services/API/Moodle/MoodleSiteInfoService.swift` as an `actor`
  - Expose `func userId() async throws -> Int` (memoized per token; reset on `MoodleTokenService.clearToken()`)
  - Expose `func siteInfo() async throws -> SiteInfo` returning typed DTO
  - Internally call `core_webservice_get_site_info` via shared webservice session (same UA as `MoodleAssignmentService`)

  **Must NOT do**:
  - Do not persist userid to Keychain/Defaults (in-memory memo is enough; token rotation invalidates it)
  - Do not log raw session tokens

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Small actor wrapping one wsfunction

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Blocks**: 6, 8
  - **Blocked By**: 1, 3

  **References**:
  - `backend/api/moodle/site_info.py` — reference payload shape (from Task 1 evidence)
  - `swift/TigerDuck/Services/API/Moodle/MoodleTokenService.swift` — actor pattern example
  - `swift/TigerDuck/Services/API/Moodle/MoodleWebserviceError.swift` — error enum to reuse

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Concurrent callers share the same memoized userId
    Tool: Bash (xcodebuild test)
    Steps:
      1. Spawn 5 concurrent Task{} calling MoodleSiteInfoService.shared.userId()
      2. Assert all return the same Int
      3. Assert the underlying wsfunction was called only once (verified via stubbed session)
    Evidence: .sisyphus/evidence/task-5-memoization.log
  ```

  **Commit**: YES (groups with Tasks 6, 8, 9)
  - Message: `feat(Moodle): add site-info, enrolled-courses, assignment services; consolidate DTOs`

---

- [ ] 6. `MoodleEnrolledCoursesService`

  **What to do**:
  - Create `Services/API/Moodle/MoodleEnrolledCoursesService.swift`
  - Expose `func fetchEnrolled() async throws -> [MoodleEnrolledCourse]` using `core_enrol_get_users_courses(userid:)`
  - `MoodleEnrolledCourse` struct in `MoodleAPIModels.swift` with: `id`, `fullname`, `idnumber`, `shortname`, `startdate`, `enddate`, plus computed `courseNo` + `semester` (parsed from idnumber via `SDCourse.courseNoFromMoodleId` logic)
  - Use `MoodleSiteInfoService.shared.userId()` for userid

  **Must NOT do**:
  - Do not duplicate site-info calls; always go through `MoodleSiteInfoService`
  - Do not filter at this layer (caller decides current vs past)

  **Recommended Agent Profile**:
  - **Category**: `quick`

  **Parallelization**:
  - **Blocks**: 10
  - **Blocked By**: 1, 5

  **References**:
  - `backend/api/moodle/enrolled_courses.py` — payload shape (Task 1 evidence)
  - `swift/TigerDuck/Models/SwiftData/SDCourse.swift:137-143` — `courseNoFromMoodleId` format handling

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Parses idnumber into courseNo + semester correctly
    Tool: Bash (xcodebuild test)
    Steps:
      1. Stub payload: [{idnumber: "1142EC1013701", fullname: "..."}]
      2. fetchEnrolled returns [MoodleEnrolledCourse(courseNo: "EC1013701", semester: "1142", ...)]
    Evidence: .sisyphus/evidence/task-6-parse.log

  Scenario: Empty idnumber is preserved (not silently dropped)
    Tool: Bash (xcodebuild test)
    Steps:
      1. Stub payload: [{idnumber: "", fullname: "special"}]
      2. fetchEnrolled returns entry with courseNo == ""
      3. Downstream merge decides what to do
    Evidence: .sisyphus/evidence/task-6-empty-idnumber.log
  ```

  **Commit**: Grouped

---

- [ ] 7. Split `CourseService` → `CourseSelectionService` + `CourseLookupService`

  **What to do**:
  - Create `Services/API/NTUST/CourseSelectionService.swift` with: `fetchEnrolledCourseNos(session:studentId:password:forceRefresh:)`, `currentSemesterCode()`, 24h UserDefaults cache helpers
  - Create `Services/API/NTUST/CourseLookupService.swift` with: `lookupCourse(semester:courseNo:)`, `searchCourses(...)`, `parseNodeToSchedule(_:)`
  - Delete `Services/API/NTUST/CourseService.swift`
  - Update every call site in `AppServiceBridge`, `AddCourseSheet`, `ClassTableViewModel`, etc., replacing `CourseService.xxx` with the right split-target (most reads land on `CourseSelectionService`)

  **Must NOT do**:
  - Do not change parameter order or argument names of the kept functions
  - Do not change caching behavior (same keys, same TTL)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Mechanical split; mostly mv + rename

  **Parallelization**:
  - **Blocks**: 10
  - **Blocked By**: 3

  **References**:
  - `swift/TigerDuck/Services/API/NTUST/CourseService.swift` — source to split
  - Call sites identified via `rg "CourseService\." swift/`

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Build succeeds after split
    Tool: Bash
    Steps:
      1. xcodebuild build -project "swift/TigerDuck.xcodeproj" -scheme "TigerDuck" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
      2. rg "CourseService\.fetchEnrolledCourseNos" swift/TigerDuck → no matches (all routed through CourseSelectionService)
    Evidence: .sisyphus/evidence/task-7-build.log
  ```

  **Commit**: Grouped with Task 4
  - Message: `feat(DataCache): make course cache semester-aware`

---

- [ ] 8. `MoodleAssignmentService` (new `mod_assign_*` path, NO calendar API)

  **What to do**:
  - Rewrite `Services/API/Moodle/MoodleAssignmentService.swift` (was `MoodleAssignmentBridgeService`):
    - `func fetchAssignments(courseIds: [Int]) async throws -> [MoodleAssignmentRecord]` — calls `mod_assign_get_assignments` with `courseids[]`
    - `func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus` — calls `mod_assign_get_submission_status(assignid:, userid:)` using `MoodleSiteInfoService`
  - `MoodleAssignmentRecord` (in `MoodleAPIModels.swift`): `assignId`, `cmId`, `courseId`, `courseNo`, `name`, `dueDate: Date?`, `allowSubmissionsFromDate: Date?`, `intro`, `grade`
  - `MoodleSubmissionStatus`: `status: String` (submitted/draft/new/reopened), `gradingStatus: String`, `timemodified: Date?`, `isSubmitted: Bool` (derived)
  - Token refresh retry on `MoodleWebserviceError.invalidToken` (same pattern as current)
  - Use the shared webservice session (pattern already in old `MoodleAssignmentBridgeService`)

  **Must NOT do**:
  - Do not call `core_calendar_get_action_events_by_timesort`
  - Do not fall back to cache inside the service; `AppServiceBridge` owns fallback
  - Do not hardcode `userid`; always go through `MoodleSiteInfoService`

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Core rewrite, critical behavior

  **Parallelization**:
  - **Blocks**: 11
  - **Blocked By**: 2, 5

  **References**:
  - `backend/api/moodle/assignments.py` — payload shape (Task 2 evidence)
  - `backend/api/moodle/submission_status.py` — payload shape (Task 2 evidence)
  - `swift/TigerDuck/Services/API/Moodle/MoodleAssignmentService.swift` (post-move, pre-rewrite) — token retry pattern
  - `swift/TigerDuck/Services/API/Moodle/MoodleWebserviceError.swift` — error enum

  **WHY Each Reference Matters**:
  - The POC evidence shows exact field names; match them to avoid decode mismatch
  - Token retry is already battle-tested; preserve its structure

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: fetchAssignments returns records for given courseIds
    Tool: Bash (xcodebuild test)
    Steps:
      1. Stub response: { courses: [{id: 1, assignments: [{id: 99, cmid: 100, name: "HW1", duedate: 1777350000}]}] }
      2. fetchAssignments(courseIds: [1]) returns [MoodleAssignmentRecord(assignId: 99, cmId: 100, name: "HW1", dueDate: ...)]
    Evidence: .sisyphus/evidence/task-8-fetch.log

  Scenario: fetchSubmissionStatus returns isSubmitted=true for "submitted" status
    Tool: Bash (xcodebuild test)
    Steps:
      1. Stub: { lastattempt: { submission: { status: "submitted", timemodified: 1 }}}
      2. fetchSubmissionStatus(assignId: 99).isSubmitted → true
      3. Stub status "new" → isSubmitted false
      4. Stub status "draft" → isSubmitted false (draft is NOT submitted)
    Evidence: .sisyphus/evidence/task-8-status.log

  Scenario: Token refresh retry on invalidToken
    Tool: Bash (xcodebuild test)
    Steps:
      1. First call throws MoodleWebserviceError.invalidToken
      2. clearToken + refreshTokenIfNeeded expected
      3. Second call succeeds
    Evidence: .sisyphus/evidence/task-8-retry.log
  ```

  **Commit**: Grouped with Tasks 5, 6, 9

---

- [ ] 9. Consolidate `MoodleAPIModels` + purge orphaned calendar DTOs

  **What to do**:
  - Create `Services/API/Moodle/MoodleAPIModels.swift` containing: `MoodleEnrolledCourse`, `MoodleAssignmentRecord`, `MoodleSubmissionStatus`, `MoodleCourseInfo` (shared), plus the wire-level decodable DTOs mapped to these domain types
  - Delete orphaned types in `Services/API/NTUST/NTUSTAPIModels.swift`: `MoodleCalendarWrapper`, `MoodleCalendarData`, `MoodleCalendarRequest`, `MoodleCalendarArgs`, `MoodleEvent`, `MoodleAction`, `MoodleCourseInfo` (if it lived there)
  - Move/replace any reference to these orphans (e.g. in `CalendarViewModel` if still present) to the new types or delete if unused

  **Must NOT do**:
  - Do not leave any `MoodleCalendar*` types in NTUST models file
  - Do not break `LibraryAPIModels.swift`

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Clean-up task

  **Parallelization**:
  - **Blocks**: 11
  - **Blocked By**: 3

  **References**:
  - `swift/TigerDuck/Services/API/NTUST/NTUSTAPIModels.swift` — types to purge
  - `rg "MoodleCalendar|MoodleEvent|MoodleAction" swift/` — every caller

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Orphan types eliminated
    Tool: Bash
    Steps:
      1. rg "MoodleCalendarWrapper|MoodleCalendarData|MoodleCalendarRequest|MoodleCalendarArgs" swift/ → no matches
      2. rg "struct MoodleEvent" swift/ → no matches
      3. xcodebuild build ... → BUILD SUCCEEDED
    Evidence: .sisyphus/evidence/task-9-purge.log
  ```

  **Commit**: Grouped

---

- [ ] 10. `AppServiceBridge.fetchCourses(semester:)` OR-union merge

  **What to do**:
  - Update `Bridge/AppServiceBridge.fetchCourses(authService:semester:forceRefresh:)`:
    - If `semester == currentSemesterCode()`: fetch Source A (course-selection) + Source C (Moodle enrolled)
    - Else: fetch Source C only (past semesters, course-selection unavailable)
    - Union by `courseNo`
    - For each courseNo: call `CourseLookupService.lookupCourse(semester:courseNo:)` for details
    - If lookup returns empty but course is from Moodle: build minimal `SDCourse` with `moodleFullname`, empty schedule
    - Save to `DataCache.saveCourses(_, semester: target)` only when login generation hasn't moved
  - Add a new orchestrator `warmAllSemesterCaches(authService:)` that iterates over all `availableSemesters` and calls `fetchCourses(semester:)` for each (fires from first Class Table page appear, see Task 12)

  **Must NOT do**:
  - Do not write to cache if `Task.isCancelled` or `loginGeneration` moved
  - Do not call Moodle enrolled courses more than once per `warmAllSemesterCaches` invocation (cache the service result in a local var across the loop)

  **Recommended Agent Profile**:
  - **Category**: `deep`

  **Parallelization**:
  - **Blocks**: 12
  - **Blocked By**: 4, 6, 7

  **References**:
  - `swift/TigerDuck/Bridge/AppServiceBridge.swift` (post-rename) — current fetchCourses flow
  - `swift/TigerDuck/Services/API/NTUST/CourseLookupService.swift` — lookup entrypoint

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Moodle-only course appears in roster
    Tool: Bash (xcodebuild test)
    Steps:
      1. Stub: course-selection returns ["EC1013701"]; Moodle returns ["EC1013701", "AUDIT123"]
      2. fetchCourses(semester: "1142") returns 2 SDCourse with courseNos {EC1013701, AUDIT123}
    Evidence: .sisyphus/evidence/task-10-union.log

  Scenario: Past semester skips course-selection scrape
    Tool: Bash (xcodebuild test)
    Steps:
      1. Stub: Moodle returns [{idnumber: "1141OLD12345"}]
      2. fetchCourses(semester: "1141") does NOT call fetchEnrolledCourseNos
      3. Returns minimal SDCourse for OLD12345 (lookup not available → fallback)
    Evidence: .sisyphus/evidence/task-10-past.log

  Scenario: warmAllSemesterCaches populates every bucket
    Tool: Bash (xcodebuild test)
    Steps:
      1. availableSemesters = ["1142","1141","1132","1131"]
      2. After warmAllSemesterCaches, courses_1142.json, courses_1141.json, courses_1132.json, courses_1131.json all exist
    Evidence: .sisyphus/evidence/task-10-warm.log
  ```

  **Commit**: Grouped with Task 11, 15
  - Message: `feat(Bridge): implement course OR-union and mod_assign_* homework fetch; drop calendar API`

---

- [ ] 11. `AppServiceBridge.fetchAssignments()` via `mod_assign_*` + DELETE calendar API path

  **What to do**:
  - Rewrite `AppServiceBridge.fetchAssignments(authService:)`:
    1. Resolve current-semester courses from `DataCache.loadCourses(semester: currentSemesterCode())`
    2. Call `MoodleAssignmentService.fetchAssignments(courseIds: <current course ids>)`
    3. For each returned `MoodleAssignmentRecord`, call `fetchSubmissionStatus` in parallel (TaskGroup with bounded concurrency)
    4. Map to `SDAssignment`:
       - `assignmentId = String(record.assignId)`
       - `isCompleted = status.isSubmitted`
       - `dueDate = record.dueDate ?? distantFuture` (skip rather than 1970 fallback)
       - `courseNo` resolved from course list
       - `moodleUrl = "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=\(record.cmId)"`
    5. Save via `DataCache.saveAssignments(merged)` (no per-semester split; assignments stay in single file)
  - DELETE every call-site for `core_calendar_get_action_events_by_timesort`:
    - Remove the entire old `fetchActionEvents` code path in `MoodleAssignmentService.swift`
    - Update `LiveActivityScenarioResolver` + `AssignmentReminderScheduler` to consume the new `SDAssignment` (they already do; nothing to rewire if mapping preserves fields)
  - Preserve the `preserveCompletionState` helper as a defensive merge when submission_status calls partially fail (e.g. retry that still times out)

  **Must NOT do**:
  - Do not retain any calendar API constant, URL, or WSFUNCTION string
  - Do not degrade to cache without logging
  - Do not break existing assignment-related unit tests (update them instead)

  **Recommended Agent Profile**:
  - **Category**: `deep`

  **Parallelization**:
  - **Blocks**: 13, 15, 16
  - **Blocked By**: 4, 8, 9

  **References**:
  - `swift/TigerDuck/Services/API/Moodle/MoodleAssignmentService.swift` (Task 8 output)
  - `swift/TigerDuck/LiveActivity/Resolvers/LiveActivityScenarioResolver.swift:121` — existing SDAssignment consumer
  - `swift/TigerDuck/LiveActivity/Scheduling/AssignmentReminderScheduler.swift:138-146` — existing consumer
  - `swift/TigerDuck/Features/Home/HomeViewModel.swift` — upcoming filter logic

  **WHY Each Reference Matters**:
  - LA + reminder consumers must keep working via the new source; don't break the contract

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Submitted assignment disappears from upcomingSorted
    Tool: Bash (xcodebuild test)
    Steps:
      1. Stub mod_assign_get_assignments returns 2 assignments (A, B)
      2. Stub submission_status: A=submitted, B=new
      3. fetchAssignments → [SDAssignment A (isCompleted=true), SDAssignment B (isCompleted=false)]
      4. merged.upcomingSorted().map(\.assignmentId) → [B only]
    Evidence: .sisyphus/evidence/task-11-submitted-hidden.log

  Scenario: Calendar API completely removed
    Tool: Bash
    Steps:
      1. rg "core_calendar_get_action_events_by_timesort" swift/ → 0 matches
      2. rg "actionEventsFunction" swift/ → 0 matches
    Evidence: .sisyphus/evidence/task-11-calendar-gone.log

  Scenario: Live Activity consumer still compiles + produces output
    Tool: Bash (xcodebuild test)
    Steps:
      1. xcodebuild build ... → BUILD SUCCEEDED
      2. Run LiveActivityScenarioResolver tests if any; at minimum ensure types match
    Evidence: .sisyphus/evidence/task-11-liveactivity.log
  ```

  **Commit**: Grouped with Task 10, 15

---

- [ ] 12. Class Table semester picker — liquid glass `.pickerStyle(.menu)` + Defaults + warm cache

  **What to do**:
  - Edit `swift/TigerDuck/Features/ClassTable/ClassTableView.swift:138-146`:
    - Replace the existing `HStack { Spacer(); Text("\(totalCredits) 學分") }` with:
      ```swift
      HStack {
          Picker("學期", selection: $viewModel.currentSemester) {
              ForEach(viewModel.availableSemesters, id: \.self) { code in
                  Text(viewModel.displayLabel(for: code)).tag(code)
              }
          }
          .pickerStyle(.menu)
          .labelsHidden()

          Spacer()

          Text("\(viewModel.totalCredits) 學分")
              .font(TigerDuckTheme.Typography.body)
              .foregroundStyle(Color.textSecondary)
      }
      .padding(.horizontal)
      ```
    - Remove the `// TODO: Implement semester picker` comment above this block
  - `ClassTableViewModel`:
    - Add `func displayLabel(for code: String) -> String` that returns `"\(code.dropLast())-\(code.last!)"` (e.g. `1142` → `114-2`)
    - Change `currentSemester` to init from `Defaults[.classTableSelectedSemester]`; add `didSet` that writes back to Defaults and calls `reloadFromCache() + triggerBackgroundRefresh(semester: newValue)`
    - Add `triggerBackgroundRefresh(semester: String)` that calls `AppServiceBridge.fetchCourses(semester:)` in a Task, compares result to current `courses` and silently updates if different
    - Add first-appear warm: `func warmCachesIfNeeded(authService:)` that iterates `availableSemesters` and calls `AppServiceBridge.fetchCourses(semester:)` for each; guarded by a `Defaults[.classTableWarmedOnce]` flag so it only runs once per session first appear
    - On pull-to-refresh: call `triggerForceRefresh(authService:)` that runs `AppServiceBridge.fetchCourses(semester: currentSemester)` AND `AppServiceBridge.fetchCourses(semester: currentSemesterCode())` in parallel (user's "reload current + latest")
  - `AppConstants.UserDefaultsKeys`: add `classTableSelectedSemester`, `classTableWarmedOnce`
  - `AppDefaults.swift` (`extension Defaults.Keys`): add `Key<String>(.classTableSelectedSemester, default: CourseSelectionService.currentSemesterCode())` and `Key<Bool>(.classTableWarmedOnce, default: false)`
  - `ClassTableView.onAppear`: call `viewModel.reloadFromCache()` (existing) followed by `viewModel.warmCachesIfNeeded(authService:)`

  **Must NOT do**:
  - Do not hand-style the picker (no custom background, no chevron, no font override)
  - Do not block UI on warm — all refreshes are background
  - Do not read the wrong cache bucket on switch (always `loadCourses(semester: currentSemester)`)

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
    - Reason: SwiftUI layout change + native picker integration

  **Parallelization**:
  - **Blocks**: 16
  - **Blocked By**: 4, 10

  **References**:
  - `swift/TigerDuck/Features/ClassTable/ClassTableView.swift:138-146` — exact insertion point
  - `swift/TigerDuck/Features/ClassTable/ClassTableViewModel.swift:14-29` — currentSemester + availableSemesters already present
  - `swift/TigerDuck/App/AppConstants.swift:22-44` — UserDefaultsKeys convention
  - `swift/TigerDuck/App/AppDefaults.swift` — Defaults.Keys extension pattern
  - iOS Liquid Glass note: `.pickerStyle(.menu)` on iOS 26 SDK renders with native Liquid Glass automatically; no manual work needed

  **WHY Each Reference Matters**:
  - The credits row is literally line-addressed; surgical replacement avoids collateral
  - Defaults pattern must match existing style for code review consistency

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Semester switch reads cache instantly
    Tool: Bash (xcodebuild test)
    Steps:
      1. Seed caches_1142.json with [A,B] and caches_1141.json with [C]
      2. ClassTableViewModel.currentSemester = "1141" (simulate user select)
      3. Assert viewModel.courses map(\.courseNo) == ["C"] immediately (no async wait)
      4. Assert Defaults[.classTableSelectedSemester] == "1141"
    Evidence: .sisyphus/evidence/task-12-switch.log

  Scenario: Background refresh silently overwrites on difference
    Tool: Bash (xcodebuild test)
    Steps:
      1. Cache has [A]
      2. Stub fetchCourses returns [A, B]
      3. triggerBackgroundRefresh
      4. After await: viewModel.courses == [A, B]; Defaults confirms no UI flash flag
    Evidence: .sisyphus/evidence/task-12-silent-update.log

  Scenario: Force reload pulls both current and latest
    Tool: Bash (xcodebuild test)
    Steps:
      1. currentSemester = "1141" (not latest)
      2. Latest = "1142"
      3. Spy fetchCourses invocations
      4. triggerForceRefresh()
      5. Assert fetchCourses was called with both "1141" and "1142"
    Evidence: .sisyphus/evidence/task-12-forcereload.log

  Scenario: displayLabel formatting
    Tool: Bash (xcodebuild test)
    Steps:
      1. #expect(viewModel.displayLabel(for: "1142") == "114-2")
      2. #expect(viewModel.displayLabel(for: "1141") == "114-1")
    Evidence: .sisyphus/evidence/task-12-format.log
  ```

  **Commit**: YES
  - Message: `feat(UI): liquid-glass semester picker on Class Table with cache-first switch`

---

- [ ] 13. Home "作業" rename + 全部/未完成 toggle + latest-semester filter + two-stage fetch

  **What to do**:
  - `Models/Domain/HomeSection.swift:22`: `case upcomingAssignments: "待辦作業"` → `case upcomingAssignments: "作業"`
  - `Features/Home/HomeViewModel.swift:144`: hardcoded `title: "待辦作業"` → `title: "作業"`
  - Add `enum AssignmentFilter: String, CaseIterable { case incomplete = "未完成"; case all = "全部" }` in `HomeViewModel.swift`
  - Add `@ObservationIgnored var allAssignmentsCache: [SDAssignment] = []` and `var assignmentFilter: AssignmentFilter` init'd from `Defaults[.homeAssignmentFilter]`
  - Computed `upcomingAssignments: [SDAssignment]`:
    - Latest-semester filter: let `currentCourseNos = Set(DataCache.shared.loadCourses(semester: CourseSelectionService.currentSemesterCode()).map(\.courseNo))`
    - Base: `allAssignmentsCache.filter { currentCourseNos.isEmpty || currentCourseNos.contains($0.courseNo) }`
    - If `.incomplete`: `base.upcomingSorted()` (existing extension)
    - If `.all`: `base.allSorted()` (new extension — see below)
  - Add to `Extensions/Array+Assignments.swift`:
    ```swift
    func allSorted() -> [SDAssignment] {
        let incomplete = filter { !$0.isCompleted }.sorted { $0.dueDate < $1.dueDate }
        let completed  = filter { $0.isCompleted }.sorted { $0.dueDate > $1.dueDate }
        return incomplete + completed
    }
    ```
  - `reloadFromCache()` + `fetchData()`: populate `allAssignmentsCache` with ALL fetched assignments (not filtered)
  - Two-stage fetch order (`fetchData`):
    1. Stage 1: `reloadFromCache()` (instant)
    2. Stage 2: `await AppServiceBridge.fetchAssignments(authService:)` — integrated path already calls `mod_assign_get_assignments` then `mod_assign_get_submission_status` per assignment; result contains authoritative `isCompleted`
    3. After Stage 2: recompute `allAssignmentsCache` from merged list; UI auto-re-derives `upcomingAssignments`
    - "Check incomplete first then completed" is satisfied because Stage 1 shows cache (incomplete bias), Stage 2 reconciles both directions via server truth
  - UI: `HomeSectionView.upcomingAssignmentsContent` — add `Picker` with `.pickerStyle(.segmented)` bound to `$viewModel.assignmentFilter` above `UpcomingAssignmentsView`; pass `showCompleted` hint so completed rows render dimmed (opacity 0.6 + strikethrough on title)
  - `AppConstants.UserDefaultsKeys`: add `homeAssignmentFilter`
  - `AppDefaults.swift`: `Key<String>(.homeAssignmentFilter, default: AssignmentFilter.incomplete.rawValue)` (stored as raw string for compatibility)

  **Must NOT do**:
  - Do not put the section-title migration in `HomeViewModel` (it belongs in `Services/Migrations/`; see Task 14)
  - Do not hard-filter completed out before storing to `allAssignmentsCache`
  - Do not leak past-semester assignments into Home (semester filter mandatory)
  - Do not call assignment APIs twice (one round-trip covers both incomplete + completed state via `mod_assign_get_submission_status`)

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`

  **Parallelization**:
  - **Blocks**: 16
  - **Blocked By**: 11, 14

  **References**:
  - `swift/TigerDuck/Features/Home/HomeView.swift:309,316` — "待辦作業" strings in empty-state messages (these are display strings, update too)
  - `swift/TigerDuck/Features/Home/HomeViewModel.swift:51,114,144` — upcomingSorted call sites
  - `swift/TigerDuck/Extensions/Array+Assignments.swift` — existing sort extension
  - `swift/TigerDuck/Features/ClassTable/Components/AddCourseSheet.swift:26-32` — `.pickerStyle(.segmented)` reference implementation

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Section title is "作業" for fresh install
    Tool: Bash (xcodebuild test)
    Steps:
      1. Clear Defaults[.homeSectionLayout]
      2. HomeViewModel.defaultSections().first(where: { $0.kind == .upcomingAssignments }).title == "作業"
    Evidence: .sisyphus/evidence/task-13-fresh-title.log

  Scenario: Toggle to 全部 shows completed items below incomplete
    Tool: Bash (xcodebuild test)
    Steps:
      1. allAssignmentsCache = [A(!isCompleted, due 2027), B(isCompleted, due 2026)]
      2. assignmentFilter = .all
      3. upcomingAssignments == [A, B]
      4. assignmentFilter = .incomplete → upcomingAssignments == [A]
    Evidence: .sisyphus/evidence/task-13-toggle.log

  Scenario: Latest-semester filter excludes past-semester assignments
    Tool: Bash (xcodebuild test)
    Steps:
      1. Seed courses_1142.json with [courseNo: "EC"], courses_1141.json with [courseNo: "OLD"]
      2. allAssignmentsCache = [A(courseNo: "EC"), B(courseNo: "OLD")]
      3. upcomingAssignments excludes B
    Evidence: .sisyphus/evidence/task-13-semester-filter.log

  Scenario: filter persistence across VM re-init
    Tool: Bash (xcodebuild test)
    Steps:
      1. Set Defaults[.homeAssignmentFilter] = "全部"
      2. New HomeViewModel instance; assignmentFilter.rawValue == "全部"
    Evidence: .sisyphus/evidence/task-13-persist.log
  ```

  **Commit**: Grouped with Task 14
  - Message: `feat(UI): rename 待辦作業 to 作業 with 全部/未完成 toggle and latest-semester filter`

---

- [ ] 14. `HomeSectionTitleMigration` in `Services/Migrations/`

  **What to do**:
  - Create `swift/TigerDuck/Services/Migrations/HomeSectionTitleMigration.swift`:
    ```swift
    enum HomeSectionTitleMigration {
        private static let defaultsKey = "HomeSectionTitleMigration.v1.done"

        static func runIfNeeded() {
            guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }
            // Read existing Defaults[.homeSectionLayout]; for any entry with
            // kind == .upcomingAssignments AND title == "待辦作業", update title to "作業".
            // Write back. Set flag.
            ...
            UserDefaults.standard.set(true, forKey: defaultsKey)
        }
    }
    ```
  - Invoke from `TigerDuckApp.init` (or `AppState` bootstrap) alongside `MoodleTokenMigration.runPendingMigrations()`
  - Idempotent: running twice is a no-op

  **Must NOT do**:
  - Do not put rename logic inside `HomeViewModel`
  - Do not forget the idempotency flag
  - Do not read Defaults on every app launch after flag is set (early-return)

  **Recommended Agent Profile**:
  - **Category**: `quick`

  **Parallelization**:
  - **Blocks**: 13 (hierarchically; migration must exist so the rename stays stable)
  - **Blocked By**: 3

  **References**:
  - `swift/TigerDuck/Services/Migrations/MoodleTokenMigration.swift` — pattern to copy
  - `swift/TigerDuck/App/TigerDuckApp.swift` — where to invoke
  - `swift/TigerDuck/App/AppDefaults.swift` — `Defaults[.homeSectionLayout]` access

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Upgrader with existing "待辦作業" title sees "作業" after migration
    Tool: Bash (xcodebuild test)
    Steps:
      1. Seed Defaults[.homeSectionLayout] with entry {kind: .upcomingAssignments, title: "待辦作業"}
      2. HomeSectionTitleMigration.runIfNeeded()
      3. Read Defaults[.homeSectionLayout]; entry.title == "作業"
      4. UserDefaults.bool(forKey: "HomeSectionTitleMigration.v1.done") == true
    Evidence: .sisyphus/evidence/task-14-migrate.log

  Scenario: Migration is idempotent
    Tool: Bash (xcodebuild test)
    Steps:
      1. Run migration once; then manually revert title to something else
      2. Run migration again; title not modified (flag present)
    Evidence: .sisyphus/evidence/task-14-idempotent.log
  ```

  **Commit**: Grouped with Task 13

---

- [ ] 15. `CanonicalCourseProvider` scoped to current semester

  **What to do**:
  - `swift/TigerDuck/LiveActivity/Providers/CanonicalCourseProvider.swift`:
    - `currentCourses()` loads via `DataCache.shared.loadCourses(semester: CourseSelectionService.currentSemesterCode())`
    - Merge with `loadUserAddedCourses()` as before (user-added carry no semester — treat as current)
    - Apply `deletedCourseNos` + `customNames` as before

  **Must NOT do**:
  - Do not load past-semester courses into Live Activity or reminders

  **Recommended Agent Profile**:
  - **Category**: `quick`

  **Parallelization**:
  - **Blocked By**: 4, 11

  **References**:
  - `swift/TigerDuck/LiveActivity/Providers/CanonicalCourseProvider.swift` — currentCourses implementation

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: currentCourses only contains current-semester entries
    Tool: Bash (xcodebuild test)
    Steps:
      1. Seed courses_1142.json with [A]; courses_1141.json with [PAST]
      2. currentCourses() → [A]; does NOT contain PAST
    Evidence: .sisyphus/evidence/task-15-scope.log
  ```

  **Commit**: Grouped with Tasks 10, 11

---

- [ ] 16. Regression tests — `MoodleHomeworkRegressionTests` additions

  **What to do**:
  - Extend `swift/TigerDuckTests/MoodleHomeworkRegressionTests.swift` with tests covering:
    - `semester_cache_isolation` (Task 4)
    - `legacy_cache_absorb` (Task 4)
    - `moodle_only_course_in_roster` (Task 10)
    - `submitted_assignment_hidden_from_incomplete` (Task 11)
    - `all_sorted_has_incomplete_before_completed` (Task 13)
    - `latest_semester_filter_excludes_past` (Task 13)
    - `home_section_title_migration_upgrader` (Task 14)
    - `calendar_api_completely_removed` (Task 11) — asserts via grep on `#file` or a known constant
  - Where real network would be required, mock via a protocol boundary injected at the service layer (introduce a small `MoodleAssignmentFetching` protocol if not already present; narrow scope — only needed to make tests deterministic)

  **Must NOT do**:
  - Do not hit the real network in tests
  - Do not require credentials to run tests

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`

  **Parallelization**:
  - **Blocked By**: 11, 12, 13, 15

  **References**:
  - `swift/TigerDuckTests/MoodleHomeworkRegressionTests.swift` — existing suite to extend
  - `swift/TigerDuckTests/TimeSliderViewModelTests.swift` — Swift Testing style reference

  **Acceptance Criteria**:

  **QA Scenarios**:

  ```
  Scenario: Full test suite passes
    Tool: Bash
    Steps:
      1. xcodebuild test -project "swift/TigerDuck.xcodeproj" -scheme "TigerDuck" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | tee /tmp/full.log
      2. grep -q "** TEST SUCCEEDED **" /tmp/full.log
      3. grep -E "Test case .*MoodleHomeworkRegressionTests.*passed" /tmp/full.log | wc -l → >= 8 (all new tests + existing)
    Evidence: .sisyphus/evidence/task-16-test.log
  ```

  **Commit**: YES
  - Message: `test(Moodle): regression tests for homework + course roster migration`

---

## Final Verification Wave

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read this plan end-to-end. For each "Must Have": verify implementation (read file, run test command). For each "Must NOT Have": search codebase for forbidden patterns. Specifically: `rg "core_calendar_get_action_events_by_timesort" swift/` must return 0 lines; `rg "KMPServiceBridge" swift/` must return 0 lines. Verify every evidence file exists under `.sisyphus/evidence/`. Confirm every commit in `git log --oneline <base>..HEAD` has a valid GPG signature via `git log --show-signature`.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | GPG [N/N] | VERDICT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `xcodebuild test` (full), capture log. Scan every changed `.swift` for: `as any`, `@ts-ignore` equivalents (`try!`, `as!`), empty catches, `print()` statements, commented-out code, unused imports. Verify new files follow existing naming + module organization. Confirm AI slop patterns absent.
  Output: `Build [PASS/FAIL] | Tests [N pass/N fail] | Files [N clean/N issues] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high` (+ `playwright` skill if UI preview needed)
  Execute every QA scenario from every task. Integration: switch semester in Class Table, verify cached data appears instantly and refreshes silently; toggle 作業 全部/未完成 on Home, verify correct list; simulate a submitted assignment by manipulating cache, confirm it disappears from 未完成 view after refresh.
  Output: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", diff `git log`/`git diff`. Verify 1:1 — no missing, no extras. Check "Must NOT do" compliance. Detect cross-task contamination (Task N touching Task M's files inappropriately). Flag unaccounted changes.
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

All commits **GPG-signed** (`git commit -S`), leveraging the verified existing config. One commit per logical phase:

1. `feat(Backend): add Moodle assignment/course POC probes` — Tasks 1, 2
2. `refactor(Services): reorganize network layer into Services/API domain folders` — Task 3
3. `feat(DataCache): make course cache semester-aware` — Tasks 4, 7 (cache + CourseService split)
4. `feat(Moodle): add site-info, enrolled-courses, assignment services; consolidate DTOs` — Tasks 5, 6, 8, 9
5. `feat(Bridge): implement course OR-union and mod_assign_* homework fetch; drop calendar API` — Tasks 10, 11, 15
6. `feat(UI): liquid-glass semester picker on Class Table with cache-first switch` — Task 12
7. `feat(UI): rename 待辦作業 to 作業 with 全部/未完成 toggle and latest-semester filter` — Tasks 13, 14
8. `test(Moodle): regression tests for homework + course roster migration` — Task 16

Every commit message follows the repo convention:
```
type(Scope): short description

- bullet point 1
- bullet point 2
```

No `Co-Authored-By:` lines.

---

## Success Criteria

### Verification Commands

```bash
# 1. Full test suite
xcodebuild test -project "swift/TigerDuck.xcodeproj" -scheme "TigerDuck" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  | tail -20   # Expected: ** TEST SUCCEEDED **

# 2. Calendar API fully removed from Swift
rg "core_calendar_get_action_events_by_timesort" swift/   # Expected: no matches

# 3. Legacy python kept but not production
rg "core_calendar_get_action_events_by_timesort" backend/api | wc -l
  # Expected: matches only in backend/api/moodle/legacy/homework_sso.py

# 4. All commits signed
git log --show-signature <base>..HEAD | grep -c "Good signature"
  # Expected: equals number of commits in the phase

# 5. New folder structure exists
test -d swift/TigerDuck/Services/API/NTUST
test -d swift/TigerDuck/Services/API/Moodle
test -d swift/TigerDuck/Services/API/Library
test -d swift/TigerDuck/Services/API/Calendar
test -d swift/TigerDuck/Services/Core

# 6. Migration file placed correctly
test -f swift/TigerDuck/Services/Migrations/HomeSectionTitleMigration.swift
```

### Final Checklist

- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] All tests pass
- [ ] All commits GPG-signed
- [ ] Evidence files saved for every QA scenario
- [ ] `core_calendar_get_action_events_by_timesort` deleted from Swift
- [ ] Section title "作業" visible for both fresh installs and upgraded installs (migration verified)
- [ ] Semester switch in Class Table is instantaneous + silent background refresh
- [ ] Native iOS `.pickerStyle(.menu)` used; no custom styling
