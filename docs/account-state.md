# Account state

What the app keeps of a signed-in school account, and what clears it when the account signs out
or another one signs in. `AppState.logoutNTUST()` is the one sign-out path; why it runs in this
order is in `docs/decisions/0026-one-sign-out-path.md`.

`tools/check_account_state.py` reads the table at the end, and CI runs it through
`tools/test_check_account_state.py`. Every Keychain key in `AppConstants.KeychainKeys` and
`AuthTokenManager`, every `Defaults` key in `swift/TigerDuck/App/AppDefaults.swift` and every file
`DataCache` writes needs a row. A row of the school account (`account`) or the library account
(`library`) names the function that clears it, and that function must mention it; a Keychain key
of either is also deleted by the fresh-install wipe in `AppState.init`. `device` rows outlive any
account: preferences, the device's own identity and public school data.

## Stores the check cannot read

| Store | Cleared by |
|---|---|
| School session cookies, the Moodle and SSO cookies | `AuthService.endSchoolSession(departing:)` and `MoodleTokenService.signOut()` |
| Shared URL cache and the in-app browser's website data | `AuthService.forgetSchoolPages`, in the sign-out calls a sign-in waits for |
| The TigerDuck browser's website data, in a store of its own on disk | `BrowserData.reset()` in `AppState.forgetAccountOnDevice` and at each sign-in in `AuthService.login`; what it could not remove the next browser clears before it loads (`browserDataState`) |
| Delivered notifications of the account | `AuthService.logout()` and again at the end of the sign-out calls; School Mail's thread stays |
| Answers shared between callers (Moodle enrolment, classroom usage, enrolled course numbers) | `AuthService.endSchoolSession(departing:)` |
| Imported class tables of the account | `ImportedClassTableStore.removeAll()` in `AppState.forgetAccountOnDevice` |
| Moodle file downloads in flight | `MoodleFileDownloads.cancelAll()` in `AppState.forgetAccountOnDevice` |
| `AppState`'s conflicts, pending overrides and polling | `AppState.logoutNTUST()` |
| Uploads, outbox and pending document pushes | `PushCoordinator.forgetUploads()`, `CloudSyncCoordinator.settleForSignOut()` |
| Feature view models (scores, class table, empty classroom, calendar, Moodle course pages) | they reload on `AuthService.loginGeneration` and `AppConstants.dataDidUpdate` |
| Widgets and the Watch | they rebuild from the cleared caches on `AppConstants.dataDidUpdate` |
| Live Activities | `LiveActivityCoordinator.endAll()` in the sign-out calls |
| The backend's device registration | the unregister in the sign-out calls, sent with the kept session until it lands |
| SwiftData | holds nothing: the models are value types the caches persist |

School Mail and the library are accounts of their own, which a school sign-out keeps; School
Mail's keys live in `MailPreferences` and `MailCredentialStore`, and its sign-out clears them.

## Stored state

| Store | Name | Scope | Cleared in |
|---|---|---|---|
| keychain | `accessTokenKey` | account | `swift/TigerDuck/Services/Auth/AuthTokenManager.swift` `clearTokens` |
| keychain | `departingSessionKey` | account | `swift/TigerDuck/Services/Auth/AuthTokenManager.swift` `storeDepartingSessions` |
| keychain | `expiresAtKey` | account | `swift/TigerDuck/Services/Auth/AuthTokenManager.swift` `clearTokens` |
| keychain | `libraryPassword` | library | `swift/TigerDuck/Services/API/Library/LibraryService.swift` `clearCredentials` |
| keychain | `libraryToken` | library | `swift/TigerDuck/Services/API/Library/LibraryService.swift` `clearToken` |
| keychain | `libraryTokenExpiry` | library | `swift/TigerDuck/Services/API/Library/LibraryService.swift` `clearToken` |
| keychain | `libraryUsername` | library | `swift/TigerDuck/Services/API/Library/LibraryService.swift` `clearCredentials` |
| keychain | `moodlePrivateToken` | account | `swift/TigerDuck/Services/API/Moodle/MoodleTokenService.swift` `drop` |
| keychain | `moodleToken` | account | `swift/TigerDuck/Services/API/Moodle/MoodleTokenService.swift` `drop` |
| keychain | `password` | account | `swift/TigerDuck/Services/Auth/AuthService.swift` `logout` |
| keychain | `pushDeviceId` | device |  |
| keychain | `refreshTokenKey` | account | `swift/TigerDuck/Services/Auth/AuthTokenManager.swift` `clearTokens` |
| keychain | `refreshTokenUsesKey` | account | `swift/TigerDuck/Services/Auth/AuthTokenManager.swift` `clearTokens` |
| keychain | `studentId` | account | `swift/TigerDuck/Services/Auth/AuthService.swift` `logout` |
| defaults | `academicCalendarCache` | device |  |
| defaults | `academicCalendarETag` | device |  |
| defaults | `accentColorHex` | device |  |
| defaults | `alwaysShowAllPeriods` | device |  |
| defaults | `appAppearance` | device |  |
| defaults | `appHasBeenInstalled` | device |  |
| defaults | `appLanguage` | device |  |
| defaults | `assignmentLiveActivityLeadTime` | device |  |
| defaults | `assignmentMarksSyncedOnce` | account | `swift/TigerDuck/App/AppState+Account.swift` `forgetSyncProgress` |
| defaults | `assignmentReminderOffsetsData` | device |  |
| defaults | `browserAddressBar` | device |  |
| defaults | `browserAppearance` | device |  |
| defaults | `browserDataState` | device |  |
| defaults | `browserDesktopSites` | account | `swift/TigerDuck/Features/Browser/BrowserData.swift` `reset` |
| defaults | `browserPreference` | device |  |
| defaults | `browserZoom` | account | `swift/TigerDuck/Features/Browser/BrowserData.swift` `reset` |
| defaults | `bulletinPushEnabled` | device |  |
| defaults | `bulletinReadIds` | device |  |
| defaults | `bulletinsSyncedAt` | account | `swift/TigerDuck/Features/Bulletins/BulletinsViewModel.swift` `forgetListSession` |
| defaults | `categoriesSyncedOnce` | account | `swift/TigerDuck/App/AppState+Account.swift` `forgetSyncProgress` |
| defaults | `classPreparingLeadTime` | device |  |
| defaults | `classReminderLeadMinutes` | device |  |
| defaults | `classTableSelectedSemester` | account | `swift/TigerDuck/App/AppState+Account.swift` `forgetAccountOnDevice` |
| defaults | `classroomMandarinDisplay` | device |  |
| defaults | `cloudSyncEnabled` | account | `swift/TigerDuck/App/AppState+Account.swift` `logoutNTUST` |
| defaults | `configuredTabsData` | device |  |
| defaults | `courseRowIdsSeen` | account | `swift/TigerDuck/App/AppState+Account.swift` `forgetSyncProgress` |
| defaults | `emptyClassroomBuilding` | account | `swift/TigerDuck/App/AppState+Account.swift` `forgetAccountOnDevice` |
| defaults | `flipToLibraryEnabled` | device |  |
| defaults | `hasCompletedOnboarding` | device |  |
| defaults | `hasPickedClassReminderLead` | device |  |
| defaults | `holidayNotifyOverrides` | account | `swift/TigerDuck/Services/API/Calendar/AcademicCalendarStore.swift` `forgetHolidayOverrides` |
| defaults | `holidayOverridesAwaitingUpload` | account | `swift/TigerDuck/Services/API/Calendar/AcademicCalendarStore.swift` `forgetHolidayOverrides` |
| defaults | `homeAssignmentFilter` | device |  |
| defaults | `homeSectionLayoutData` | device |  |
| defaults | `invertSliderDirection` | device |  |
| defaults | `isAssignmentReminderEnabled` | device |  |
| defaults | `isClassReminderEnabled` | device |  |
| defaults | `isLiveActivityEnabled` | device |  |
| defaults | `lastPromptedUpdateAt` | device |  |
| defaults | `lastPromptedUpdateVersion` | device |  |
| defaults | `lastReportedUnparseableStoreVersion` | device |  |
| defaults | `lastSeenCoursesResetAt` | account | `swift/TigerDuck/App/AppState+Account.swift` `forgetSyncProgress` |
| defaults | `lastShownWhatsNewVersion` | device |  |
| defaults | `lastUpdateCheckAt` | device |  |
| defaults | `libraryStoredPasswordRefusals` | library | `swift/TigerDuck/Services/API/Library/LibraryService.swift` `storedPasswordRefusals` |
| defaults | `libraryStoredPasswordRefusedAt` | library | `swift/TigerDuck/Services/API/Library/LibraryService.swift` `storedPasswordRefusals` |
| defaults | `macConfiguredTabsData` | device |  |
| defaults | `macMoodleOpenTarget` | device |  |
| defaults | `notificationSettingsPushPending` | account | `swift/TigerDuck/App/AppState+NotificationSettings.swift` `cancelNotificationSettingsPushes` |
| defaults | `ntustCredentialsPresent` | account | `swift/TigerDuck/Services/Auth/AuthService.swift` `markCredentialsChanged` |
| defaults | `ntustStoredPasswordRefusals` | account | `swift/TigerDuck/Services/API/NTUST/SSOLoginService.swift` `storedPasswordRefusals` |
| defaults | `ntustStoredPasswordRefusedAt` | account | `swift/TigerDuck/Services/API/NTUST/SSOLoginService.swift` `storedPasswordRefusals` |
| defaults | `outlineRequiredCourses` | device |  |
| defaults | `pendingConflictCategories` | account | `swift/TigerDuck/App/AppState+Account.swift` `forgetSyncProgress` |
| defaults | `pinTodayCoursesOnClassTable` | device |  |
| defaults | `pushServerEnabled` | device |  |
| defaults | `pushServerURLOverride` | device |  |
| defaults | `schoolDataSyncedAt` | account | `swift/TigerDuck/App/AppState+Account.swift` `forgetAccountOnDevice` |
| defaults | `serverPushUserOptOut` | device |  |
| defaults | `showAbsoluteAssignmentTime` | device |  |
| defaults | `showAssignmentScenario` | device |  |
| defaults | `showClassPreparingScenario` | device |  |
| defaults | `showClassroomInClassTable` | device |  |
| defaults | `showInClassScenario` | device |  |
| defaults | `shownServerPopupIds` | device |  |
| defaults | `skippedUpdateVersion` | device |  |
| defaults | `ssoLoginTimestamp` | account | `swift/TigerDuck/Services/API/NTUST/NTUSTSessionManager.swift` `invalidateSession` |
| defaults | `syncAssignmentReminders` | device |  |
| defaults | `syncAssignments` | device |  |
| defaults | `syncCourseColors` | device |  |
| defaults | `syncCourseNames` | device |  |
| defaults | `syncCourses` | device |  |
| defaults | `syncLiveActivity` | device |  |
| defaults | `syncPreferencesPushPending` | device |  |
| defaults | `useEnglishClassroomAbbreviation` | device |  |
| defaults | `useEnglishCourseAbbreviation` | device |  |
| defaults | `visualPreset` | device |  |
| cache | `archived_assignments.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `assignments.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `bulletin_details/` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `bulletin_summaries.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `calendar_events.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `closed_unsubmitted_assignments.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `course_color_map.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `course_custom_colors.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `course_custom_names.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `course_search_options.json` | device |  |
| cache | `courses_*` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `deleted_courses.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `ignored_courses.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `locally_completed_assignments.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `moodleDir` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `moodleFilesDir` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `moodle_course_id_map.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `picked_course_colors.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `score_report_*` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `selection_dropped.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
| cache | `user_added_courses.json` | account | `swift/TigerDuck/Services/Core/DataCache.swift` `clearUserScopedData` |
