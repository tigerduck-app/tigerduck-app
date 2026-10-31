# Account state

What the app keeps of a signed-in school account, and what clears it when the account signs out
or another one signs in. `AppState.logoutNTUST()` is the one sign-out path; why it runs in this
order is in `docs/decisions/0026-one-sign-out-path.md`.

`tools/check_account_state.py` reads the table at the end, and the Architecture workflow runs it
on every pull request. Every Keychain key in `AppConstants.KeychainKeys` and `AuthTokenManager`,
every `Defaults` key declared in a `Defaults.Keys` extension of the app target and every file a
source under `swift/TigerDuck/Persistence/` names needs a row. A row of the school account
(`school`) or the library account (`library`) names the function that clears it, and that function
must mention it; a Keychain key of either is also deleted by the fresh-install wipe in
`AppState.init`. `device` rows outlive any account: preferences, the device's own identity and
public school data.

## Stores the check cannot read

| Store | Cleared by |
|---|---|
| School session cookies, the Moodle and SSO cookies | `AuthService.endSchoolSession(departing:)` and `MoodleTokenService.signOut()` |
| Shared URL cache and the in-app browser's website data | `AuthService.forgetSchoolPages`, in the sign-out calls a sign-in waits for |
| The TigerDuck browser's website data, in a store of its own on disk, and the files it saved | `BrowserData.reset()` in `AppState.forgetAccountOnDevice` and at each sign-in in `AuthService.login`; what it could not remove the next browser clears before it loads (`browserDataState`) |
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
| School Mail's cached pages, bodies and search index | `MailCache.clearAll()`, from School Mail's sign-out (`MailAccountManager.logout()`) |

School Mail and the library are accounts of their own, which a school sign-out keeps; School
Mail's keys live in `MailPreferences` and `MailCredentialStore`, and its sign-out clears them.

## Stored state

| Store | Name | Scope | Cleared in |
|---|---|---|---|
| keychain | `accessTokenKey` | school | `swift/TigerDuck/Backend/Auth/AuthTokenManager.swift` `clearTokens` |
| keychain | `departingSessionKey` | school | `swift/TigerDuck/Backend/Auth/AuthTokenManager.swift` `storeDepartingSessions` |
| keychain | `expiresAtKey` | school | `swift/TigerDuck/Backend/Auth/AuthTokenManager.swift` `clearTokens` |
| keychain | `libraryPassword` | library | `swift/TigerDuck/School/Library/LibraryService.swift` `clearCredentials` |
| keychain | `libraryToken` | library | `swift/TigerDuck/School/Library/LibraryService.swift` `clearToken` |
| keychain | `libraryTokenExpiry` | library | `swift/TigerDuck/School/Library/LibraryService.swift` `clearToken` |
| keychain | `libraryUsername` | library | `swift/TigerDuck/School/Library/LibraryService.swift` `clearCredentials` |
| keychain | `moodlePrivateToken` | school | `swift/TigerDuck/School/Moodle/MoodleTokenService.swift` `drop` |
| keychain | `moodleToken` | school | `swift/TigerDuck/School/Moodle/MoodleTokenService.swift` `drop` |
| keychain | `password` | school | `swift/TigerDuck/Account/AuthService.swift` `logout` |
| keychain | `pushDeviceId` | device |  |
| keychain | `refreshTokenKey` | school | `swift/TigerDuck/Backend/Auth/AuthTokenManager.swift` `clearTokens` |
| keychain | `refreshTokenUsesKey` | school | `swift/TigerDuck/Backend/Auth/AuthTokenManager.swift` `clearTokens` |
| keychain | `studentId` | school | `swift/TigerDuck/Account/AuthService.swift` `logout` |
| defaults | `academicCalendarCache` | device |  |
| defaults | `academicCalendarETag` | device |  |
| defaults | `accentColorHex` | device |  |
| defaults | `alwaysShowAllPeriods` | device |  |
| defaults | `appAppearance` | device |  |
| defaults | `appHasBeenInstalled` | device |  |
| defaults | `appLanguage` | device |  |
| defaults | `assignmentLiveActivityLeadTime` | device |  |
| defaults | `assignmentMarksSyncedOnce` | school | `swift/TigerDuck/App/AppState+Account.swift` `forgetSyncProgress` |
| defaults | `assignmentReminderOffsetsData` | device |  |
| defaults | `browserAddressBar` | device |  |
| defaults | `browserAppearance` | device |  |
| defaults | `browserDataState` | device |  |
| defaults | `browserDesktopSites` | school | `swift/TigerDuck/Features/Browser/BrowserData.swift` `reset` |
| defaults | `browserZoom` | school | `swift/TigerDuck/Features/Browser/BrowserData.swift` `reset` |
| defaults | `bulletinPushEnabled` | device |  |
| defaults | `bulletinReadIds` | device |  |
| defaults | `bulletinsSyncedAt` | school | `swift/TigerDuck/Features/Bulletins/BulletinsViewModel.swift` `forgetListSession` |
| defaults | `categoriesSyncedOnce` | school | `swift/TigerDuck/App/AppState+Account.swift` `forgetSyncProgress` |
| defaults | `classPreparingLeadTime` | device |  |
| defaults | `classReminderLeadMinutes` | device |  |
| defaults | `classTableSelectedSemester` | school | `swift/TigerDuck/App/AppState+Account.swift` `forgetAccountOnDevice` |
| defaults | `classroomMandarinDisplay` | device |  |
| defaults | `cloudSyncEnabled` | school | `swift/TigerDuck/App/AppState+Account.swift` `logoutNTUST` |
| defaults | `configuredTabsData` | device |  |
| defaults | `courseChangesCache` | device |  |
| defaults | `courseChangesETag` | device |  |
| defaults | `courseRowIdsSeen` | school | `swift/TigerDuck/App/AppState+Account.swift` `forgetSyncProgress` |
| defaults | `emptyClassroomBuilding` | school | `swift/TigerDuck/App/AppState+Account.swift` `forgetAccountOnDevice` |
| defaults | `flipToLibraryEnabled` | device |  |
| defaults | `hasCompletedOnboarding` | device |  |
| defaults | `hasPickedClassReminderLead` | device |  |
| defaults | `holidayNotifyOverrides` | school | `swift/TigerDuck/School/Calendar/AcademicCalendarStore.swift` `forgetHolidayOverrides` |
| defaults | `holidayOverridesAwaitingUpload` | school | `swift/TigerDuck/School/Calendar/AcademicCalendarStore.swift` `forgetHolidayOverrides` |
| defaults | `homeAssignmentFilter` | device |  |
| defaults | `homeSectionLayoutData` | device |  |
| defaults | `invertSliderDirection` | device |  |
| defaults | `isAssignmentReminderEnabled` | device |  |
| defaults | `isClassReminderEnabled` | device |  |
| defaults | `isLiveActivityEnabled` | device |  |
| defaults | `lastPromptedUpdateAt` | device |  |
| defaults | `lastPromptedUpdateVersion` | device |  |
| defaults | `lastReportedUnparseableStoreVersion` | device |  |
| defaults | `lastSeenCoursesResetAt` | school | `swift/TigerDuck/App/AppState+Account.swift` `forgetSyncProgress` |
| defaults | `lastShownWhatsNewVersion` | device |  |
| defaults | `lastUpdateCheckAt` | device |  |
| defaults | `libraryStoredPasswordRefusals` | library | `swift/TigerDuck/School/Library/LibraryService.swift` `storedPasswordRefusals` |
| defaults | `libraryStoredPasswordRefusedAt` | library | `swift/TigerDuck/School/Library/LibraryService.swift` `storedPasswordRefusals` |
| defaults | `macConfiguredTabsData` | device |  |
| defaults | `macMoodleOpenTarget` | device |  |
| defaults | `notificationSettingsPushPending` | school | `swift/TigerDuck/App/AppState+NotificationSettings.swift` `cancelNotificationSettingsPushes` |
| defaults | `ntustCredentialsPresent` | school | `swift/TigerDuck/Account/AuthService.swift` `markCredentialsChanged` |
| defaults | `ntustStoredPasswordRefusals` | school | `swift/TigerDuck/School/NTUST/SSOLoginService.swift` `storedPasswordRefusals` |
| defaults | `ntustStoredPasswordRefusedAt` | school | `swift/TigerDuck/School/NTUST/SSOLoginService.swift` `storedPasswordRefusals` |
| defaults | `outlineRequiredCourses` | device |  |
| defaults | `pendingConflictCategories` | school | `swift/TigerDuck/App/AppState+Account.swift` `forgetSyncProgress` |
| defaults | `pinTodayCoursesOnClassTable` | device |  |
| defaults | `pushServerEnabled` | device |  |
| defaults | `pushServerURLOverride` | device |  |
| defaults | `schoolDataSyncedAt` | school | `swift/TigerDuck/App/AppState+Account.swift` `forgetAccountOnDevice` |
| defaults | `serverPushUserOptOut` | device |  |
| defaults | `showAbsoluteAssignmentTime` | device |  |
| defaults | `showAssignmentScenario` | device |  |
| defaults | `showClassPreparingScenario` | device |  |
| defaults | `showClassroomInClassTable` | device |  |
| defaults | `showInClassScenario` | device |  |
| defaults | `shownServerPopupIds` | device |  |
| defaults | `skippedUpdateVersion` | device |  |
| defaults | `ssoLoginTimestamp` | school | `swift/TigerDuck/School/NTUST/NTUSTSessionManager.swift` `invalidateSession` |
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
| cache | `archived_assignments.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `assignments.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `bulletin_details/` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `bulletin_summaries.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `calendar_events.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `closed_unsubmitted_assignments.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `course_color_map.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `course_custom_colors.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `course_custom_names.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `courses_*` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `deleted_courses.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `ignored_courses.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `locally_completed_assignments.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `moodleDir` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `moodleFilesDir` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `moodle_course_id_map.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `picked_course_colors.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `score_report_*` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `selection_dropped.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `server_dropped.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
| cache | `user_added_courses.json` | school | `swift/TigerDuck/Persistence/DataCache.swift` `clearUserScopedData` |
