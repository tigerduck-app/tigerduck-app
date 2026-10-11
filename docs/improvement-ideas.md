# Apple 端改進建議

> 整理日期：2026-10-12。依據：本 repo `dev` @ `1fc9a39b`（PR #237 merge 後）、`tigerduck-backend` origin/dev @ `7f3cb94`、`tigerduck-app-android` origin/dev @ `23b01a49`。最新發布版本為 v2.3.0（PR #225）。

## 閱讀說明

- 每一條包含：類型與標題（Conventional Commits）、現況與證據、建議做法，以及效益、成本、風險、需要的配合與信心。
- 優先：以 issue 的 Priority 欄位為準，bug 照 `docs/issue-triage.md` 的定義（Urgent＝當機、資料遺失或隱私外洩；High＝主要功能壞掉；Medium＝有替代方式；Low＝小問題），功能與維護工作依重要程度。
- 成本：S＝一天內；M＝數天；L＝一週以上。對應 issue 的 Effort 欄位：S＝Low（小），S–M 與 M＝Medium（中），M–L 與 L＝High（大）。
- Issue：每一條標題後面列出對應的 issue。`#N` 是本 repo，`backend#N` 是 tigerduck-backend，`android#N` 是 tigerduck-app-android。
- 信心：高＝讀過程式並追完路徑；中＝很可能成立，但沒有完整追完；低＝值得查證的線索。
- 路徑：`swift/…`、`docs/…`、`tools/…` 在本 repo；`backend:` 指 tigerduck-backend 的 origin/dev；`android:…/` 指 tigerduck-app-android origin/dev 的 `app/src/main/java/org/ntust/app/tigerduck/`。
- 範圍與限制：只讀程式碼，沒有建置、沒有在裝置上量測，也沒有用學校帳號登入；效能相關的數字都是從程式碼推估。
- 已經有 issue 的項目集中在「九、既有 issue」，其他章節不重複列。
- 另有一項資安問題已在對話中另外回報，這份文件不寫細節，處理完再補進來。

## 重點

- 兩個會讓資料不見的 bug：伺服器同步 Moodle 之後，使用者的作業標記會在所有裝置上消失（2.1）；課程查詢失敗時，每台裝置的上課時間都會被清空（2.2）。
- 有期限：TLS pin 在 2027-01-18 到期，要在 12 月中前發布新版（3.1）。
- 隱私：換帳號後，成績頁可能還顯示上一位使用者的成績（4.2）；登出後，widget 也會暫時留著上一位的課表（5.3）。
- 發布版本的 Sentry 沒有 DSN，錯誤和 crash 一直沒有送出去；要先補齊遮蔽再打開（7.1）。
- #237 的後續：最划算的是先停掉每次 outbox tick 抓了又丟的 `/sync/full`（1.2），再做 polling backoff（1.1）；delta sync 需要的 change feed 後端已經有了（1.4）。
- 便宜又明顯的修正：點公告推播不會打開該則公告（4.1）；Widget 教室顯示錯誤的根因已經找到（#211）；School Mail 回到 App 後，列表看不到新信（6.1）。

## 一、#237 留下的後續

PR #237 刻意沒做三件事：revision 變動時的 delta sync、revision polling 的 backoff、沒變的課程與作業不重傳；另外還有一個沒實測的假設。建議順序是 1.2 → 1.1 → 7.1 → 1.5 → 1.3 → 1.4。

### 1.1 perf(Sync): back off revision polling and poll once on return（#238、android#154、backend#32）

- **現況**：前景每 10 秒固定打一次 `/sync/revision`，離線、5xx、429、401 都照打，也不擋重疊的請求（`swift/TigerDuck/App/AppState+RevisionPolling.swift:16-66`）；只有 scene 進背景、登出或關閉同步才停（`swift/TigerDuck/TigerDuckApp.swift:166,173`）。後端每次 poll 都 commit 一次 `last_seen_at`（`backend:server/routes/sync/snapshot.py:36-49`），前景一小時就是 360 次。後端的 `poll_tracker` 只記在行程記憶體裡，推播流程沒有讀它，所以拉長間隔不會影響推播。
- **建議**：回到前景時立刻 poll 一次；有變動或本機剛編輯後的一分鐘內維持 10 秒，之後倍增到 60 秒（Mac 120 秒）；出錯時指數退避到 300 秒並加 jitter；`NetworkMonitor` 判斷離線時暫停；401 時重新登入一次，再失敗就停到下次回前景；上一個請求還沒回來就跳過。
- **評估**：效益高（後端負載、耗電）；成本 S；風險低。iPhone 上，作業標記、課程覆寫與伺服器的 Moodle 同步會送 silent push（`sync_trigger`）補上，但通知設定文件、假日例外與停課日不會；Mac 也收不到 silent push（`backend:server/push/pipeline.py:475`），所以上限不宜拉太長。配合：Android 也是固定 10 秒的迴圈（`android:…/ui/screen/home/HomeViewModel.kt:534-560`），可以一起改。信心高。

### 1.2 perf(CloudSync): stop fetching and discarding /sync/full on every outbox tick（#239、backend#24）

- **現況**：`CloudSyncCoordinator.syncTick` 每次都先呼叫 `pullFullSync()`，抓一份完整的 `/sync/full` 再丟掉（`swift/TigerDuck/Services/CloudSync/CloudSyncCoordinator.swift:185-191,287-289`）。tick 每 5 分鐘一次、每次 `didBecomeActive` 一次（關掉控制中心也算），本機每次編輯後 1 秒也一次；scene 進背景也不會停，所以 Mac 開著就整天跑（:320-331、:357-361）。後端每次 `/sync/full` 都會寫一筆 sync log、取消這台裝置排隊中的 sync trigger，並把伺服器自己的 Moodle 同步延後 2 小時（`backend:server/routes/sync/snapshot.py:103-118`、`backend:server/routes/sync/_shared.py:97`）。Mac 一直開著時，伺服器端的 Moodle 同步可能一直輪不到，2.1 也就更容易發生。
- **建議**：刪掉 `pullFullSync()` 和它的兩個呼叫點。outbox drain 遇到 `URLError` 和 401 本來就會保留項目（`swift/TigerDuck/Services/CloudSync/SyncOutbox.swift:160-176`），重試行為不變。後端只在上傳路由延後同步工作，並改成 `greatest(run_after, now + 2h)`。
- **評估**：效益高；成本 S；風險低；配合：後端（延後邏輯，可以晚點做）；信心：App 端高，「伺服器同步一直被延後」中。

### 1.3 perf(Sync): skip course and assignment uploads whose content did not change（#240）

- **現況**：每次抓完課程都上傳整份課程清單（`swift/TigerDuck/Bridge/AppServiceBridge.swift:256-289`）；每輪作業同步（回到 App 超過 60 秒就跑一輪）都上傳整份作業清單（`swift/TigerDuck/Bridge/AppServiceBridge+Assignments.swift:256-282`）。後端每次都逐列 upsert，更新 `updated_at`、`last_seen_at` 與課程的 `version`，再寫 log、延後伺服器同步（`backend:server/routes/sync/uploads.py:163-178`）。內容沒變的上傳不會增加 revision，不會造成同步迴圈，只是浪費。
- **建議**：對排序後的請求算 hash（課程以帳號加學期為單位，作業以帳號為單位），收到 2xx 才記下，最長 6 小時後仍重傳一次。以下情況不能跳過：
  - `forceKeys` 非空。
  - 這台裝置重設學期後的第一次上傳：它會解除重設時留下的 tombstone（`backend:server/routes/sync/uploads.py:107-122`），而重抓的課表 hash 通常和重設前相同。
  - reconcile 為伺服器已清空的學期補傳（`swift/TigerDuck/App/AppState+CourseReconcile.swift:86-91`）。
  - 剛登入，或剛重新打開同步開關。
- **評估**：效益中（大多數回到 App 的情況省兩次上傳）；成本 S；風險中：例外條件漏一條，伺服器資料就會過時，要補測試。會少掉的只有 `last_seen_at`（沒人讀）、log 與同步延後，作業提醒是掃描式的，不受影響。配合：不需要。信心中高。

### 1.4 feat(Sync): read the change feed before deciding on a full sync（#241、backend#26）

- **現況**：revision 一變就抓整份 `/sync/full`，在 main actor 上解析、重寫快取、發 `dataDidUpdate`，接著再另外 GET 一次通知設定文件（`swift/TigerDuck/App/AppState+BackendSync.swift:15-215`）。後端其實已經有增量 API：`GET /sync?since_revision=` 回傳每筆變動的 `revision`、`entity_type`、`entity_id`、`operation`、`payload` 與 `has_more`；資料被壓縮掉（30 天）之後回 410 `sync_revision_expired`（`backend:server/routes/sync/snapshot.py:52-89`）。
- **建議**：revision 變動時先讀 feed。只有 `assignment` 與 `bulletin_*` 類的變動就略過（伺服器每次軟刪除暫存列或更新繳交狀態都會寫一筆）；只有 `settings_document` 就只跑通知設定的 reconcile；其他情況照舊 full sync；最後把 watermark 推到 `returned_until_revision`。
- **陷阱**：`PushAPIClient` 會把所有非 2xx 回報給 `APIVersionGate`（`swift/TigerDuck/Services/Push/PushAPIClient.swift:350-357`），而 gate 收到任何 410 就永久鎖成「需要更新」（`swift/TigerDuck/Services/API/APIVersionGate.swift:26-29`）。feed 的 410 一定要在那之前處理掉。
- **後端可以加的**：每筆 feed 帶 `by_this_device`（changelog 已經存了 `device_id`）。現在每台裝置在自己編輯後約 10 秒，都會因為自己的回音再做一次 full sync。
- **評估**：效益中高（多數 revision 變動不必 full sync）；成本 App M、後端 S；風險中：分類錯了會漏同步，要有測試；配合：後端（`by_this_device`，可選），Android 可以共用同一套規則；信心：API 盤點高，效益估計中。

### 1.5 chore(Logging): record where a lapsed service session lands（#242）

- **現況**：#237 假設服務 session 過期時頁面會導到學校入口 `i.ntust.edu.tw`，所以課表和成績抓取遇到「最後的主機不是自己」就清掉該服務的 cookie 再登入一次（`swift/TigerDuck/Services/API/NTUST/CourseSelectionService.swift:56-79`、`swift/TigerDuck/Services/API/NTUST/NTUSTScoreService.swift:114-135`）。這兩個分支什麼都沒記錄，`AppLogger` 也只有 `captureError`（`swift/TigerDuck/Services/Logging/AppLogger.swift:48`），恢復成功的 bounce 完全看不到。
- **建議**：加一個約 5 行的 `AppLogger.captureMessage`，bounce 時送一筆 info 事件，tag 帶 `service`、`landedHost`（分桶：ssoam2／ssoam／i.ntust.edu.tw／other）、`ssoBody`、`outcome`（recovered／bouncedAgain），只送主機，不送路徑與 query；`redirectedToSSO` 也帶上主機。一週的資料就能證實或推翻這個假設，不需要用測試帳號登入。前置：Sentry 目前沒有啟用，要先做 7.1。
- **評估**：效益中（確認 #237 的修法夠不夠）；成本 S；風險無（不含個資）；配合：Android 要不要做同樣的 bounce 處理，可以等資料出來再決定；信心高。

## 二、資料正確性與同步

### 2.1 fix(sync): keep assignment overrides when the server replaces an upload placeholder（backend#23）

- **現況**：App 上傳作業時不知道 Moodle 課程 id，後端存成 `moodle_course_id=0` 的暫存列；伺服器還沒自己抓到這份作業前，使用者的忽略或完成標記會掛在暫存列上（`backend:server/routes/overrides.py:267-290`）。之後伺服器的 Moodle 同步建立正式列，並把不在結果裡的列（包含暫存列）軟刪除（`backend:server/syncjobs/assignments.py:101-153`），標記沒有跟著搬過去。`/sync/full` 只用未刪除的列對應 Moodle id（`backend:server/routes/sync/snapshot.py:174,229`），這筆標記送到 App 時 `moodle_assignment_id` 是 null；App 找不到對應就跳過（`swift/TigerDuck/App/AppState+BackendSync.swift:56-67`），接著用伺服器狀態覆寫本機（:128-141），標記就在所有裝置上消失。後端提醒也是依 `user_assignment_id` 對應標記（`backend:server/push/reminders.py:216`），所以被忽略的作業會照常提醒。
- **情境**：老師剛出的作業，學生馬上按了忽略；幾小時後伺服器同步一跑，忽略就不見了，還收到提醒。
- **建議**：後端建立正式列時，若同一份作業有暫存列，就把暫存列上的標記改指到新列，或直接把暫存列升級成正式列；`_pk_to_moodle` 改用包含已刪除列的對照，讓已經斷掉的標記自己恢復。補一個後端測試。
- **評估**：效益高；成本 S；風險低；配合：只需要後端，Android 的解析方式相同，修好後兩邊都受益；信心中高（路徑追完，沒有實際執行）。

### 2.2 fix(ClassTable): keep cached class times when a course lookup fails（#243）

- **現況**：更新課表時，每門課各查一次課程查詢系統；查詢丟錯時改用 `fallbackCourseData`，裡面沒有上課時間和教室（`swift/TigerDuck/Bridge/AppServiceBridge.swift:207-219,545-570`）。整份清單接著寫入快取並上傳（:250-289），後端 upsert 會直接覆寫 `schedule_json` 與 `classroom_map`（`backend:server/routes/sync/uploads.py:163-173`）。Moodle 和成績都沒有這門課時，fallback 回傳 nil，這門課會直接從清單消失。
- **情境**：加退選期間 querycourse 最忙，也最多人下拉更新。一次逾時或錯誤頁，課表、widget、Live Activity 就少了那幾門課的時段，其他裝置和後端的上課提醒也一起少掉，要等下一次成功更新才回來。
- **建議**：查詢前先把這學期快取的課依課號建索引，查詢失敗時沿用快取裡那一列；只有「查詢成功但沒有結果」才用 fallback。
- **評估**：效益高；成本 S；風險低；配合：不需要；信心高。

### 2.3 fix(CloudSync): keep edits through server errors instead of dropping them after five（#244）

- **現況**：outbox 最多試 5 次；只有 `URLError`、取消與 401 會保留且不扣次數，5xx、429、404 和解碼失敗都扣一次，滿 5 次就丟掉，只留一行 `os` log（`swift/TigerDuck/Services/CloudSync/SyncOutbox.swift:94,160-185`）。丟掉之後，下一次成功的 pull 會用伺服器狀態蓋掉本機標記（`swift/TigerDuck/App/AppState+BackendSync.swift:128-141`）。後端故障期間每回到前景就 drain 一次，回來五次，這段時間做的標記就沒了。
- **建議**：5xx、408、429 比照 `URLError` 保留；真的要丟時，像假日例外的 `unacknowledgedHolidayIDs` 一樣保護本機狀態，並用 `AppLogger.captureError` 回報。
- **評估**：效益高；成本 S；風險低；配合：不需要；信心高。

### 2.4 fix(CloudSync): accept the server's reply to clearing an assignment mark（#245）

- **現況**：取消作業標記（`local_status: "none"`）時，後端回 `{"deleted": true}`（`backend:server/routes/overrides.py:95-127`），App 卻用必填 `id`、`local_status`、`updated_at` 的 `AssignmentOverrideResponse` 解碼（`swift/TigerDuck/Services/Push/PushAPIDTO.swift:259-269`、`swift/TigerDuck/Services/Push/PushAPIClient.swift:160-170`），每次都失敗，outbox 於是重送 5 次。刪除在第一次就成功了，但每次重送都會讓後端多寫一筆 changelog 與 log，並排一次 sync trigger，讓其他裝置多做 full sync。
- **建議**：呼叫端都沒有用到回應（`swift/TigerDuck/Services/CloudSync/CloudSyncCoordinator.swift:300,307` 是 `_ =`），改成不解碼回應內容。
- **評估**：效益中高；成本 S；風險低；配合：不需要（Android 只看 HTTP 狀態）；信心高。

### 2.5 fix(Sync): drop a full sync that a sign-out overtook（#246）

- **現況**：`syncOverridesFromBackend` 只在進入時檢查同步開關與登入狀態；`fetchFullSync` 回來後就直接寫入作業標記、課程顏色與名稱、假日例外、手動與隱藏的課程（`swift/TigerDuck/App/AppState+BackendSync.swift:15-215`），中間沒有再比對 `loginGeneration`。登出只取消 `syncTask`，取消不到由 poll、push 或下拉觸發的這條路徑。下拉後立刻登出，晚到的回應就會把上一位使用者的資料寫進剛清空的快取，違反 `swift/TigerDuck/AGENTS.md` 的規則。
- **建議**：進入時記下 generation，每個 await 之後確認沒有變、同步仍然開著。
- **評估**：效益中（機率低，但屬於隱私邊界）；成本 S；風險低；配合：不需要；信心高。

### 2.6 fix(Sync): build the course upload in one place, with generated colours（#247）

- **現況**：抓完課程後的上傳是 bridge 自己組的（`swift/TigerDuck/Bridge/AppServiceBridge.swift:256-289`），會把 `TigerDuckTheme.courseColorMap` 一起當成 `course_overrides` 送出，而這份 map 也包含自動分配的顏色。`AppState.courseUploadRequest` 刻意拿掉了這段，註解寫著自動分配的顏色會變成整個帳號的設定（`swift/TigerDuck/App/AppState+BackendSync.swift:411-434`）；bridge 這份副本卻還在送，而且是在 detached task 裡用 `try?` 送，失敗既不記錄也不會重新登入。
- **已決定**：自動分配的顏色也要上傳，讓整個帳號共用同一組配色：第一台上傳的裝置決定每門課的顏色（後端只補空白的 `color_hex`），其他裝置跟著用伺服器的顏色。
- **建議**：`AppState.courseUploadRequest` 成為唯一的組裝函式，並改成帶上 `courseColorMap` 的 `course_overrides`（包含自動分配的顏色），同時改寫那段註解；bridge 改用它，刪掉約 30 行重複的程式，上傳改走 `pushCoordinator`。使用者手動挑的顏色照舊用會覆寫的 PATCH。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心高。

### 2.7 fix(Schedule): update pending Live Activity start jobs on re-sync（backend#25）

- **現況**：`/schedule/sync` 只取消不在新清單裡的待送工作；key 還在的直接跳過，新增時又用 `on_conflict_do_nothing()`（`backend:server/routes/schedule_v3.py:68-82,117`），而 key 只由裝置、`source_id` 與情境組成（:81）。48 小時內已經排好的 Live Activity 啟動不會跟著更新：改了課前提醒的提前時間、老師延後截止時間、課程改名或換教室，伺服器送出的都還是舊的時間和內容。
- **建議**：key 相同但 `fire_at` 或 payload 不同時，更新那筆待送工作。
- **評估**：效益中高；成本 S；風險低；配合：只需要後端（Android 不用 `/schedule/sync`）；信心高。

### 2.8 fix(Sync): run the first-sync mark upload once per account（#248、android#155）

- **現況**：只要伺服器上沒有任何作業標記、本機有，就把本機標記全部上傳（`swift/TigerDuck/App/AppState+BackendSync.swift:76-85`）。裝置 A 清掉最後一個標記後，裝置 B 下一次同步看到伺服器是空的，就把自己過時的標記傳回去。
- **建議**：每個帳號只做一次，記一個 flag。
- **評估**：效益中；成本 S；風險低；配合：Android 有一樣的判斷（`android:…/notification/BackgroundSyncWorker.kt:162-171`），一起改；信心高。

### 2.9 fix(Sync): honour the Assignments sync switch（#249、backend#30）

- **現況**：「同步作業」開關只在偏好設定的 PATCH 和重新開啟時的檢查用到（`swift/TigerDuck/Services/Push/PushRegistrationService.swift:427`）。作業清單上傳只看 `cloudSyncEnabled`（`swift/TigerDuck/Bridge/AppServiceBridge+Assignments.swift:256-282`），標記的上傳與拉取也不看這個開關。所有裝置都關掉時後端會清掉作業資料（`backend:server/routes/user_devices.py:550-566`），這台裝置下一輪又傳回去。
- **已決定**：這個開關只管「標記為完成」與「標記為忽略」。
- **建議**：標記的推送與拉取依開關決定；作業清單照常上傳，因為後端的作業提醒用的是它。後端在所有裝置都關掉時，連作業清單一起刪除，改成只刪標記（backend#30）。
- **評估**：效益中；成本 S；風險低；配合：後端（只刪標記，App 端可以先做）；信心高。

### 2.10 perf(Sync): reuse what the full sync fetched and write only what changed（#250）

- **現況**：每次 full sync 之後，`reconcileNotificationSettings()` 會再 GET 一次 `/sync/full` 已經帶回的設定文件（`swift/TigerDuck/App/AppState+BackendSync.swift:212`）。不論有沒有變，都重寫標記檔並發 `dataDidUpdate`（:140-141、:205），連帶觸發各頁重讀、手錶 payload、widget snapshot、Live Activity 與 `/schedule/sync`，全都在 main actor 上。另外每個 `PushAPIClient` 都建立自己的 ephemeral `URLSession`（`swift/TigerDuck/Services/Push/PushAPIClient.swift:364-373`），bridge 每次上傳都 new 一個，連線沒辦法重用。
- **建議**：直接用 snapshot 帶回的設定文件；寫入前先比較，有變才發通知；上傳共用 `pushCoordinator` 的 client。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心高。

### 2.11 fix(Sync): queue a follow-up when a sync trigger arrives mid-pull（#251）

- **現況**：silent push 的 `sync_trigger` 會呼叫 `syncOverridesFromBackend`，但另一個 pull 正在進行時，重入保護會直接略過它（`swift/TigerDuck/App/AppState+BackendSync.swift:19-27`）。前景時 polling 會補上；在背景時，widget 和 Live Activity 要等下次開 App 才更新。Android 的做法是進行中收到 trigger 就排一次後續同步（android PR #135）。
- **建議**：進行中收到 trigger 時記一個 flag，結束後再跑一次。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心中。

### 2.12 fix(Sync): sync the course a colour pick displaces（#252）

- **現況**：挑顏色時，`setColor` 會把原本用這個顏色的課換成別的顏色（`swift/TigerDuck/Theme/TigerDuckTheme.swift:197-215`），但只 PATCH 被挑的那門課（`swift/TigerDuck/Features/ClassTable/ClassTableViewModel+Editing.swift:261-270`），伺服器上就有兩門課同色。之後套用伺服器顏色時，依伺服器回傳的順序逐筆 `setColor`，每次同步都可能把這兩門課的顏色換來換去。
- **建議**：依 `color_hex_updated_at` 排序後一次套用所有伺服器顏色；挑色之後，連被換掉顏色的課一起 PATCH。
- **評估**：效益低中；成本 S–M；風險低；配合：不需要；信心中。

## 三、登入與學校資料

### 3.1 chore(Security): rotate the TLS pins before 2027-01-18（#253、android#157）

- **現況**：`*.ntust.edu.tw` 與 `api.lib.ntust.edu.tw` 兩組 pin 共用同一個到期日 2027-01-18（`swift/Shared/TLSPinningDelegate.swift:39-66`），距今 98 天；Android 也是同一組 pin、同一個日期。到期後會退回系統信任，不會斷線，但失去防護。比較大的風險在到期前：學校若換成不同中繼憑證簽發的萬用憑證，所有 NTUST 請求都會被拒，一直到到期日為止。
- **建議**：現在就用 `tls-pin-rotation` skill 在兩個 repo 一起輪換，12 月中前發布 iPhone 與手錶版本。每組 pin 各自設到期日（之後若要加上 Android PR #131 的 `cardsystem.ntust.edu.tw` 也需要）。加一個測試，任一組在 45 天內到期就失敗。
- **評估**：效益高（有期限）；成本 S，加一次發布；風險低；配合：Android 同步輪換；信心高。

### 3.2 fix(Auth): stop silent SSO retries once the school rejects the password（#254、android#163）

- **現況**：SSO 登入被拒時只丟 `.loginFailed`，不讀頁面上的原因，畫面一律顯示請使用者確認帳號密碼（`swift/TigerDuck/Services/API/NTUST/SSOLoginService.swift:185-200`）。用已存密碼的背景登入分散在 `AuthService`、課表、成績與 Moodle token 更新，沒有一條會在密碼被拒後停手。使用者在學校改了密碼後，舊密碼會在每次啟動、下拉課表、看成績和更新 Moodle token 時一再送出；帳號被鎖或出現驗證碼時，使用者看到的也還是「請確認帳號密碼」。School Mail 已經有同類保護：密碼被拒後，背景檢查就不再登入（`swift/TigerDuck/Services/Mail/Sync/MailChecker.swift:155`）。
- **建議**：加一個持久化的「密碼被拒」旗標：背景登入被拒時設定、每次背景 POST 前檢查、使用者手動登入成功才清除。把 `MoodleTokenService.extractLoginError` 移到 `HTMLParser`，讓錯誤訊息帶出學校頁面上的說明（使用者看得到的文案，要先審）。
- **評估**：效益高；成本 S；風險低；配合：Android 值得檢查同樣的情況；信心中高（SSO 的鎖定門檻沒有驗證）。

### 3.3 fix(Auth): require a live SSO session before calling a sign-in successful（#255）

- **現況**：`ensureServiceLogin` 打開服務頁後，只要不是 ssoam2 的登入表單就當作已登入（`swift/TigerDuck/Services/API/NTUST/SSOLoginService.swift:124-128`），不看 HTTP 狀態，也不確認 session；判斷登入頁時只認 `ssoam2.ntust.edu.tw`（`swift/TigerDuck/Services/Core/HTMLParser.swift:16-33`）。第一頁若是維護頁、503、學校入口，或 Android PR #131 提到的另一台 SSO 主機 `ssoam.ntust.edu.tw`（NetIQ 表單，帶 invisible reCAPTCHA），互動式登入會在沒有送出密碼的情況下「成功」，打錯的密碼也照樣存進 Keychain（`swift/TigerDuck/Services/Auth/AuthService.swift:163-165`），之後再接上 3.2 的重試。
- **建議**：回傳成功前呼叫一次 `NTUSTSessionManager.shared.probeCookiesValid()`。讓 `HTMLParser` 認得 ssoam 的頁面，遇到時丟新的 `.interactiveLoginRequired`，不要當成成功。送出帳密的主機白名單維持只有 ssoam2。
- **評估**：效益中高；成本 S；風險低；配合：Android PR #131 已處理兩台主機的判斷；信心：程式路徑高，實際觸發的頻率要看學校伺服器。

### 3.4 fix(Calendar): parse the school calendar in the Gregorian calendar and keep it on failure（#256）

- **現況**：`currentROCYear` 用 `Calendar.current` 取年份再減 1911（`swift/TigerDuck/Services/API/Calendar/CalendarService.swift:66-74`）。手機設成民國曆時，取到的年份已經是 115，減完是 -1796，找不到 ICS，學校行事曆整個空白。ICS 的 `DateFormatter` 沒有指定 locale 和曆法（:171-187），在民國曆下 `20250901` 會被解成西元 3936 年。以上兩點用 Swift script 實際驗證過。另外，抓取失敗時回傳 `[]`（:77-91），兩個呼叫端都直接拿它取代快取裡的學校行程（`swift/TigerDuck/App/AppState+RevisionPolling.swift:112-118`、`swift/TigerDuck/Features/Calendar/CalendarViewModel.swift:124-132`）。同一個 repo 的 `CourseSelectionService.swift:181-186` 已經處理過一樣的民國曆問題。
- **建議**：年份改用 Gregorian 曆與 `AppClock.now()`；formatter 設 `en_US_POSIX` 與 Gregorian；失敗時回傳 nil 並保留快取；補一個民國曆 locale 的 `parseICS` 測試（這個檔案目前沒有測試）。
- **評估**：效益高；成本 S；風險低；配合：不需要；信心高。

### 3.5 perf(Moodle): bound and trim submission-status requests（#257）

- **現況**：每輪作業同步，會對每一份還沒確認繳交的作業各發一個 submission status 請求，沒有並行上限，也不排除早已截止的（`swift/TigerDuck/Bridge/AppServiceBridge+Assignments.swift:173-201`）；回到 App 超過 60 秒就會跑一輪。後端自己的同步只問 48 小時內到期的作業，而且同時最多 4 個（`backend:server/config.py:182-183`）。
- **建議**：沒交且已過 cutoff 的不問（下拉時仍全部重查）；並行上限設 4，寫成一個小 helper，讓課程查詢（`swift/TigerDuck/Bridge/AppServiceBridge.swift:181-228`）也共用。之後可以評估用 `tool_mobile_call_external_functions` 批次呼叫，先確認 site info 裡有這個函式。
- **評估**：效益中；成本 S（批次 M）；風險低；配合：不需要；信心中。

### 3.6 fix(Assignments): keep a past term's Moodle course out of this term（#258）

- **現況**：挑本學期的 Moodle 課程時，只要課號在本學期課表裡就收（`swift/TigerDuck/Bridge/AppServiceBridge+Assignments.swift:142-147`），不比對學期，而 Moodle 會保留過去的選課。重修同一門課時，舊學期的作業會出現在這學期，顯示為逾期，每輪都重問狀態，也會上傳到後端。
- **建議**：同一個課號有多個 Moodle 課程時，優先取 `semester == currentSemester` 的，否則取開始日期最新的。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心中（學校跨學期沿用課號是推論）。

### 3.7 fix(Security): fetch the semester catalogue through the pinned session（#259）

- **現況**：學期清單用 `URLSession.shared` 打 `querycourse.ntust.edu.tw`（`swift/TigerDuck/Services/API/NTUST/SemesterCatalog.swift:12-14,134-138`），沒有 TLS pinning；同一台主機的課程查詢卻有 pin（`swift/TigerDuck/Services/API/NTUST/CourseLookupService.swift:10-20`）。這是唯一沒有 pin 的 NTUST 請求，它的結果又決定課程歸在哪個學期，而且 `URLSession.shared` 會帶上共用 cookie jar 裡 `.ntust.edu.tw` 網域的 cookie。
- **建議**：改用和 `CourseLookupService` 一樣有 pin 的 ephemeral session。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心：沒有 pin 高，帶到哪些 cookie 中。

### 3.8 refactor(Moodle): add one webservice call helper before #212 and #162（#260）

- **現況**：組請求與 `.invalidToken` 重試各複製了三份（`MoodleAssignmentService.swift`、`MoodleEnrolledCoursesService.swift`、`MoodleSiteInfoService.swift`，都在 `swift/TigerDuck/Services/API/Moodle/`），Moodle 網址散在四個常數。`.invalidToken` 的處理是先 `clearToken()` 再更新（`MoodleAssignmentService.swift:12-15,63-68`），而 `clearToken()` 會刪掉 token 並清掉 ssoam2 與 moodle2 的 cookie（`MoodleTokenService.swift:157-173`）：更新失敗（例如 Moodle 維護中）時就完全沒有 token；harvest 進行中又碰到 `.invalidToken` 時，可能清掉 harvest 正在用的 cookie。`accessexception` 也被當成 token 失效（`MoodleWebserviceError.swift:60`），#212 一呼叫網站沒開放的函式就會觸發重新登入；維護狀態也沒有對應的錯誤。
- **建議**：做一個 `MoodleWebserviceClient.call(_:params:as:)`，負責 token 與更新（拿到新 token 後才替換，cookie 只在登出時清）、錯誤對應（區分「函式不允許」與「token 失效」，補上維護狀態）、在 main actor 之外解碼，以及單一的 `MoodleSite.current`。
- **評估**：效益中（#212、#162 的前置）；成本 S–M；風險中低（動到 token 流程要仔細測）；配合：不需要；信心：重複程式高，cookie 競態中。

### 3.9 perf(Parsing): check for the SSO form without parsing the whole page on the main actor（#261）

- **現況**：`HTMLParser` 在預設 MainActor 的 app target 裡（`swift/TigerDuck.xcodeproj/project.pbxproj:1249`），每次判斷是不是 SSO 頁面都用 SwiftSoup 解析整頁（`swift/TigerDuck/Services/Core/HTMLParser.swift:27-33`），所以課表頁和成績頁都會在 main actor 上完整解析一次；成績頁的主要解析當初已經特地移到背景。
- **建議**：先用 `html.contains("loginForm") || html.contains("Username")` 篩，命中才用 SwiftSoup；`HTMLParser` 標成 `nonisolated`。
- **評估**：效益低中；成本 S；風險低；配合：不需要；信心高。

## 四、iOS 功能頁

### 4.1 fix(Push): open the bulletin when a subscription bulletin notification is tapped（#262）

- **現況**：推播點擊只處理 `custom_push_bulletin`（`swift/TigerDuck/TigerDuckApp.swift:197`）。一般訂閱公告的推播 `kind` 是 `bulletin`，也帶 `bulletin_id`（`backend:server/bulletins/user_dispatch.py:178-185`、`backend:server/bulletins/dispatcher.py:341-351`），點了只會打開 App、停在上次的分頁。Android 會直接打開那則公告。
- **建議**：`case "custom_push_bulletin", "bulletin":`。
- **評估**：效益高；成本 S；風險低；配合：不需要；信心高。

### 4.2 fix(Score): drop the previous account's report on sign-out（#263）

- **現況**：`ScoreViewModel.load` 只有在 `report == .empty` 時才讀快取（`swift/TigerDuck/Features/Score/ScoreViewModel.swift:66-76`），也沒有監聽 `dataDidUpdate`；登出只刪掉磁碟上的檔案。成績釘在 tab 上時，A 登出、B 在同一台手機登入，B 會看到 A 的姓名、學號、GPA 與各科成績，直到離開這個分頁或下拉；B 的抓取失敗時就一直留著。
- **建議**：記下 report 屬於哪個學號，`load` 時不同就重設為 `.empty`，一併清掉 `collapsedTerms`。
- **評估**：效益高（隱私）；成本 S；風險低；配合：不需要；信心高。

### 4.3 fix(LiveActivity): skip ignored and locally completed assignments in "due soon"（#264、android#156）

- **現況**：「作業快到期」只排除 Moodle 上已繳交的作業（`swift/TigerDuck/LiveActivity/Resolvers/LiveActivityScenarioResolver.swift:163`），使用者標記忽略或自行標記完成的（`isArchived`、`isLocallyCompleted`）照樣會啟動 Live Activity。送給後端排 push-to-start 的清單（`swift/TigerDuck/Services/Push/ScheduleSyncService.swift:149`）和 `swift/TigerDuck/App/AppState+LiveActivity.swift:108` 也是同樣的條件。後端的作業提醒已經排除這兩種狀態（`backend:server/push/reminders.py:51`）。
- **已決定**：忽略與自行標記完成的作業都不觸發「作業快到期」，和後端的作業提醒一致。
- **建議**：三處都加上 `!isArchived && !isLocallyCompleted`。
- **評估**：效益高；成本 S；風險低；配合：Android 的 resolver 條件相同（`android:…/liveactivity/LiveActivityResolver.kt:59`），兩邊一起改。這也是 #210、#209 的前置。信心中高。

### 4.4 fix(App): open the class table from a widget when its tab is not pinned（#265）

- **現況**：從 widget 打開課表時，直接設 `selectedTab = .classTable`（`swift/TigerDuck/ContentView.swift:201-202`）。課表沒有釘在 tab 上時，就是同一個函式裡圖書館分支註解所說的情況：選了一個沒有對應 Tab 的值，會讓 TabView 壞掉（:188-190）。
- **建議**：比照圖書館分支，未釘選時經由「更多」頁開啟；也確認所有 tab 都被移除時會退回 `.more`。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心高。

### 4.5 fix(Moodle): open the web page when the Moodle app is not installed（#266）

- **現況**：iOS 上作業與課程的 Moodle 連結只開 `moodlemobile://`（`swift/TigerDuck/Features/Home/Components/UpcomingAssignmentsView.swift:262-266`、`swift/TigerDuck/Features/ClassTable/Components/CourseDetailSheet.swift:226-234`），沒裝 Moodle App 的學生點了沒有反應；網頁版的 `moodleWebURL` 其實已經有了。
- **建議**：`openURL(link) { accepted in if !accepted { openURL(web) } }`。
- **評估**：效益中高；成本 S；風險低；配合：不需要；信心高。

### 4.6 fix(ClassTable): pick up newly published terms without a relaunch（#267）

- **現況**：學期選單和「沒選過就跟著最新學期」只在 view model 第一次暖快取時算一次（`swift/TigerDuck/Features/ClassTable/ClassTableViewModel.swift:44-50,79-89`），學期清單本身則會定期更新。App 跨過開學一直沒被關掉時，課表會停在上學期，首頁卻已經是新學期。另外 `classTableSelectedSemester` 在登出時沒有清，下一個帳號會打開上一位選的學期。
- **建議**：在 `reloadFromCache()` 重算這兩項，登出時清掉這個 key。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心中（學期清單更新與登出這兩段沒有逐行追）。

### 4.7 fix(Calendar): remove the device-calendar read path, or give it a usage description（#268）

- **現況**：行事曆會呼叫 `requestFullAccessToEvents()`（`swift/TigerDuck/Features/Calendar/CalendarViewModel.swift:149`），但 Info.plist、專案設定和 `InfoPlist.strings` 都沒有 `NSCalendarsFullAccessUsageDescription`，git 歷史裡也從來沒有過；缺這個 key 時系統會直接拒絕。所以合併系統行事曆的這段從來沒有運作過。
- **建議**：先依 #167 的方向決定。不打算讀系統行事曆就刪掉這段；要讀就補上 key，並在切換月份時重新載入。
- **評估**：效益低中（清掉死碼，或讓功能真的能用）；成本 S；風險低；配合：不需要；信心高。

### 4.8 perf(UI): redraw on minute changes and tick the time slider once a minute（#269）

- **現況**：`MinuteTicker` 不管分鐘有沒有變，每 5 秒都更新一次 `tick`（`swift/TigerDuck/Clock/MinuteTicker.swift:17-27`）；課表頁讀了它，所以整頁 body 每分鐘重算 12 次。每次重算會讀好幾次 `hasStoredCredentials`，而每次讀都是兩次沒有快取的 Keychain 讀取（`swift/TigerDuck/Services/Auth/AuthService.swift:104-106`）。首頁時光機用 `TimelineView(.periodic(from: .now, by: 1))` 每秒重畫（`swift/TigerDuck/Features/Home/Components/TimeSlider/TimeSliderSection.swift:78`），但軌道每分鐘只移動約 0.9 pt，標籤也只顯示到分鐘。
- **建議**：`MinuteTicker` 只在分鐘改變時發佈（保留 5 秒的偵測延遲）；時光機改用 `.everyMinute`；`AuthService` 快取「憑證是否存在」，只在 `revalidateStoredCredentials()` 時重讀。
- **評估**：效益中（耗電與捲動順暢度，沒有量測）；成本 S；風險低；配合：不需要；信心中。

### 4.9 fix(a11y): fix the accessibility gaps found while reading（#270）

- **現況**：
  - 作業列的完成、忽略與復原只能用自訂的拖曳手勢（`swift/TigerDuck/Features/Home/Components/UpcomingAssignmentsView.swift:295-404`），沒有 `accessibilityActions`，VoiceOver、Voice Control 和鍵盤使用者都無法操作。
  - 課表格子的 VoiceOver 標籤把「週一」代進 `"週%1$@ 第%2$@節：%3$@"`，中文會唸成「週週一 第3節」（`swift/TigerDuck/Features/ClassTable/Components/TimetableGridView.swift:13-30`）；formatter 也只在第一次建立時抓 locale，切換 App 語言後不會變。
  - 同步狀態點只用紅綠色區分（`swift/TigerDuck/SharedUI/SyncStatusDot.swift`）；主題色與課程顏色的色票沒有標籤；作業 badge 對 VoiceOver 隱藏；月曆日期數字固定 32 pt，大字級時會被截斷；幾處動畫沒有遵守「減少動態效果」。
- **建議**：作業列加 `.accessibilityActions`；課表標籤改用現有的星期字串；其餘逐項補上標籤、圖示與 Reduce Motion 判斷。
- **評估**：效益中；成本各 S；風險低；配合：不需要；信心：前兩項高，其餘中。

### 4.10 fix(Home): show a course's assignments in its sheet under every filter（#271）

- **現況**：首頁篩選切到「已忽略」時，從時光機打開的課程 sheet 用的是 `upcomingAssignments.unfinished(for:)`，而這時清單裡只有已忽略的作業，sheet 就是空的（`swift/TigerDuck/Features/Home/HomeViewModel.swift:279-281`）。
- **建議**：改讀 `allAssignmentsCache`。
- **評估**：效益低；成本 S；風險低；配合：不需要；信心中。

### 4.11 perf(ClassTable): debounce the custom colour picker（#272）

- **現況**：自訂顏色拖曳時每一格都呼叫 `onSelect`（`swift/TigerDuck/Features/ClassTable/Components/CourseColorPickerSheet.swift:141-152`），每次都寫檔、發 `dataDidUpdate`（首頁、課表、行事曆都會重讀，Live Activity 也會更新），並排一次同步。
- **建議**：停止拖曳約 300 ms 後才套用。
- **評估**：效益低中；成本 S；風險低；配合：不需要；信心中。

## 五、Widget、Live Activity、Apple Watch、Mac

### 5.1 fix(App): wire push, Watch and widget setup at launch, not in ContentView.onAppear（#273）

- **現況**：綁定 silent push 的處理、啟動 `WCSession`、建立 widget snapshot writer，都寫在 `ContentView.onAppear`（`swift/TigerDuck/TigerDuckApp.swift:93-118`）。App 被系統在背景喚醒時沒有 scene，這些都不會執行：`sync_trigger` 到達時 `onSyncTrigger` 還是 nil，等於什麼都沒做，卻回報 `.newData`（`swift/TigerDuck/App/PushAppDelegate.swift:98-110`、`swift/TigerDuck/App/AppState+PushServer.swift:16-21`）；手錶發出的同步或圖書館 QR 請求喚醒 iPhone 時，也沒有 session 接收，只能等逾時後改由手錶自己抓。
- **建議**：在 `PushAppDelegate.didFinishLaunching` 綁定 sync trigger 並啟動 `WCSession`；手錶的同步請求由 coordinator 自己回應，不經過 view。
- **評估**：效益中高（App 沒開著時，silent push 與手錶也能運作）；成本 S–M；風險中低（啟動順序要配合 `hasCompletedOnboarding`）；配合：不需要；信心中（依程式推論，沒有在裝置上測）。

### 5.2 fix(Widgets): skip holidays when picking a later day's first class（#274）

- **現況**：Widget 推算「下一堂課」時，只對今天檢查假日（`swift/TigerDuckWidgets/Logic/WidgetTimelineDerivation.swift:52`）；往後找 1 到 7 天時只看停課日，不看假日（:104-131）。放假前一晚，下一堂課和鎖定畫面的 widget 會顯示「明天：微積分 08:10」。
- **建議**：迴圈裡遇到 `quietDayKeys` 的日子就跳過，並補一個假日測試。
- **評估**：效益中高；成本 S；風險低；配合：不需要；信心高。

### 5.3 fix(Widgets): refresh widgets right after sign-out and on accent changes（#275）

- **現況**：登出時快取很早就清掉了（`swift/TigerDuck/App/AppState+Account.swift:106`），但 `dataDidUpdate` 要等 `settleForSignOut()` 和 `pushCoordinator.disable()` 兩個網路呼叫結束才發（:120-128），widget snapshot writer 也不監聽登入狀態。離線，或在那之前 App 就被關掉時，上一位使用者的課表會留在主畫面和鎖定畫面上，直到下次開 App。另外，accent 的 setter 註解寫著只影響 Live Activity（`swift/TigerDuck/App/AppState.swift:363-370`），其實 widget 也用它（`swift/TigerDuckWidgets/Theme/WidgetPalette.swift:40`），換色後 widget 要等下次回前景才會變。
- **建議**：清快取後立刻重建 widget snapshot；widget writer 加上 accent 的監聽。
- **評估**：效益中高（隱私）；成本 S；風險低；配合：不需要；信心：程式路徑高，實際延遲多久中。

### 5.4 fix(LiveActivity): end a running class activity when the user skips that class（#276）

- **現況**：Live Activity 只在「不可用、倒數結束、當天不上課」三種情況下結束（`swift/TigerDuck/LiveActivity/Runtime/LiveActivityCoordinator.swift:325-346`），標記停課只會擋掉新的啟動。課前提醒（最多提前 4 小時）或上課中的 activity 顯示時標記停課，它會一直留在鎖定畫面上，直到倒數結束。
- **建議**：新增「已停課」的結束原因，做法和現有的 quiet day 一樣（`source_id` 是 `courseNo_yyyyMMdd_period`，可以取出課號與日期），也加進 `canStart`。ADR 0010 允許新增原因，記得更新裡面的清單。
- **評估**：效益中；成本 S–M；風險低；配合：不需要；信心高。

### 5.5 fix(Widgets): stop the lock-screen widget's reload loop without a snapshot（#277）

- **現況**：沒有 snapshot 時，鎖定畫面 widget 回傳單一 entry 加 `.atEnd`（`swift/TigerDuckWidgets/Widgets/AccessoryWidget.swift:24-31`）。`NextClassWidget.swift:40-51` 的註解正好說明了這樣會讓 WidgetKit 一直重新載入，所以那邊改成午夜再試。第一次開 App 前就加了 widget，或 snapshot 解碼失敗時會發生。
- **建議**：比照 `NextClassWidget` 改成午夜重試，順便改用台北時間的午夜。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心高。

### 5.6 fix(Widgets): give each block of a twice-a-day course its own Today row（#278）

- **現況**：「今日課表」widget 從第一節到最後一節組成一列（`swift/TigerDuckWidgets/Views/TodayListView.swift:100-107`），同一天 3–4 節和 7–8 節的課會變成一列「3–8 10:20–16:20」。推算邏輯和手錶都已經分段處理。
- **建議**：依 `contiguousRuns` 每段一列。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心高。

### 5.7 perf(Widgets): skip the write and reload when the snapshot did not change（#279）

- **現況**：`WidgetSnapshotWriter.regenerate()` 每次都寫檔並 `reloadAllTimelines()`（`swift/TigerDuck/Widgets/WidgetSnapshotWriter.swift:80-100`），每次回前景、每次 `dataDidUpdate`（包含跟 widget 無關的作業同步）都會跑。
- **建議**：先和已存的 snapshot 比較，相同就不寫也不 reload。
- **評估**：效益中（省 widget 的 reload 額度）；成本 S；風險低；配合：不需要；信心高。

### 5.8 perf(Watch): stop re-sending the library password and an unchanged schedule（#280）

- **現況**：每次 `dataDidUpdate` 都會推一次資料給手錶，而且每次都呼叫 `republishIfCredentialed()`（`swift/TigerDuck/Services/Watch/WatchSyncBridge.swift:33-36,72-76`），排進一個含圖書館密碼的 `transferUserInfo`，也不檢查有沒有配對的手錶；推送內容用 `Date()` 當時間戳，所以內容相同也一定會重送。
- **建議**：只在手錶要求同步或 epoch 改變時重送憑證；內容沒變就不推；先確認有配對手錶而且已經安裝 App。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心高。

### 5.9 fix(Watch): hide holidays and skipped classes on the Watch（#281、android#158）

- **現況**：手錶的 payload 沒有停課日和假日，`NextClassResolver` 只依星期篩選（`swift/Shared/Watch/NextClassResolver.swift:20-45`），放假或停課時手錶仍顯示下一堂課。
- **建議**：payload 加上假日與各課的停課日（用 optional key，舊版本照樣能解），在 resolver 裡篩掉。
- **評估**：效益中；成本 M；風險低；配合：Wear OS 有同樣的缺口；信心高。

### 5.10 perf(Mac): load class table and calendar data once per change, not per cell（#282）

- **現況**：Mac 課表的 `courses` 是 computed property，每次存取都從磁碟讀四個 JSON 再合併（`swift/TigerDuck/Platform/Mac/MacClassTableView.swift:93-107`；`DataCache` 沒有記憶體快取，見 `swift/TigerDuck/Services/Core/DataCache.swift:621-640`），而每一格都會讀它（`swift/TigerDuck/Platform/Mac/MacClassTableView+Grid.swift:95-108`），重畫一次就是上百次讀檔，點任何一門課都會重畫。Mac 行事曆的 `allEvents` 與 `eventsByDay` 也是每個日期格各解碼一次（`swift/TigerDuck/Platform/Mac/MacCalendarView.swift:38-50,252`）。iOS 版兩者都有快取。
- **建議**：資料放進 `@State`，在 `.task(id:)` 裡依學期與現有的 `cacheRevision` 重建。
- **評估**：效益中（Mac 點擊延遲）；成本 S–M；風險低；配合：不需要；信心高。

### 5.11 fix(Mac): leave holidays out of the Home cards and make ⌘R refresh Bulletins（#283、#284）

- **現況**：Mac 首頁的今日與下一堂課卡片只排除停課，不排除假日（`swift/TigerDuck/Platform/Mac/MacWidgetCards.swift:33-52`）。工具列的重新整理（⌘R）執行的是 `backgroundSync`，不會重抓公告（`swift/TigerDuck/Platform/Mac/MacRootView.swift:186-197,240-248`），Mac 公告頁也只有失敗時才有「重試」；iOS 可以下拉。
- **建議**：卡片用 `AcademicCalendarStore.shared.isClassDay` 篩選；公告頁的 ⌘R 改成呼叫 `viewModel.refresh()`。
- **評估**：效益低中；成本 S；風險低；配合：不需要；信心高。

### 5.12 refactor(LiveActivity): delete the write-only SharedSnapshotStore（#285）

- **現況**：Live Activity coordinator 會寫入 `SharedSnapshotStore`，但 `readSnapshot()` 在這個檔案以外沒有任何呼叫者（`swift/TigerDuck/LiveActivity/Runtime/SharedSnapshotStore.swift:56`），extension 用的是 `context.state.snapshot`。
- **建議**：刪掉這個 store、各個寫入點、`project.pbxproj` 裡的項目，以及 App Group entitlement 測試中的那一行。
- **評估**：效益低；成本 S；風險低；配合：不需要；信心高。

## 六、School Mail

### 6.1 fix(Mail): reload the open list when the inbox grew（#286）

- **現況**：回到 App 時，信箱頁只重新開始 polling，不會重新載入（`swift/TigerDuck/Features/SchoolMail/SchoolMailView.swift:337-340`），而且 polling 會先等 60 秒（`swift/TigerDuck/Features/SchoolMail/MailListViewModel.swift:505-518`）。頁面 poll 要不要重載，看的是和前景、背景檢查共用的 `inboxNextUID`（`swift/TigerDuck/Services/Mail/Sync/MailChecker.swift:244`）。通知開著時，回到 App 會先跑一次前景檢查，推一則 App 內的 banner，再把 marker 往前推（`swift/TigerDuck/Services/Mail/Sync/MailBackgroundRefresh.swift:93-103`、`MailChecker.swift:255-271`）；接著頁面 poll 得到 `.noNewMail`，列表就一直看不到那封信，直到使用者下拉、切換資料夾或收到下一封新信。背景檢查之後也一樣。
- **建議**：`pollOnce` 改成拿 inbox 的 `uidNext` 和列表自己最新的 UID 比較，大於最新 UID 加一就重載（最後一封 UID 是 100 的信箱，`uidNext` 是 101），否則 marker 只往前推；`.active` 時立刻 poll 一次。這是 Android 的做法（`android:…/ui/screen/mail/SchoolMailListViewModel.kt:468-480`）。做完可以拿掉 `.page` trigger 與 `existing:` 參數。另外，頁面 poll 也會寫進只有 10 筆的診斷紀錄（`MailChecker.swift:165`），在信箱頁待 10 分鐘，背景檢查的紀錄就全被擠掉，可以一起處理。
- **評估**：效益高；成本 S；風險低；配合：Android 已經這樣做；信心高。

### 6.2 fix(Mail): stop SwiftMail's fixed IMAP deadlines failing large transfers（#287）

- **現況**：vendored SwiftMail 的 IMAP 指令逾時從送出時開始計算，有進度也不會重置（`swift/Packages/SwiftMail/Sources/SwiftMail/IMAP/IMAPConnection+CommandExecution.swift:110-118`）：抓整封原始信 10 秒、抓單一 part 60 秒、APPEND 30 秒（`swift/Packages/SwiftMail/Sources/SwiftMail/IMAP/IMAP/Commands/FetchCommands.swift:105,151`、`AppendCommand.swift:16`）。逾時被對應成「連不上伺服器」（`swift/TigerDuck/Services/Mail/Transport/LiveMailClient.swift:627`），但 App 本身預期要處理最大 50 MB 的信（`swift/TigerDuck/Services/Mail/Core/MailConstants.swift:24-34`）。估算在約 3 Mbps 的連線下：20 MB 的附件會在 60 秒時失敗並斷線；檢視原始碼與超過數 MB 的信在 10 秒失敗；約 12 MB 的寄件備份或大草稿在 30 秒時存不進去。SMTP 本身的逾時沒有問題。
- **建議**：在 vendored 套件打一個 patch（`VENDORED.md` 加一條並附測試），把這三個上限拉到約 300 秒，或改成有進度就重置。Android 是有進度就重置。
- **評估**：效益高；成本 S；風險低（卡住的傳輸會佔住指令鎖比較久，ADR 0015 已經接受這個取捨）；配合：不需要；信心：程式路徑高，實際網速的影響中。

### 6.3 perf(Mail): take Reply-To from the header the message screen already fetched（#288）

- **現況**：回覆時為了讀 Reply-To，會用 `try?` 下載整封原始信（`swift/TigerDuck/Features/SchoolMail/MailComposeViewModel.swift:209-215`）。原因是 SwiftMail 解析標頭時把 `reply-to` 當成 envelope 欄位而丟掉，`MessageInfo` 又沒有這個欄位（`swift/Packages/SwiftMail/Sources/SwiftMail/IMAP/IMAP/Handler/FetchMessageInfoHandler.swift:108-119`）。回覆一封帶 20 MB 附件的信，要先在空白表單後面下載約 27 MB，期間不能送出；再碰上 6.2 的 10 秒上限通常會失敗，回覆就默默寄給 From，而不是 Reply-To。
- **建議**：vendored patch 保留 `reply-to`，`MailMessageDetail` 加一個 optional 的 `replyTo`，然後刪掉 `rawSource` 的呼叫。
- **評估**：效益高；成本 S；風險低；配合：不需要；信心高。

### 6.4 feat(Mail): show attachment download progress, ignore repeat taps, prune opened files（#289）

- **現況**：點附件後沒有任何進度狀態；整個檔案先放在記憶體裡，再寫成一個新的暫存檔（`swift/TigerDuck/Features/SchoolMail/MailMessageViewModel.swift:489-510`）。這些檔案只有登出或清快取時才刪（`swift/TigerDuck/Services/Mail/Store/MailCache.swift:149`），也不算進 20 MB 的快取上限。最多一分鐘沒有任何回饋，多點一次就多排一次完整下載（polling 也要排在後面），磁碟上也多一份。
- **建議**：view model 加一個 `downloading` 集合，顯示 spinner，重複點擊直接 return；開過的附件檔超過一天就清掉。Android 三項都有。
- **評估**：效益中高；成本 S；風險低；配合：不需要；信心高。

### 6.5 perf(Mail): trim each check: no STATUS, text-only prefetch, no base64 round trip（#290）

- **現況**：
  - 每次檢查（頁面 poll、背景、前景、移動信件）都多送一個 STATUS，只為了填一個沒有人讀的 `unseen`（`swift/TigerDuck/Services/Mail/Transport/LiveMailClient.swift:125-144`、`swift/TigerDuck/Services/Mail/Core/MailModels.swift:221`）。
  - 預先抓信件內文時，連每張 5 MB 以內的內嵌圖片都抓，而且沒有總量上限（`LiveMailClient.swift:228-239`）。背景用行動網路下載了幾 MB 的海報圖，結果超過 10 MB 又不快取。
  - 寄信時附件的 base64 先切行再接回去，結果完全一樣，白白多出大量字串配置（`swift/TigerDuck/Services/Mail/Compose/MailMessageBuilder.swift:80-86`）。
- **建議**：`status()` 只用 EXAMINE；預先抓取只抓文字部分（打開信時本來就會重抓）；拿掉 `components(separatedBy:)` 和 `joined`。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心高。

### 6.6 fix(Mail): skip checks while notification permission is denied（#291）

- **現況**：前景與背景檢查只看 App 內的通知開關（`swift/TigerDuck/Services/Mail/Sync/MailChecker.swift:157`）。使用者在系統裡拒絕通知後，每次喚醒和回到 App 仍然會做一次 TLS 連線加 LOGIN。
- **建議**：加一個 `MailNotificationPermission.isDenied()` 判斷，拒絕時不檢查，也不重新排背景工作。
- **評估**：效益低中；成本 S；風險低；配合：不需要；信心高。

### 6.7 fix(Mail): refresh flags when paging older mail（#292、android#159）

- **現況**：往前翻頁時只加入沒看過的 UID，不更新已經有的列（`swift/TigerDuck/Features/SchoolMail/MailListViewModel.swift:266-268`）；重新整理也只更新最新的 50 封，更早的列原樣保留並寫回快取（:808、:878-882）。在 webmail 上已讀或刪掉的舊信，在 App 裡會一直顯示未讀或還在，打開已刪除的信會失敗。
- **建議**：舊頁的合併方式比照第一頁，並把持久化的列表限制在約 200 列。
- **評估**：效益低中；成本 S–M；風險低；配合：Android 有同樣的缺口；信心中。

### 6.8 fix(Mail): use Button-based taps in the recipient rows（#293）

- **現況**：寫信畫面的收件人列用了 plain `.onTapGesture`（`swift/TigerDuck/Features/SchoolMail/Components/MailRecipientTokenField.swift:105,154`、`swift/TigerDuck/Features/SchoolMail/Components/MailRecipientRow.swift:80`），而它們位在 Form 或 ScrollView 裡，違反 `swift/TigerDuck/AGENTS.md` 的 iOS 18 手勢規則，可能要點兩次才有反應。
- **建議**：改用 `swift/TigerDuck/Extensions/View+ScrollSafeGesture.swift` 的 helper。
- **評估**：效益低；成本 S；風險低；配合：不需要；信心低中（沒有在裝置上確認）。

## 七、測試、CI 與維護

### 7.1 fix(Logging): give release builds a Sentry DSN, or remove Sentry（#294）

- **現況**：`AppLogger.start()` 從 Info.plist 讀 `SENTRY_DSN`，空的就傳 nil（`swift/TigerDuck/Services/Logging/AppLogger.swift:17-31`）。唯一的來源是 `INFOPLIST_KEY_SENTRY_DSN = "";`（`swift/TigerDuck.xcodeproj/project.pbxproj:1224,1476`），值本身就是空字串；本機 build 和封存的 1.5.2–1.7.0 版 Info.plist 裡都沒有 `SENTRY_DSN`，Xcode Cloud 的建置流程也沒有另外帶入。也就是說，從 2026-04-18 導入至今，所有 `AppLogger.captureError` 和 crash 回報都沒有送出去。另外 `AppState()` 在 `AppLogger.start()` 之前就建立了（`swift/TigerDuck/TigerDuckApp.swift:11,22`），`AppState.init` 裡發生的錯誤無論如何都送不出去。
- **打開前要先補的遮蔽**（依 sentry-cocoa 原始碼，信心中）：
  - Moodle REST 網址都帶 `wstoken=`，HTTP breadcrumb 會把 query 存進 `data["http.query"]`，目前沒有 `beforeBreadcrumb`。
  - 預設開啟的 failed-request 事件把 token 放在 `request.query_string`，但 `beforeSend` 只清 `request.url`（`AppLogger.swift:26-31`）。
  - `NSError` 的 userInfo 與 `error.description` 沒有遮蔽，例如會帶完整網址的 `unexpected OIDC page: <url>`（`swift/TigerDuck/Services/API/Moodle/MoodleTokenService.swift:441`）。
  - Debug build 的 `environment` 也是 production。
- **建議**：二選一。
  - 保留：DSN 由 Xcode Cloud 的 secret 經 `SENTRY_DSN = $(SENTRY_DSN)` 帶進 Info.plist；補上 breadcrumb、query string 與 exception value 的遮蔽；依 configuration 設 `environment`；`failedRequestTargets` 只留後端；`AppLogger.start()` 移到 `AppState()` 之前；替 `scrubSensitive` 補測試。
  - 移除：拿掉套件、`AppLogger.start()` 和授權條目，並修正 `docs/third-party-migration-plan.md` 與 `swift/TigerDuck/Services/AGENTS.md` 的描述。
- **評估**：效益高（線上目前完全沒有錯誤資料，1.5 也依賴它）；成本 S–M；風險：沒補遮蔽就打開，會把 token 送上 Sentry；配合：不需要；信心高。

### 7.2 fix(Launch): delete the real SQLite sidecars when the iOS store is reset（#295）

- **現況**：iOS 版重設 SwiftData store 時，用 `appendingPathExtension` 刪 `default.store.wal` 和 `.shm`（`swift/TigerDuck/TigerDuckApp.swift:56-62`），但實際的 sidecar 是 `default.store-wal`。Mac 版已經在 68787031 修好（:276-290），那個 commit 說的正是「壞掉的 sidecar 沒刪，重試又讀到同一份資料」。iOS 若遇到 store 打不開，重試可能再次失敗，之後每次啟動都退回記憶體中的 store。
- **建議**：兩個平台共用一個 `makeModelContainer()`，順便刪掉約 35 行重複程式。
- **評估**：效益中（罕見但嚴重）；成本 S；風險低；配合：不需要；信心高。

### 7.3 ci(Tests): build the macOS app on pull requests（#296）

- **現況**：`tests.yaml` 只跑手機與手錶的單元測試，檔頭寫明不測 macOS（`.github/workflows/tests.yaml:3-4`）；`tools/check_macos_sources.py` 只檢查檔案歸屬。過去就有 Mac 專屬的編譯錯誤進到分支（ad7616cd 修的 `LibraryQRImageCache`、45cfb081 修的 `AppState+CourseReconcile`）。
- **建議**：matrix 加一個 `mac`：`xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`，共用現有的快取。不需要模擬器，熱快取下約 3–5 分鐘，和其他 job 並行；repo 是 public，Actions 分鐘數不收費。
- **評估**：效益高；成本 S；風險低；配合：不需要；信心高。

### 7.4 test(SSO): fixture tests for HTMLParser, the Moodle token decoder and error mapping（#297）

- **現況**：`HTMLParser`（`swift/TigerDuck/Services/Core/HTMLParser.swift`）決定每一次 SSO 登入的成敗，也決定課表與成績的 bounce 判斷，卻沒有任何測試或 HTML fixture；`MoodleTokenService.decodeTokenTriple` 和 `MoodleWebserviceError.from(jsonData:)` 都是純函式，同樣沒有測試。#233 之後 Dependabot 會定期升級 SwiftSoup，但沒有測試會用到它。
- **建議**：用手工製作或去識別化的頁面當 fixture，涵蓋 ssoam2 表單、OIDC bridge、維護頁與 ssoam 頁。
- **評估**：效益高；成本 S；風險低；配合：不需要；信心高。

### 7.5 test(LiveActivity): pin which scenario the Live Activity shows（#298）

- **現況**：`LiveActivityScenarioResolver.resolve`（`swift/TigerDuck/LiveActivity/Resolvers/LiveActivityScenarioResolver.swift:19-79`）決定顯示哪一種情境：作業優先於上課中、上課中優先於課前，假日擋課程但不擋截止日，還有停課與提前時間的邊界。它是純函式，但目前只有雲端同步開關有測試（`swift/TigerDuckTests/LiveActivitySyncGateTests.swift`）。4.3 和 5.4 都會改到這裡。
- **建議**：先補表格式的測試，再做 4.3 與 5.4。
- **評估**：效益中高；成本 S；風險低；配合：不需要；信心高。

### 7.6 test: keep the test host from running the app's launch work（#299）

- **現況**：單元測試以 TigerDuck.app 為 host（`swift/TigerDuck.xcodeproj/project.pbxproj:1537`），所以測試時 `AppState.init`、第一次 `onAppear`（背景同步、widget snapshot、App Store 版本查詢）與行事曆更新都會執行，但沒有任何測試需要它們。在已登入的開發模擬器上跑測試，會真的連 NTUST 與 Moodle 同步，並在 ADR 0020 的保護之外寫入 Defaults，還會和測試搶 main actor。
- **建議**：`@main` 判斷 `XCTestConfigurationFilePath`，測試時只顯示一個空的 scene。
- **評估**：效益中；成本 S；風險：原本默默依賴 host 副作用的測試會現形（例如 `SchoolMailCharsetHook.install()`）；配合：不需要；信心中高。

### 7.7 perf(Launch): cut main-thread Keychain reads before the first frame（#300）

- **現況**：第一個畫面出來之前，Release build 會在 main thread 同步讀約 8 次 Keychain：`AuthService.init` 讀學號和密碼（密碼只為了判斷存不存在）、`PushIdentity.loadOrCreate` 1 次、`AuthTokenManager.init` 3 次，`PushCoordinator.assertEnvConsistency` 2 次（只給 `assert` 用，Release 根本不檢查）。`DebugEndpointStore.currentOverride` 每次呼叫都讀 Keychain，`PushAPIClient` 每個請求都會讀，包括 10 秒一次的 polling。第一次 `onAppear` 也同步建立並寫入 widget snapshot（`swift/TigerDuck/TigerDuckApp.swift:115-118`）。
- **建議**：`assertEnvConsistency` 整段包進 `#if DEBUG`；`currentOverride` 加記憶體快取，設定或清除時失效；`hasStoredCredentials` 改用快取（同 4.8）；widget snapshot 延到第一個畫面之後。改動前後用 Instruments 的 App Launch 量測。
- **評估**：效益中（沒有量測）；成本各 S；風險低；配合：不需要；信心中。

### 7.8 chore(Migrations): delete the four migrations shipped before 1.7.1（#301）

- **現況**：`MoodleTokenMigration`、`HomeSectionTitleMigration`（2026-04-21）、`ClassroomAbbrCacheMigration`（05-01）、`CustomNameCacheMigration`（05-15）都已經上線五到六個月，依 `swift/TigerDuck/Services/Migrations/AGENTS.md` 的生命週期可以刪了。`SemesterAttributionCacheMigration`（08-20）可以下一版再刪；09-12 加的三個依各自的說明，要等最低支援版本超過 2.1.0；`DefaultTabsPinMigration`（10-05）保留。遷移資料夾以外，`DataCache.absorbLegacyCourseCache()` 每次啟動都會列一次快取目錄（`swift/TigerDuck/Services/Core/DataCache.swift:41`），也是 v1.3.x 時代的相容程式。
- **建議**：刪掉這四個檔案、它們在 `runPendingMigrations()` 裡的呼叫和 `moodleTokenMigrationDone` key，連同 `absorbLegacyCourseCache()`。
- **評估**：效益低中；成本 S；風險：還停在 1.7.0 以前、直接跳到新版的使用者會略過這些遷移（`MoodleTokenService` 自己會補拿 token，其餘都只是快取）；配合：不需要；信心：日期高，風險評估中。

### 7.9 chore: delete dead code and untrack two stray root files（#302）

- **現況**：下列項目在整個 `swift/` 裡只有宣告、沒有使用：
  - 型別與檔案：`Bridge/ModelAdapters.swift`（`swift/TigerDuck/AGENTS.md` 也記為空殼）、`Services/Auth/SSOWebAuthSession.swift`（只有 TODO）、`Models/Domain/MockData.swift`（182 行）、`WidgetGridEditMode`、`MoreEditModeView`、`AssignmentCountBadge`、`LoadingShimmer`。
  - 函式：`HTMLParser.extractInputFields`、`PushAPIClient.cancelSchedule`、`HomeViewModel.hasUnfinishedAssignment`、`BulletinsViewModel.clearFilters` 等。
  - repo 根目錄的 `oh-my-openagent.json` 與 `tigerduck-app.iml` 被 git 追蹤，看起來是本機工具的設定檔。
- **建議**：刪除時一併更新 `project.pbxproj` 的 macOS 清單或 `tools/macos-excluded-sources.txt`，以及 `swift/TigerDuck/AGENTS.md` 的對應條目；根目錄兩個檔案 `git rm --cached`，並忽略 `*.iml`。`TigerDuckWatchWidget/` 的去留見 8.1。
- **評估**：效益低（減少維護量）；成本 S；風險低；配合：不需要；信心高。

### 7.10 test(ClassTable): keep one conflict layout and test it（#303）

- **現況**：iOS 的課表格子角色（`swift/TigerDuck/Features/ClassTable/ClassTableViewModel+Grid.swift:61-131`）另外實作了一份 `swift/TigerDuck/Shared/ClassTableLayout.swift` 的演算法；Mac 課表和 widget 用的是後者。兩份都沒有測試排版本身。
- **建議**：先在 `ClassTableLayout` 補重疊與三門課串連的測試，再讓 iOS 改用它（保留現有的快取）。這也是 #153 的前置。
- **評估**：效益中；成本 S（測試）、M（合併）；風險低；配合：不需要；信心高。

### 7.11 test: fix three leaky tests（#304）

- **現況**：
  - `NameAbbrServiceTests` 把 `Defaults[.appLanguage]` 設成 `"en"` 後沒有還原（`swift/TigerDuckTests/NameAbbrServiceTests.swift:58,90`），會影響其他測試和模擬器裡的 App。
  - `MoodleHomeworkRegressionTests` 寫進真正的 `DataCache.shared`，留下 `courses_TEST_ISO_*` 檔案（`swift/TigerDuckTests/MoodleHomeworkRegressionTests.swift:42`）。
  - `TimeSliderViewModelTests` 用 `Calendar.current` 和 `Date()` 組出「今天」，只有在 Asia/Taipei 時區才會通過，目前是靠 CI 固定時區。
- **建議**：還原 Defaults、改用暫存目錄的 cache、改用台北曆與 `AppClock`。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心高。

## 八、新功能

### 8.1 feat(Watch): ship the next-class complication（#305）

- **現況**：`swift/TigerDuckWatchWidget/` 已經寫好四種錶面樣式、以台北時間為界的 timeline 與 relevance，也有 snapshot 測試，但 `project.pbxproj` 裡沒有任何引用，專案也沒有手錶的 widget extension target。README 卻把錶面複雜功能列為已上線（`README.md:60,206`、`README.en.md:60`）。手錶 App 已經把資料寫進 App Group 並呼叫 reload（`swift/TigerDuckWatch Watch App/Services/ScheduleStore.swift:24`），只差 target 和簽章。Wear OS 有 tile 和 complication。
- **建議**：新增 watchOS widget extension target，App Group 用 `group.org.ntust.app.TigerDuck.watch`，編入這個資料夾以及 `Shared/Watch`、`SharedAppGroup`、`WatchAppLogger`、`WatchTheme` 與 Clock 相關檔案；provider 裡的 `Date()` 改用 `AppClock.now()`。最好先做 5.9，免得錶面在假日也顯示課程。短期內不做的話，先修正 README。
- **評估**：效益高（錶面與智慧型疊放）；成本 M（新 target 與 provisioning）；風險低；配合：不需要；信心高。

### 8.2 feat(Notifications): let users turn class reminders off and choose the lead time（#306）

- **現況**：上課提醒是後端推播，只送 iPhone 和 iPad（`backend:server/push/course_reminders.py:194`），預設開啟、上課前 10 分鐘（:160、`backend:server/config.py:202-204`）。App 對通知設定文件的 `courses` 區段只做原樣轉傳（`swift/TigerDuck/Services/Sync/NotificationSettingsDocument.swift:39-49`），沒有任何設定畫面；iOS 也沒有依類型關閉通知的系統開關，想關掉只能關掉全部通知。Android 的上課提醒跟著課前 Live Update 的開關，以及 5 分鐘到 4 小時的提前時間。
- **建議**：通知設定加入「上課提醒」開關與提前時間，寫進 `courses.enabled` 與 `courses.reminder_offsets_minutes`；後端已經會讀這兩個欄位，不必改。
- **評估**：效益高；成本 S（含要審的文案）；風險低；配合：不需要；信心高。

### 8.3 feat(Push): open the assignment when a reminder is tapped（#307）

- **現況**：作業提醒的 payload（`kind: "assignment_reminder"`）已經帶了 `moodle_assignment_id` 與 `moodle_course_id`，後端註解也寫明由 client 依此 deep link（`backend:server/push/reminders.py:296-308`），但 iOS 的點擊路由沒有處理這個 kind（`swift/TigerDuck/TigerDuckApp.swift:189-215`）。
- **建議**：比照 4.1 加一個 case，打開首頁並捲到那份作業，或直接開 Moodle 頁面（搭配 4.5 的備援）。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心高。

### 8.4 feat(iOS): App Intents and a library QR control（#308）

- **現況**：整個 `swift/` 沒有任何 `AppIntent`、App Shortcuts、`ControlWidget`、Spotlight 索引或 `MenuBarExtra`。目前有的是：連到 `tigerduck://library` 的小型圖書館 widget、翻面顯示 QR、鎖定畫面 widget，StandBy 也會顯示小型 widget。iOS 部署目標是 18.0，可以使用控制中心的控制項。
- **建議**：做一個「打開圖書館 QR」intent（沿用 `WidgetURLRouter`），同時用在控制中心、鎖定畫面、動作按鈕和捷徑；「下一堂課」intent 直接用快取的課表與 widget 的推算邏輯回答，不需要網路。
- **評估**：效益中高；成本 M；風險低；配合：不需要；信心高（確定目前沒有）。

### 8.5 feat(Home): stack overlapping courses in lanes on the time slider（#309）

- **現況**：時光機的軌道把每段課程畫在同樣的高度與中心線上（`swift/TigerDuck/Features/Home/Components/TimeSlider/FluidGlassTrackView.swift:34-52`），衝堂時後面的課會蓋住前面的課。Android 用 lane 疊放（android PR #82）。
- **建議**：沿用 #153 要做的 lane 分配（見「九、#153」），在軌道上分成上下兩條。
- **評估**：效益中；成本 S；風險低；配合：不需要；信心高。

### 8.6 其他點子（P3）（#310、#311、#312、#313、#314、#315、#316、#317、backend#31）

| 標題 | 現況與做法 | 成本 |
|---|---|---|
| feat(Mac): add a menu bar next class and more keyboard shortcuts | 目前的快捷鍵只有 ⌘R、⌘,、月份切換與 Esc。macOS 14 可以用 `MenuBarExtra`，沿用下一堂課卡片的邏輯；再加 ⌘1–5 切換側邊欄、⌘F 搜尋公告。 | S–M |
| feat(Calendar): tap a Moodle deadline to open it | 行事曆裡 Moodle 事件的 id 是 `moodle-<assignmentId>`，列表項目目前沒有點擊動作。 | S |
| feat(Score): add a GPA what-if | 讓學生替還沒出分的課選預期成績，沿用 `NTUSTGradePoints.gpa(of:)` 算出預估的學期與累計 GPA，只在本機計算。 | S–M |
| feat(More): build the empty-classroom finder | 「空教室」目前是 placeholder。可以移植 `api-poc/api/ntust/classroom.py`，但要照 `api-poc/api/AGENTS.md` 處理表單步驟的順序，並記得「空表格不代表全部空著」。 | M–L |
| feat(InfoSystem): list the Information System portal links | Android PR #131（draft）把 `i.ntust.edu.tw/student` 的連結整理成六類。只列連結是 S；要在 App 內帶著登入狀態打開，需要 WKWebView 與 cookie 橋接，並先做 3.3 與 `cardsystem.ntust.edu.tw` 的 pin。 | M–L |
| feat(Theme): add Light and System appearance | App 強制深色（`swift/TigerDuck/TigerDuckApp.swift:90`），顏色 token 都是固定的深色值，約 288 處使用；widget 已支援兩種外觀。Android 有系統、深色、淺色三種。 | L |
| feat(Reminders): remind once about homework marked done but not submitted | Android 對「自己標記完成、Moodle 上仍未繳交」的作業，會在最後一個提醒時間再提醒一次；後端提醒目前排除這些作業，需要後端配合。 | S–M |
| feat(Privacy): add a switch for diagnostics reports | 7.1 決定保留 Sentry 之後，在設定裡加一個開關；Android 的分析功能要使用者同意才開。 | S |

## 九、既有 issue

### #236 bug(Sync): courses_reset_at never parses

- **現況**：仍然成立。`ISO8601DateFormatter()` 預設不接受小數秒（`swift/TigerDuck/App/AppState+BackendSync.swift:178-188`），後端用 `isoformat()` 送出含微秒的時間。比對對象 `lastCourseSyncAt` 是裝置時鐘，每次同步都會更新（:204），登出也不會清。全 App 掃過一遍後，其他後端時間欄位不是用已經支援小數秒的解碼方式，就是保留為字串，所以這是唯一壞掉的解析。
- **建議**：issue 的兩個選項中，傾向「保留，但改成比對這台裝置上次套用過的 `courses_reset_at`（每個帳號記一份）」，因為 Android 和舊版仍會做全量重設，後端也還依賴這個欄位。解析方式比照 `JSONDecoder.DateDecodingStrategy.iso8601WithFractionalSecondsFallback`（`swift/TigerDuck/Extensions/JSONDecoder+ISO8601.swift:11`），有沒有小數秒都能解。
- **評估**：成本 S；配合：不需要；信心高。

### #230 bug(Sync): choosing Use Local brings deleted courses back

- 已在 `dev` 由 #235 修好，跟下一次 release PR 一起關閉。在 Android 修好（android#153）之前，Android 的 Use Local 仍會清掉伺服器上所有課程 tombstone，Apple 端也會受影響。

### #233 chore(deps): check the first Dependabot and Renovate pull requests

- **現況**：`generate_licenses.py --check` 會比對每個 pin 的版本與 revision（`tools/generate_licenses.py:342-373`），所以每個 Dependabot 的 Swift PR 都會在 `licenses.yaml` 失敗，直到有人在 Mac 上跑 generator 並推上去。Renovate 的 onboarding PR #229（對 main）在 2026-10-10 關閉、沒有 merge；`.github/renovate.json` 進到 main 之後，要確認 Dependency Dashboard 有出現。
- **建議**：generator 加一個模式，依每個 pin 的 revision 淺層 clone 到暫存目錄，當作 `--checkouts` 傳入。這只用 git、不會執行 package manifest，可以在 ubuntu 上對 bot PR 跑。先做成只對 `dependabot[bot]` 執行的 job，把 licenses 的差異存成 artifact（S）。要自動推回 PR 分支（M）需要 App 或 PAT token：用 `GITHUB_TOKEN` 推的 commit 不會重跑 required checks，而 Dependabot 也不會再 rebase 有別人 commit 的 PR。
- **評估**：成本 S–M；信心：做法高，GitHub 平台細節中。

### #211 bug(Widget): 完整課表大小的 Widget，教室地點顯示錯誤

- **根因**：Widget 的 snapshot 用的是 `course.classroom`（`swift/TigerDuck/Widgets/WidgetSnapshotBuilder.swift:33`），這個字串是把課程所有教室用逗號接起來的（`swift/TigerDuck/Bridge/AppServiceBridge.swift:624`），週課表格子再用 `lineLimit(1)` 顯示（`swift/TigerDuckWidgets/Views/WeekGridView.swift:205-209`），就變成截圖裡的「TR-313, ...」。下一堂課、今日與鎖定畫面的 widget 也用同一個字串（`NextClassView.swift:111,142`、`TodayListView.swift:144`、`AccessoryViews.swift:73,86`）。App 的課表則是依節次用 `CourseRoomHint.room(for:weekday:periodId:)` 挑一間（`swift/TigerDuck/Features/ClassTable/Components/TimetableGridView.swift:149`），手錶也已經依區段挑選（`swift/TigerDuck/Services/Watch/WatchPayloadEncoder.swift:104-122`）。
- **建議**：`SnapshotCourse` 加上 `classroomMap`（解碼時給預設值，不必改版本）；週課表依格子的節次挑教室，下一堂課與今日依該段的第一節；把 `classroomForRun` 移到共用的 helper。Live Activity 與 Mac 下一堂課卡片用的 `classroom(for: weekday)`（`swift/TigerDuck/Models/SwiftData/SDCourse.swift:160-178`），在同一天上兩次課時也會接成兩間教室，一起改；伺服器推送的 activity 會經由 `ScheduleSyncService` 一起修好。
- **評估**：成本 S–M；配合：不需要；信心高。

### #209 bug(Homework): 課堂助教不應該跳出作業與作業未完成通知（backend#27、android#160）

- **現況**：作業清單向 Moodle 要的是所有選課的作業（`swift/TigerDuck/Services/API/Moodle/MoodleAssignmentService.swift`），不分身分；Live Activity、首頁和送給後端的清單都讀同一份快取。iOS 從 2.1.0 起，作業提醒全部由後端送出，而後端自己的 Moodle 同步（`backend:server/syncjobs/moodle_client.py`）同樣不分身分。
- **建議**（依 PoC 順序）：
  1. 成本最低：`mod_assign_get_assignments` 加 `capabilities[0]=mod/assign:submit`，Moodle 會排除使用者沒有繳交權限的課（助教與教師角色沒有這個權限）。
  2. submission status 沒有 `lastattempt` 也是一個訊號。
  3. 需要明確角色時，用 `core_user_get_course_user_profiles` 一次取回各課的 `roles`。

  先用助教帳號跑 api-poc 的 `assignments` 與 `submission_status` 驗證 1、2，再在 App、後端 fetcher 與 Android 加同一個參數。
- **風險**：學校若自訂一個從學生角色複製出來的助教角色，1、2 都會失效。
- **評估**：成本各 S；配合：後端與 Android；信心中（Moodle 的行為依原始碼推論，需要 PoC）。

### #210 feat(Homework): 允許手動針對課程忽略作業（backend#28、android#162）

- **現況**：單份作業的忽略與完成已經有了，存在 `archived_assignments.json`，並以 `local_status` 同步，後端提醒也會排除（`backend:server/push/reminders.py:51`）。課表格子已經有長按選單（`swift/TigerDuck/Features/ClassTable/Components/TimetableGridView.swift:203`）。
- **建議**：
  - App 端：長按選單加「忽略作業」與「取消忽略作業」，badge 加一個忽略的樣式；每個使用者存一份忽略的課程集合（登出時清掉），在 `DataCache.loadAssignments()` 的 overlay 裡套用，首頁、badge、詳細頁與 Live Activity 就都會跟著變。
  - 後端：`user_course_overrides` 加 `ignore_assignments`，`reminders.py` 檢查它，也順便讓這份清單跨裝置同步。只做 App 端的話，伺服器自己抓到的新作業仍然會提醒。
  - 先做 4.3。助教（#209）也可以先用它當手動的替代方案。
- **評估**：成本 App M、後端 S–M；配合：後端與 Android；信心高。

### #208 feat(ClassTable): 課表頁面的額外功能與最佳化（android#161）

- **現況**：課程查詢的回應已經有 `RequireOption`（`swift/TigerDuck/Services/API/NTUST/NTUSTAPIModels.swift:12`），但沒有對應到任何地方；`SDCourse` 只帶了 `dimension` 與 `allYear`。Android 也解碼了，但沒有使用。
- **建議**：照 69c530ad（加入 `dimension`、`allYear` 的 commit）的路線加 `requireOption`：`SDCourse`、`CourseData`、bridge 的查詢、`DataCache` 的 `CachedCourse`、Add Course 與 reconcile。接著在課程詳細頁加一列，課表格子加 `strokeBorder`，設定預設開啟。開始前先用 `course_lookup` probe 確認代碼值。
- **評估**：成本 S–M；配合：Android；信心：模型高，代碼值中。

### #153 feat(UI): 三堂課不同時衝堂課表顯示可優化

- **現況**：三門以上互相重疊時，iPhone 為每門課各開一欄（`swift/TigerDuck/Features/ClassTable/Components/TimetableGridView.swift:293` 有 TODO），Mac 與 widget 透過 `ClassTableLayout`（`swift/TigerDuck/Shared/ClassTableLayout.swift:132-150`）也是同樣做法。Android 已經用貪婪的區間著色分配 lane（`android:…/ui/screen/classtable/ClassTableCellLayout.kt:195-232`），A、B、C 串連時只需要兩條 lane。
- **建議**：`ClassTableLayout` 加上 `lane` 與 `laneCount`，畫 `laneCount` 欄；同時讓 iOS 改用 `ClassTableLayout`（見 7.10），三個平台一起改善。時光機上的疊放見 8.5。
- **評估**：成本 S–M；配合：Android 已有；信心高。

### #135 style(Calendar): macOS 行事曆圓形標記與外框沒有 Padding

- **現況**：日期數字是 28 pt 的圓，上方 padding 4 pt，選取格的背景只內縮 3 pt（`swift/TigerDuck/Platform/Mac/MacCalendarView.swift:316-353`），圓的頂端和背景邊緣之間只剩 1 pt；「今天」的外框用 `stroke`，線寬有一半畫在框外。8588db54 曾經以這組數字關閉這個 issue，之後又重新打開。
- **建議**：拿掉額外的選取背景（實心圓已經表示選取，和 iOS 一樣），或把上方 padding 拉到約 8 pt；外框改用 `strokeBorder`；補上 iOS 已有的無障礙標籤。
- **評估**：成本 S；配合：不需要；信心中（要看實際畫面確認）。

### #167 feat(Calendar): 可以加入自定義活動或是直接同步進原有行事曆

- **建議**：先做匯出，不先做 App 內的自訂活動。
  - 最便宜：沿用現有的分享流程（`ClassTableExporter`、`ShareSheet`）產生一次性的 `.ics`，內容是課程時段（加上學期起訖，假日當作例外）與 Moodle 截止日。不需要權限，也不需要後端；缺點是重複匯入會產生重複的事件。
  - 要持續同步：用 EventKit 寫進 App 自己的「TigerDuck」行事曆，需要完整存取權限與 usage description（見 4.7）。
  - 長期：由後端提供 webcal feed，跨平台通用，但要設計私密網址。
- **評估**：成本 `.ics` S–M、EventKit M；配合：視做法；信心中。

### #168 feat(Notification): custom ring sound（backend#29）

- **現況**：App 唯一的本機通知是 School Mail（`swift/TigerDuck/Services/Mail/Sync/MailNotifier.swift:137` 用 `.default`）；上課、作業、公告都是遠端推播，後端把 `aps.sound` 寫死成 `"default"`（`backend:server/push/job_payloads.py:235`、`backend:server/push/payload.py:165,271`）。專案裡沒有 Notification Service Extension。
- **建議**：先在通知設定文件加上「各類通知是否響鈴」，後端在關閉時省略 `aps.sound`（後端已經在讀這份文件）。之後要自訂鈴聲，可以把 `.caf` 打包進 App、由後端送檔名；或加一個 Notification Service Extension，依 App Group 裡的偏好改寫聲音（不必改後端，但多一個 target）。
- **評估**：成本 S 起；配合：後端；信心高。

### #50 feat(iPad): iPad Enhancement

- **現況**：iPad 用的是 iPhone 版面。target 支援 iPad（`TARGETED_DEVICE_FAMILY = "1,2"`），但只有圖書館與 Onboarding 會依尺寸調整，`Platform/Mac` 以外沒有 split view。
- **建議**：
  - `MainTabView` 加 `.tabViewStyle(.sidebarAdaptable)`（iOS 18 可用，iPhone 不受影響）；首頁、成績、行事曆在 regular 寬度下限制閱讀寬度約 700 pt（S）。
  - 公告在寬螢幕改成列表與內容兩欄，可以參考 `MacBulletinsView`（M）。
  - 外接鍵盤支援 ⌘R 與 ⌘1–5。
  - 要確認 sidebar 和「更多」分頁的互動。
- **評估**：成本 S–M；配合：不需要；信心中。

### #52 feat(moodle3): 作業兼容臺師大 Moodle

- **現況**：Moodle 網址寫死在好幾處（`MoodleAPIModels.swift:6`、`MoodleTokenService.swift:13-14`、`swift/TigerDuck/App/AppConstants.swift:72`、`AppServiceBridge+Assignments.swift:223`，以及後端的 `moodle_base_url`）。OIDC 流程中 Moodle 的那一半是通用的，身分提供者那一半則是 NTUST 專用。
- **建議**：屬於 L 級的工作：
  - token 要依網站分開存。
  - 作業 id 要加上網站前綴；`SDAssignment.assignmentId`、`moodle-<id>` 的行事曆 id、標記集合，以及後端的提醒 key 都會撞號。
  - 臺師大的課程 idnumber 沒有 NTUST 的學期前綴，現在的學期篩選會把它們濾掉。
  - 後端 schema 與 Android 都要改。

  第一步先查臺師大公開的 `tool_mobile_get_public_config`，看能不能用 `ASWebAuthenticationSession` 走瀏覽器登入。先做 3.8。
- **評估**：成本 L；配合：後端與 Android；信心中。

### #162 feat(Moodle): 考慮自架 Moodle LMS 以自行模擬 edge case

- **建議**：做完 3.8 之後約需 2–3 天。
  - 比照 ADR 0007，做一個只在 DEBUG 出現的 Moodle 網址覆寫。
  - 切換時清掉 Moodle 狀態，絕不把 NTUST 的 token 或密碼送到覆寫的主機。
  - token 從測試站的安全金鑰頁面貼上即可，不需要登入流程。
  - 覆寫期間不上傳到後端。
  - 測試課程要用 NTUST 格式的 idnumber，才會出現在課表裡。
- **評估**：成本 M；配合：不需要；信心中。

### #212 feat(Moodle): 可在 app 內查看課堂成員、詳細資訊、公告、附件等額外資訊

- **現況**：api-poc 已經有對應的 probe，Swift 端都還沒有。依學生的需求與成本排序：
  1. autologin（S–M）：用已存的 private token 換取瀏覽器登入網址，順便解決沒裝 Moodle App 時「在 Moodle 中打開」沒有反應的問題（同 4.5）。要遵守每 6 分鐘一次的限制，並檢查 `autologinurl` 的主機。
  2. 公告（M）：一次 forums-by-courses，再對 news forum 取討論串，需要呈現 HTML。
  3. 課程檔案（M）：每門課一次 `core_course_get_contents`；保留 site info 的 `userprivateaccesskey`，改走 `tokenpluginfile`，`AppLogger` 也要遮蔽這段路徑。
  4. 測驗截止日（S，放進行事曆）；包含作答紀錄是 M。
  5. 成績總覽（S–M）。
  6. Moodle 通知（M）：要用真正的 `useridto`，並依 `site_info.functions` 選擇未讀計數。
  7. 討論區（M），排在公告之後。
  8. 課堂成員（S）：價值低，而且會帶出同學的個資，建議最後做或不做。
- **前置**：先做 3.8，否則網站沒開放的函式會被當成 token 失效。
- **評估**：成本依項目；配合：不需要；信心中高。

### #213 feat(Library): 圖書館系統新功能與最佳化

- **現況**：目前只有登入與輪替的入館 QR（`swift/TigerDuck/Services/API/Library/LibraryService.swift`），「討論小間」和「講座」在「更多」裡是即將推出的 placeholder；api-poc 沒有館藏查詢或借用的 probe，Android 也還沒有。
- **建議**：先把 placeholder 改成用 `InAppBrowserView` 開圖書館自己的頁面，借用的入口註明需要校內網路（S）；原生版本要先寫 probe（L）。借用需要校內網路，而 `NetworkMonitor` 偵測不到，所以要有自己的錯誤訊息。
- **評估**：成本 S 或 L；配合：不需要；信心中。

## 十、查過、目前沒有發現問題的部分

- **同步**：通知設定文件的 JSON merge、409 重試與登出時的 generation 檢查（ADR 0002）；outbox 檔案的逐筆解碼與 `clearAll` 的 generation 檢查；課程 reconcile 的 tombstone 順序與重設鎖（ADR 0005）；假日例外佇列；推播註冊的退避（最多 600 秒）與每小時重送；同步相關檔案沒有使用 `Calendar.current`。
- **登入與學校資料**：SSO 登入佇列與登出後的 generation 檢查、帳密只送往白名單主機；Moodle OIDC 流程（最多 6 步、主機檢查、在 main actor 之外執行）；學期代碼（包含暑修）的解析；`NetworkMonitor` 的 captive portal 偵測；TLS delegate 的主機比對與到期後的退回。
- **功能頁**：捲動內容上沒有 plain `.onTapGesture`（Add Course 的背景點擊有註明原因）；formatter 都是 static；列表都是 lazy；登出後首頁、課表、行事曆與公告都會從清空的快取重讀；匯出的課表圖片在分享後會刪除。
- **Widget 與 Live Activity**：結束策略符合 ADR 0010 與 0012；push-to-start token 的轉送；權限閘門（ADR 0011）；timeline 使用台北時間並套用 debug clock；舊版 snapshot 仍然可以解碼。
- **School Mail**：UIDVALIDITY 的處理、單一連線與指令序列化、登出時的競態、`BODY.PEEK`、web view 的鎖定（ADR 0003）、SMTP 逾時；`DevMail*` 只在 DEBUG 編入。
- **CI**：每個 workflow 的 token 預設唯讀，action 都釘了 SHA；`tools/` 的唯讀檢查在 `dev` 上全部通過；2026-09-13 之後沒有 flaky 的失敗。
- **和 Android 對照後確認 Apple 已有**：通知依 thread 分組、iOS 課表圖片匯出、HTML 信件的淺色檢視、收件人泡泡與 To／Cc 分列、更新提示、合開與暑修課程、0.5 學分、課表依節次顯示教室、公告篩選記憶、課名字級設定、伺服器推播彈窗、每台裝置的通知同步、夜間節次。

## 十一、總表

依 issue 的 Priority 排序，同一級內依文件順序。另行回報的資安項目不在表內。

| 優先 | 規模 | 文件 | Issue | 標題 | 相關 |
|---|---|---|---|---|---|
| Urgent | 小 | 2.1 | backend#23 | bug(sync): the server's Moodle sync orphans assignment marks attached to upload placeholders | — |
| Urgent | 小 | 2.2 | #243 | bug(ClassTable): a failed course lookup wipes class times on every synced device | — |
| Urgent | 小 | 3.1 | #253 | chore(Security): rotate the TLS pins before they expire on 2027-01-18 | android#157 |
| Urgent | 小 | 4.2 | #263 | bug(Score): after switching accounts, Score can show the previous account's grades | — |
| High | 小 | 1.1 | #238 | perf(Sync): revision polling never backs off and keeps polling every 10 seconds | android#154、backend#32 |
| High | 小 | 1.2 | #239 | perf(CloudSync): every outbox tick fetches /sync/full and throws it away | backend#24 |
| High | 小 | 2.3 | #244 | bug(CloudSync): five server errors in a row drop an assignment mark for good | — |
| High | 小 | 2.5 | #246 | bug(Sync): a full sync that outlives a sign-out writes the previous account's data | — |
| High | 小 | 3.2 | #254 | bug(Auth): silent sign-ins keep sending a password the school already rejected | android#163 |
| High | 小 | 3.3 | #255 | bug(Auth): a sign-in counts as successful without checking the password or the session | — |
| High | 小 | 3.4 | #256 | bug(Calendar): the school calendar is empty on phones set to the ROC calendar, and a failed fetch erases it | — |
| High | 小 | 4.4 | #265 | bug(App): opening the class table from a widget breaks the tab bar when Class Table is not pinned | — |
| High | 小 | 4.5 | #266 | bug(Moodle): Moodle links do nothing on iPhone and iPad without the Moodle app | — |
| High | 小 | 5.3 | #275 | bug(Widgets): widgets keep the previous account's timetable after sign-out, and the old accent after a change | — |
| High | 小 | 6.2 | #287 | bug(Mail): large downloads and uploads fail on slower connections because IMAP time limits never reset | — |
| High | 小 | 6.3 | #288 | bug(Mail): replying downloads the whole message to read Reply-To, and replies to From when that fails | — |
| High | 中 | 7.1 | #294 | bug(Logging): release builds have no Sentry DSN, so no error or crash report is ever sent | — |
| High | 小 | 7.2 | #295 | bug(Launch): resetting the iOS store leaves the real SQLite sidecars behind | — |
| High | 小 | 7.3 | #296 | ci(Tests): pull requests never build the macOS app | — |
| High | 小 | 7.4 | #297 | test(SSO): HTMLParser and the Moodle token decoding have no tests | — |
| High | 中 | 8.1 | #305 | feat(Watch): ship the next-class complication | — |
| High | 小 | 8.2 | #306 | feat(Notifications): let users turn class reminders off and choose the lead time | — |
| High | 小 | 九 | #209 | bug(Homework): 課堂助教不應該跳出作業與作業未完成通知 | backend#27、android#160 |
| Medium | 小 | 1.3 | #240 | perf(Sync): course and assignment lists are uploaded whole even when nothing changed | — |
| Medium | 中 | 1.4 | #241 | feat(Sync): read the change feed before deciding on a full sync | backend#26 |
| Medium | 小 | 1.5 | #242 | chore(Logging): record where a lapsed service session lands | — |
| Medium | 小 | 2.4 | #245 | bug(CloudSync): clearing an assignment mark is retried five times because its reply never decodes | — |
| Medium | 小 | 2.6 | #247 | bug(Sync): the two course upload paths disagree on course colours | — |
| Medium | 小 | 2.7 | backend#25 | bug(schedule): /schedule/sync keeps the old fire time and payload of a pending Live Activity start | — |
| Medium | 小 | 2.8 | #248 | bug(Sync): the first-sync mark upload brings cleared marks back from a stale device | android#155 |
| Medium | 小 | 2.9 | #249 | bug(Sync): the Assignments sync switch does not stop mark sync | backend#30 |
| Medium | 小 | 2.10 | #250 | perf(Sync): every full sync refetches the settings document and rewrites unchanged caches | — |
| Medium | 小 | 2.11 | #251 | bug(Sync): a sync trigger that arrives during a pull is dropped | — |
| Medium | 小 | 3.5 | #257 | perf(Moodle): every assignment round asks about every unconfirmed assignment at once | — |
| Medium | 小 | 3.6 | #258 | bug(Assignments): a retaken course pulls the old term's assignments into this term | — |
| Medium | 小 | 3.7 | #259 | bug(Security): the semester catalogue is fetched without TLS pinning | — |
| Medium | 中 | 3.8 | #260 | refactor(Moodle): add one webservice call helper before #212 and #162 | — |
| Medium | 小 | 4.1 | #262 | bug(Push): tapping a subscription bulletin notification does not open the bulletin | — |
| Medium | 小 | 4.3 | #264 | bug(LiveActivity): ignored and marked-done assignments still start the "due soon" Live Activity | android#156 |
| Medium | 小 | 4.6 | #267 | bug(ClassTable): a newly published term does not appear until the app relaunches | — |
| Medium | 小 | 4.7 | #268 | bug(Calendar): the device-calendar merge never runs because the usage description is missing | — |
| Medium | 小 | 4.8 | #269 | perf(UI): Class Table redraws every 5 seconds and the time slider every second | — |
| Medium | 中 | 4.9 | #270 | bug(a11y): assignments, the class table and shared controls have accessibility gaps | — |
| Medium | 中 | 5.1 | #273 | bug(App): silent pushes and Watch requests do nothing when iOS launches the app in the background | — |
| Medium | 小 | 5.2 | #274 | bug(Widgets): the next-class widgets ignore holidays when looking ahead | — |
| Medium | 中 | 5.4 | #276 | bug(LiveActivity): skipping a class leaves its running Live Activity on screen | — |
| Medium | 小 | 5.7 | #279 | perf(Widgets): every data change rewrites the widget snapshot and reloads all timelines | — |
| Medium | 小 | 5.8 | #280 | perf(Watch): every data change re-sends the library password and the schedule to the Watch | — |
| Medium | 中 | 5.9 | #281 | bug(Watch): the Watch shows classes on holidays and skipped days | android#158 |
| Medium | 中 | 5.10 | #282 | perf(Mac): the class table and calendar decode their cache files once per cell | — |
| Medium | 小 | 6.1 | #286 | bug(Mail): the open mail list misses new mail after returning to the app | — |
| Medium | 小 | 6.4 | #289 | feat(Mail): show attachment download progress, ignore repeat taps, prune opened files | — |
| Medium | 小 | 6.5 | #290 | perf(Mail): each mail check sends an unused STATUS and prefetches inline images | — |
| Medium | 小 | 7.5 | #298 | test(LiveActivity): scenario resolution has no tests | — |
| Medium | 小 | 7.6 | #299 | test: unit tests run the app's launch work, including real school syncs | — |
| Medium | 小 | 7.7 | #300 | perf(Launch): the main thread reads the Keychain about eight times before the first frame | — |
| Medium | 小 | 7.8 | #301 | chore(Migrations): delete the four migrations shipped before 1.7.1 | — |
| Medium | 中 | 7.10 | #303 | test(ClassTable): the conflict layout is implemented twice and neither copy is tested | — |
| Medium | 小 | 7.11 | #304 | test: three tests leak state or depend on the time zone | — |
| Medium | 小 | 8.3 | #307 | feat(Push): open the assignment when an assignment reminder is tapped | — |
| Medium | 中 | 8.4 | #308 | feat(Library): App Intents and a library QR control | — |
| Medium | 小 | 8.5 | #309 | feat(Home): stack overlapping courses in lanes on the time slider | — |
| Medium | 中 | 九 | #50 | feat(iPad): iPad Enhancement | — |
| Medium | 中 | 九 | #153 | feat(UI): 三堂課不同時衝堂課表顯示可優化 | — |
| Medium | 中 | 九 | #208 | feat(ClassTable): 課表頁面的額外功能與最佳化 | android#161 |
| Medium | 中 | 九 | #210 | feat(Homework): 允許手動針對課程忽略作業 | backend#28、android#162 |
| Medium | 中 | 九 | #211 | bug(Widget): 完整課表大小的 Widget，教室地點顯示錯誤 | — |
| Medium | 大 | 九 | #212 | feat(Moodle): 可在 app 內查看課堂成員、詳細資訊、公告、附件等額外資訊 | — |
| Medium | 中 | 九 | #233 | chore(deps): check the first Dependabot and Renovate pull requests after the next release | — |
| Low | 中 | 2.12 | #252 | bug(Sync): picking a course colour leaves another course with the same colour on the server | — |
| Low | 小 | 3.9 | #261 | perf(Parsing): checking for the SSO form parses the whole page on the main actor | — |
| Low | 小 | 4.10 | #271 | bug(Home): a course sheet opened under the Ignored filter shows no assignments | — |
| Low | 小 | 4.11 | #272 | perf(ClassTable): dragging the custom colour picker writes and syncs on every step | — |
| Low | 小 | 5.5 | #277 | bug(Widgets): the Lock Screen widget reloads in a loop when there is no snapshot | — |
| Low | 小 | 5.6 | #278 | bug(Widgets): the Today widget merges two blocks of the same course into one row | — |
| Low | 小 | 5.11 | #283 | bug(Mac): the Home Today and Next Class cards show classes on holidays | — |
| Low | 小 | 5.11 | #284 | bug(Mac): Refresh does not reload Bulletins | — |
| Low | 小 | 5.12 | #285 | refactor(LiveActivity): SharedSnapshotStore is written but never read | — |
| Low | 小 | 6.6 | #291 | bug(Mail): mail checks keep signing in while notification permission is denied | — |
| Low | 中 | 6.7 | #292 | bug(Mail): paging older mail never refreshes read or deleted state | android#159 |
| Low | 小 | 6.8 | #293 | bug(Mail): recipient rows use plain tap gestures inside the compose form | — |
| Low | 小 | 7.9 | #302 | chore: delete dead code and untrack two stray root files | — |
| Low | 中 | 8.6 | #310 | feat(Mac): a menu bar next class and more keyboard shortcuts | backend#31 |
| Low | 小 | 8.6 | #311 | feat(Calendar): open a Moodle deadline from the calendar | backend#31 |
| Low | 中 | 8.6 | #312 | feat(Score): a GPA what-if | backend#31 |
| Low | 大 | 8.6 | #313 | feat(More): an empty-classroom finder | backend#31 |
| Low | 大 | 8.6 | #314 | feat(InfoSystem): list the Information System portal links | backend#31 |
| Low | 大 | 8.6 | #315 | feat(Theme): Light and System appearance | backend#31 |
| Low | 中 | 8.6 | #316 | feat(Reminders): remind once about homework marked done but not submitted | backend#31 |
| Low | 小 | 8.6 | #317 | feat(Privacy): a switch for diagnostics reports | backend#31 |
| Low | 大 | 九 | #52 | feat(moodle3): 作業兼容臺師大 Moodle | — |
| Low | 小 | 九 | #135 | style(Calendar): macOS 行事曆顯示的圓形標記與外框沒有任何 Padding，可以再最佳化 | — |
| Low | 中 | 九 | #162 | feat(Moodle): 考慮自架 Moodle LMS 以自行模擬 edge case | — |
| Low | 中 | 九 | #167 | feat(Calendar): 可以加入自定義活動或是直接同步進原有行事曆 | — |
| Low | 小 | 九 | #168 | feat(Notifications): custom ring sound | backend#29 |
| Low | 小 | 九 | #213 | feat(Library): 圖書館系統新功能與最佳化 | — |
| Low | 小 | 九 | #236 | bug(Sync): courses_reset_at never parses, so a full reset made on another device is never detected | — |
| — | — | 九 | #230 | bug(Sync): choosing Use Local when re-enabling course sync brings deleted courses back | 已在 `dev` 修好，隨 release 關閉；android#153 |
