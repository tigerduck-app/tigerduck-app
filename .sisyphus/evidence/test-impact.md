# Test Impact Analysis

**Generated:** 2026-04-21  
**Task:** T1d – Existing test scan (affected files)

---

## Xcode Schemes

```
Schemes:
    TigerDuck
    TigerDuckLiveActivityExtension
```

Test targets: `TigerDuckTests`, `TigerDuckUITests` (both under scheme `TigerDuck`)

---

## Test Files Found

```
swift/TigerDuckTests/TimeSliderViewModelTests.swift
swift/TigerDuckTests/TigerDuckTests.swift
swift/TigerDuckUITests/TigerDuckUITestsLaunchTests.swift
swift/TigerDuckUITests/TigerDuckUITests.swift
```

Total: 4 test files

---

## Symbol Search Results

Command run:
```bash
rg -n 'AuthService|MoodleService|NTUSTSessionManager|isNTUSTLoggedIn|isNTUSTAuthenticated' \
  swift/TigerDuckTests/ swift/TigerDuckUITests/
```

**Output: (empty — no matches)**

No test file references any of the affected symbols:
- `AuthService`
- `MoodleService`
- `NTUSTSessionManager`
- `isNTUSTLoggedIn`
- `isNTUSTAuthenticated`

---

## TimeSliderViewModelTests.swift

**Status: SAFE** — no references to affected symbols.

File content summary:
- Tests `CourseTimeSlot.dateFromTimeString(_:on:)` parsing
- Tests `TimeSliderViewModel.xOffset(for:)` pixel calculations
- Tests `TimeSliderViewModel.courseState(at:)` state machine
- Uses only: `TimeSliderViewModel`, `TimeSliderMetrics`, `CourseTimeSlot`, `SDCourse`
- No auth, session, or Moodle symbols present

---

## Conclusion

**NO_TESTS_AFFECTED**

All 4 test files are clean. None reference `AuthService`, `MoodleService`, `NTUSTSessionManager`, `isNTUSTLoggedIn`, or `isNTUSTAuthenticated`. The auth-persistence-fix changes can proceed without requiring any test file modifications.
