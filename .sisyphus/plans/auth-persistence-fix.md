# NTUST 認證持久化修復 — Issues #57 & #11

## TL;DR

> **Quick Summary**: 讓 TigerDuck iOS app 的登入狀態穩定不閃爍（#57），並以 Moodle Mobile App 的 webservice token 方式取代目前每小時重新 SSO 的 Moodle 資料抓取，避免 Moodle 伺服器重複寄送「新裝置登入」通知（#11）。
>
> **Deliverables**:
> - Settings 頁面登入狀態改綁 `hasStoredCredentials`（Keychain-backed stable source），對齊現有 cached-first 模式
> - 新的 `MoodleTokenService`：呼叫 `/login/token.php?service=moodle_mobile_app` 取得 webservice token，存 Keychain
>   - **Token 自動更新**：token 失效（`invalidtoken`/`accessexception`）時自動用 Keychain 既有 NTUST 帳密靜默換新 token，**不彈任何登入 UI**；對齊 Moodle Mobile 連續 3+ 月不需重新授權的行為
> - `MoodleService` 改寫為呼叫 `/webservice/rest/server.php` REST 端點；一次性 retry-on-invalid-token；刪除 HTML scrape + sesskey 舊流程
> - `AuthService.login/logout` 串接 Moodle token 生命週期；fresh-install / logout 時一併清除
> - **新資料夾 `swift/TigerDuck/Services/Migrations/`**：專門收納 breaking-change 相容層；本次建立 `MoodleTokenMigration.swift`（處理舊用戶升級後取得 Moodle token）；feature service 本體內**零 migration 程式碼**
> - Actor-serialized 併發保護；明確錯誤分類（`invalidtoken` / `invalidlogin` / 網路）
> - **Task 0 硬性閘門**：在任何實作前，先實地探測 NTUST Moodle 是否支援 `/login/token.php`，失敗就停並回報使用者
>
> **Estimated Effort**: Medium
> **Parallel Execution**: YES — 6 waves
> **Critical Path**: T0 (probe) → T1a/T1b/T1c/T1d/T1e (discovery parallel) → T3 (token service) → T5 (auth integration) → T6 (moodle rewrite) → T7 (consumers) → T9/T10 (verify) → F1–F4 (final review)

---

## Context

### Original Request

使用者在 dev branch 上要求修復兩個 bug：
1. **Issue #57** `bug(sync): 正在同步時，設定頁面中會顯示為未登入`
2. **Issue #11** `bug(notification): login with the same device, often receive moodle notification "New Login Record"` — 提供 Moodle 新裝置登入通知郵件範例並要求參考 Moodle Mobile App 的持久登入實作方法

### Interview Summary

**關鍵討論與決策**:
- **Issue #57 範圍**：只在設定頁面 — 但經 Metis 提醒，需先做 `isNTUSTLoggedIn` call-graph 審查確認其他頁面未被影響（已納入 Task 1b）
- **Issue #11 方向**：**只走 Moodle webservice token**（`/login/token.php?service=moodle_mobile_app`），不做 SSO scrape fallback；若 token 路線失敗由 Task 0 硬閘門提前攔截並回報使用者
- **Settings re-auth 視覺**：最簡模式 — 只正確顯示登入狀態即可，不加 spinner/文字
- **測試**：不寫單元或 UI 測試；僅 `xcodebuild build` 於 iPhone 17 Pro simulator 目標 compile-check；**不執行 simulator**
- **Commit 策略**：一計畫、多 commit（按功能模組）、一個 PR、**GPG 簽章**、格式 `feat|fix|refactor(scope): ...`、**不帶 `Co-Authored-By` 行**（來自 `~/.claude/CLAUDE.md`）

**Research Findings**:

**Moodle Mobile App 機制**（librarian 確認）：
- 認證端點：`POST /login/token.php` (params: `username`, `password`, `service=moodle_mobile_app`, optional `lang`)
- 成功回應：`{"token": "<32-hex>", "privatetoken": "<long>"}`；token 預設存活 3 個月
- API 呼叫：`GET /webservice/rest/server.php?wstoken=<T>&wsfunction=<F>&moodlewsrestformat=json`
- 為何不觸發通知：token-based stateless 呼叫不建立新 session，伺服器不會認為「新裝置」
- 潛在阻礙：若 `/login/token.php` 被 Shibboleth 保護（federated-only），會重導或回 `invalidlogin` → Task 0 負責偵測

**TigerDuck 現況**（explore agents 確認）：
- `AuthService` (`swift/TigerDuck/Services/Auth/AuthService.swift`) `isNTUSTAuthenticated` (18–21) = `cookiesValid && storedStudentId != nil`；`hasStoredCredentials` (28–31) 只看 Keychain
- `NTUSTSessionManager` (29–34) `cookiesValid` 靠 `Defaults[.ssoLoginTimestamp]` 對 3600s TTL；伺服器實際 cookie 可能已被刷新但 client 不自知
- `SettingsView.swift:281` 綁 `appState.isNTUSTLoggedIn`（cookie-based）→ 每小時 cookie TTL 到期時閃紅
- 其他保護畫面（`ClassTableView`, `HomeView` 等）走 `AppState.ntustProtectedAccessState(isEmpty:)` → `hasStoredCredentials` base — 不會閃（符合 AGENTS.md cached-first 準則）
- `MoodleService.fetchAssignments()` 走 `cookiesValid` 檢查 → 若無效就呼 `SSOLoginService.ensureServiceLogin(for: moodle_url)` → 完整 SSO re-flow → Moodle 新 session → 通知觸發
- `KMPServiceBridge.swift:19–24, 134–137` 已有 `loginGeneration` race guard（logout 時 bump），**此機制保留勿動**
- 現有測試只有 `TimeSliderViewModelTests.swift`；AuthService/MoodleService 無既有測試需要維持

### Metis Review

**Identified Gaps（已在本計畫處理）**:
- Gap: `/login/token.php` 可能被 Shibboleth 保護 → **Task 0 硬閘門**，失敗就停並回報
- Gap: 刪除 HTML scrape 前未盤點現有抓取資料 → **Task 1a** 盤點 MoodleService 網路呼叫 + HTML parse 位置
- Gap: `isNTUSTLoggedIn` 可能有其他消費者 → **Task 1b** 用 `lsp_find_references` 做 call-graph
- Gap: Widget/LiveActivity 可能讀 Moodle 資料（需共享 Keychain group）→ **Task 1c** audit
- Gap: 既有測試可能引用改動的符號 → **Task 1d** 檢查並決定修/刪/留
- Gap: GPG 簽章可能未設定 → **Task 1e** pre-flight
- Gap: 併發 `ensureAuthenticated()` 造成重複 token 換發 → **Task 3** 使用 Swift actor 或 cached Task
- Gap: 錯誤類型模糊 → **Task 3/4** 明確 enum 劃分 `invalidtoken` vs `invalidlogin` vs 網路錯誤
- Gap: 升級路徑（舊用戶有 cookie 但無 token）→ **Task 5** 加入 first-launch 沉默取 token 邏輯
- Gap: `AuthService.logout()` 未清 Moodle token → **Task 5** 加入
- Gap: Fresh-install purge 未涵蓋新 Keychain keys → **Task 4** 加入

---

## Work Objectives

### Core Objective

- 消除 TigerDuck iOS app 設定頁面登入狀態在背景 re-auth 期間的閃爍（Issue #57）
- 把 Moodle 資料抓取從「每小時 SSO re-flow → 新 session → 新裝置通知」改為「長效 webservice token stateless call」（Issue #11）

### Concrete Deliverables

- `swift/TigerDuck/Features/Settings/SettingsView.swift`: account row 改綁穩定來源 `hasStoredCredentials`
- `swift/TigerDuck/Services/Auth/MoodleTokenService.swift`（新建）：actor-based、公開方法 `obtainToken(studentId:password:)` / `refreshTokenIfNeeded()` / `clearToken()` / `currentToken()`
- `swift/TigerDuck/Services/Auth/MoodleWebserviceError.swift`（新建）：錯誤 enum + 解析
- `swift/TigerDuck/Services/Network/MoodleService.swift`: 全部呼叫改走 `/webservice/rest/server.php`；一次性 retry-on-invalidToken；刪除 sesskey 抓取與 HTML scrape
- `swift/TigerDuck/Services/Auth/AuthService.swift`: `login()` 成功後取 Moodle token；`logout()` 清 Moodle token（**不得含任何 migration 邏輯**）
- `swift/TigerDuck/Services/Migrations/`（新資料夾）：
  - `swift/TigerDuck/Services/Migrations/MoodleTokenMigration.swift`（新建）：舊用戶升級路徑（Keychain 有帳密但無 Moodle token）一次性靜默取 token
  - `swift/TigerDuck/Services/Migrations/AGENTS.md`（新建）：長期規範文件，說明此資料夾用途、命名、生命週期、刪除準則
- `swift/TigerDuck/App/AppState.swift`: fresh-install purge 加入 Moodle token keys；新增 `runPendingMigrations()` 觸發點呼叫 Migrations
- `swift/TigerDuck/App/AppConstants.swift`: 新增 `KeychainKeys.moodleToken`、`.moodlePrivateToken`、`moodleBaseURL`
- 探測紀錄：`.sisyphus/evidence/probe-result.json`（Task 0 產出）
- 盤點紀錄：`.sisyphus/evidence/moodle-inventory.md`、`.sisyphus/evidence/isNTUSTLoggedIn-callers.txt`、`.sisyphus/evidence/widget-moodle-audit.md`（Task 1 產出）

### Definition of Done

- [ ] `xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet` exit 0
- [ ] `xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuckLiveActivityExtension -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet` exit 0
- [ ] `rg -n 'appState\.isNTUSTLoggedIn' swift/TigerDuck/Features/Settings/` 回報 0 筆
- [ ] `rg -n 'sesskey|SwiftSoup|<tr|<td' swift/TigerDuck/Services/` 回報 0 筆（除非 Task 1a 明確紀錄為保留）
- [ ] `rg -n 'moodleToken|MoodleToken' swift/TigerDuck/App/AppState.swift` 回報 ≥1 筆（在 fresh-install purge 區塊）
- [ ] `git log origin/dev..HEAD --format='%B' | grep -c 'Co-Authored-By'` 回報 0
- [ ] 所有 commit 皆 GPG 簽章成功（`git log --show-signature` 顯示 Good signature）
- [ ] Task 0 probe 產出的 evidence JSON 顯示 `token` 成功欄位（若為其他失敗狀態，計畫在 Task 0 後由使用者決定是否繼續）

### Must Have

- Task 0 Moodle webservice 相容性探測，**任何實作前必須先跑**；探測失敗就停止工作並產生回報給使用者
- Settings 頁登入狀態來源改為 `hasStoredCredentials` 對齊其他畫面 cached-first 模式
- `MoodleTokenService` 使用 Swift `actor` 序列化 token 取得
- Moodle token 存 `KeychainManager` 使用既有 API（和 studentId/password 相同機制）
- `AuthService.login()` 成功後呼叫 `MoodleTokenService.obtainToken()`；失敗不應阻擋 NTUST SSO 成功狀態（僅 log + 留待後續重試）
- `AuthService.logout()` 必須一併刪除 Moodle token
- `AppState` fresh-install 清除邏輯包含 `moodleToken` 與 `moodlePrivateToken`
- `MoodleService` 所有對 Moodle 的網路呼叫改為 `/webservice/rest/server.php?wstoken=...`
- 錯誤分類 enum 涵蓋至少四種狀況：`invalidToken` / `invalidCredentials` / `accessException` / `transientNetwork`
- **Moodle token 自動更新（無感刷新，對齊 Moodle Mobile App）**：
  - `MoodleTokenService` 必須提供 `refreshTokenIfNeeded()` 公開方法：讀取 Keychain 既有 NTUST 帳密，重新呼叫 `/login/token.php` 換新 token；不彈出任何 UI、不要求使用者再次輸入密碼
  - `MoodleService` 在收到 `invalidtoken` / `accessexception` 時必須執行「**一次性**」自動 retry：呼叫 `refreshTokenIfNeeded()` 成功後用新 token 重打同一 API call
  - 一次性重試後仍失敗 → 才依錯誤類型決定：`invalidlogin`（密碼已變更）→ 丟錯給 UI 層由現有 `presentNTUSTLogin()` 流程處理；其他錯誤走 `transientNetwork` log 後由使用者下次互動再重試
  - refresh 流程必須同樣在 actor 序列化保護下進行（禁止併發 refresh）；`refreshTokenIfNeeded()` 若已有 in-flight refresh task 應共享之，避免同一秒觸發多個 token 換發
- **Migration / 相容層隔離（專案長期準則）**：
  - 建立 `swift/TigerDuck/Services/Migrations/` 資料夾作為**所有** breaking-change 相容層的歸宿（本次起、未來沿用）
  - 每個 migration 用獨立 `.swift` 檔（本次 `MoodleTokenMigration.swift`）
  - 每個 migration 必須自包含：含自己的 idempotency flag、自己的 run 方法、自己的失敗處理；不依賴其他 migration
  - Migration 呼叫點由 `AppState` 統一管理（例如 `runPendingMigrations()` 於 init 尾端觸發 detached Task），不得嵌入 `AuthService` / `MoodleService` / `MoodleTokenService` 等 feature service
  - 資料夾內放 `AGENTS.md` 文檔說明本資料夾契約（長期準則 — 後續新增 migration 時 agent 參考）
- 所有 commit 使用 GPG 簽章，格式 `type(scope): description`，**絕對不包含 `Co-Authored-By:` 行**
- 每個 commit 前 `xcodebuild build`（app + widget）必須 compile pass

### Must NOT Have (Guardrails)

- **禁止**跑 simulator（不呼叫 `xcodebuild test`、不呼叫 `xcrun simctl boot`）；compile-only (`xcodebuild build`) 即可
- **禁止**寫新的單元測試或 UI 測試（user 明確拒絕）
- **禁止**刪除既有 `TigerDuckTests/TimeSliderViewModelTests.swift`
- **禁止**修改 `backend/api/` 任何 Python 檔案（backend out of scope）
- **禁止**任何後端 / 外部服務變更建議（cookie refresh server、proxy 等）
- **禁止**在 `MoodleTokenService` 引入多餘抽象（禁止 `MoodleTokenProviding` protocol、禁止 `TokenRefreshCoordinator`、禁止 generic `WebserviceClient<T>` — Metis 指名 AI-slop 風險）
- **禁止**改寫 `AuthService` 超出加入 `obtainMoodleToken` 呼叫 + `clearToken` 呼叫以外範圍
- **禁止**在 `AuthService` / `MoodleService` / `MoodleTokenService` / 任何 feature service 檔案中嵌入 **migration 邏輯**（舊用戶升級路徑）— 必須在 `swift/TigerDuck/Services/Migrations/` 專屬檔案
- **禁止**在 `AuthService.ensureAuthenticated()` 加入「如果 Moodle token 缺就取一次」這類 migration-ish 分支 — 該路徑屬 `MoodleTokenMigration.swift` 職責
- **禁止**動 `LiveActivityCoordinator` / Live Activity subsystem，除非 Task 1c 明確發現 Moodle 耦合
- **禁止**動 `KMPServiceBridge` 的 `loginGeneration` race guard（既有機制需保留）
- **禁止**在 Moodle token 換發加入重試迴圈、exponential backoff、telemetry（Metis 指名非需求；唯一允許的重試是 MoodleService 層的「一次性 retry-on-invalidToken」）
- **禁止**改用 `UserDefaults` 存 token（必須 Keychain）
- **禁止** Task 0 probe 失敗仍繼續後續實作任務 — 硬閘門
- **禁止**修改 `AppState.ntustProtectedAccessState(isEmpty:)` 的語意（維持 cached-first 契約）
- **禁止** commit 含 `as!`、`as? X as!`、`try!`、`fatalError()` 在新增檔案中（Swift 風格 guardrail）
- **禁止**把 token 或 privatetoken 放入 log 文字（安全風險）
- **禁止**新增 `@Published` / `@Observable` 屬性在 `MoodleTokenService`（actor 內部狀態，不直接供 UI binding）
- **禁止** Migrations/ 資料夾內的檔案互相 import（每個 migration 獨立自包含）
- **禁止**在 Migrations/ 資料夾放任何「新功能」程式碼（只放相容層，避免隨時間膨脹為無主之地）

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** — 所有驗證由 agent 工具或 shell 命令完成。**絕對不跑 simulator**。

### Test Decision
- **Infrastructure exists**: YES（Swift Testing + XCTest 都已配置）
- **Automated tests**: NO（user 明確拒絕）
- **Framework**: n/a
- **If TDD**: n/a

### QA Policy

每個實作任務的 QA 皆為「靜態 / compile-time 驗證」，組合下列工具：

- **Compile check**：`xcodebuild build -project swift/TigerDuck.xcodeproj -scheme <TigerDuck|TigerDuckLiveActivityExtension> -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet` — exit 0
- **Symbol presence / absence**：`rg -n <pattern> <path>`（expected 行數精確）
- **AST-level pattern**：`ast-grep --lang swift --pattern '<P>' <path>` — 預期匹配數
- **LSP diagnostics**：`lsp_diagnostics(filePath=<path>, severity="error")` — 0 error
- **LSP references**：`lsp_find_references(...)` 用於確認某符號已移除 / 新增的呼叫位置
- **GPG 簽章驗證**：`git log --show-signature origin/dev..HEAD` grep `Good signature`
- **Commit message 格式驗證**：`git log --format='%s' origin/dev..HEAD | grep -vE '^(feat|fix|refactor|chore)\([A-Za-z]+\): '` 預期空輸出
- **No Co-Authored-By**：`git log --format='%B' origin/dev..HEAD | grep -c 'Co-Authored-By'` 預期 0

- **Frontend/UI**: 不使用 Playwright（user 禁止 simulator）；改用靜態 view 檔案內容檢查
- **TUI/CLI**: 僅 Bash 一次性命令 — 不使用 tmux
- **API/Backend**: 使用 `curl` 做 Task 0 一次性 probe（evidence 存檔）；實際 app 內 API 呼叫**不透過 curl 測試**，以 compile + code review 代替
- **Library/Module**: compile + AST 檢查

Evidence 路徑：`.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 0 (Gate — 單任務硬閘門):
└── T0: Moodle webservice 相容性探測 [quick, oracle 協助判讀]

Wave 1 (Discovery, 5 並行 — 全部結束後才進 Wave 2):
├── T1a: MoodleService 現況盤點 + HTML scrape 清單 [explore 代理]
├── T1b: AppState.isNTUSTLoggedIn call-graph [explore 代理]
├── T1c: Widget / LiveActivity Moodle 耦合審查 [explore 代理]
├── T1d: 既有測試掃描（受影響檔案）[quick]
└── T1e: GPG 簽章與 commit 格式 pre-flight [quick]

Wave 2 (Foundation, 3 並行):
├── T2:  Settings flicker 修復 #57 (依賴 T1b) [quick]
├── T3:  MoodleTokenService + 錯誤 enum + actor 併發保護 (依賴 T0) [deep]
└── T4:  AppConstants Keychain keys + AppState fresh-install purge (依賴 T3) [quick]

Wave 3 (Integration, 3 並行):
├── T5:  AuthService.login/logout 串接（純 feature 本體，無 migration 邏輯）(依賴 T3, T4) [deep]
├── T5b: Migrations/ 資料夾 + MoodleTokenMigration.swift + AppState 觸發點 (依賴 T3, T4) [deep]
└── T6:  MoodleService 改寫為 REST webservice 呼叫 (依賴 T1a, T3, T4) [deep]

Wave 4 (Consumers, 2 並行):
├── T7:  CalendarViewModel / KMPServiceBridge 串接新 MoodleService API (依賴 T6) [unspecified-high]
└── T8:  Logout cascade 與 DataCache 互動檢查 (依賴 T5) [quick]

> 每個實作 task 本身 AC 已含「xcodebuild compile pass」+ 靜態 grep/ast-grep 驗證。
> 獨立的「compile matrix」與「ast-grep sweep」已被 F2/F3 reviewer 覆蓋，不另立 task 避免重工。

Wave FINAL (4 並行 review，全部 APPROVE 後等使用者 okay):
├── F1: 計畫合規 audit (oracle)
├── F2: Swift code 品質（含 AI slop 檢查、compile matrix [app + widget]）(unspecified-high)
├── F3: 靜態 QA：跑每個 task 的 evidence 命令 + 全域 ast-grep sweep (unspecified-high)
└── F4: 範圍忠實度（對照 diff 與計畫）(deep)
→ 呈現結果 → 等使用者明確 okay

Critical Path: T0 → T1a → T3 → T5 → T6 → T7 → F1–F4 → user okay
Parallel Speedup: ~55% vs 純順序（Waves 1/2/3/4 皆多工）
Max Concurrent: 5 (Wave 1)
```

### Dependency Matrix

| Task | Depends On | Blocks | Wave |
|------|-----------|--------|------|
| T0 | — | T3, T5, T6, T7 | 0 |
| T1a | — | T6 | 1 |
| T1b | — | T2 | 1 |
| T1c | — | T4 (有條件)、T9 | 1 |
| T1d | — | T5, T6, T9 | 1 |
| T1e | — | Commit checkpoints | 1 |
| T2 | T1b | T9 | 2 |
| T3 | T0 | T4, T5, T6 | 2 |
| T4 | T3 | T5, T6 | 2 |
| T5 | T3, T4, T1d | T8, F1–F4 | 3 |
| T5b | T3, T4 | F1–F4 | 3 |
| T6 | T1a, T3, T4, T1d | T7, F1–F4 | 3 |
| T7 | T6 | F1–F4 | 4 |
| T8 | T5 | F1–F4 | 4 |
| F1 | T2, T5, T5b, T6, T7, T8 | user okay | Final |
| F2 | T2, T5, T5b, T6, T7, T8 | user okay | Final |
| F3 | T2, T5, T5b, T6, T7, T8 | user okay | Final |
| F4 | T2, T5, T5b, T6, T7, T8 | user okay | Final |

### Agent Dispatch Summary

| Wave | Tasks | Dispatch |
|------|------|----------|
| 0 | 1 | T0 → `quick` + 可洽詢 `oracle` 判讀 ambiguous response |
| 1 | 5 | T1a → `explore` / T1b → `explore` / T1c → `explore` / T1d → `quick` / T1e → `quick` |
| 2 | 3 | T2 → `quick` / T3 → `deep` / T4 → `quick` |
| 3 | 3 | T5 → `deep` / T5b → `deep` / T6 → `deep` |
| 4 | 2 | T7 → `unspecified-high` / T8 → `quick` |
| FINAL | 4 | F1 → `oracle` / F2 → `unspecified-high` / F3 → `unspecified-high` / F4 → `deep` |

---

## TODOs

> 每個任務都必備：Recommended Agent Profile + Parallelization + QA Scenarios。
> **沒有 QA Scenarios 的任務視為 INCOMPLETE，會被 Final Verification Wave 拒絕。**

- [x] 0. **Moodle Webservice 相容性探測（硬閘門）**

  **What to do**:
  - 不改 code。執行一次 shell 探測：用 NTUST 學生帳密 POST 到 `https://moodle2.ntust.edu.tw/login/token.php`，觀察回應格式
  - 同時 `curl -I` 確認 `https://moodle2.ntust.edu.tw/webservice/rest/server.php` 可達（通常回 HTTP 500 或 303 redirect — **這是正常的，表示伺服器存在**）
  - 把探測結果存到 `.sisyphus/evidence/probe-result.json`
  - 判讀結果（四種可能）：
    - **PASS**: HTTP 200 且 JSON 含 `token` 欄位（長度 ≥ 20 chars）→ 允許進入 Wave 1
    - **FAIL-CREDENTIAL**: HTTP 200 且 JSON 含 `errorcode: "invalidlogin"` → 代表端點存在、但提供的帳密錯；可由使用者重跑
    - **FAIL-FEDERATED**: HTTP 3xx 到 `ssoam2.ntust.edu.tw` 或 HTTP 200 但內容是登入頁 HTML → 端點被 Shibboleth 保護，**token-only 不可行**
    - **FAIL-DISABLED**: JSON 含 `errorcode: "enablewsdescription"` / `"servicenotloaded"` → 網站管理員沒啟用 web service
  - 若結果非 PASS（且非 FAIL-CREDENTIAL — 該狀況使用者可修正），**整個計畫停在此任務**，把探測 JSON 連同摘要呈給使用者決定是否改走「強化 SSO」路線

  **Must NOT do**:
  - 不得修改任何 source code
  - 不得自動切換到 SSO 強化路線（使用者保留決策權）
  - 不得把 NTUST 帳密 log 出或寫入非 `.sisyphus/evidence/` 的路徑
  - 探測命令帶憑證時**務必走環境變數**（`$NTUST_USER`、`$NTUST_PASS`），不得 hardcode 或寫入 git

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 單次 shell 探測 + JSON 解析即可，無需架構深度；若回應 ambiguous 可升級洽詢 `oracle`
  - **Skills**: 無
    - 不需額外 skill
  - **Skills Evaluated but Omitted**:
    - `explore`: 不是找 code — 不適用
    - `librarian`: 已在 Prometheus 階段完成 — 不需重跑

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 0 — 單任務硬閘門
  - **Blocks**: T3, T5, T6, T7（任何實作 Moodle token 路線的任務）
  - **Blocked By**: None — 第一個執行

  **References**:

  **External References**:
  - Moodle 官方 token 端點文件（librarian 已彙整）：Moodle Mobile 使用 `POST /login/token.php` with `service=moodle_mobile_app`
  - 預期成功回應 shape：`{"token": "<32 hex>", "privatetoken": "<long>"}`
  - 預期錯誤回應 shape：`{"error": "<text>", "errorcode": "<code>"}`；常見 `errorcode`: `invalidlogin`, `enablewsdescription`, `servicenotloaded`

  **Pattern References**:
  - `.sisyphus/evidence/` 既有習慣（plan 骨架 Verification Strategy 區塊已定義檔案命名）

  **WHY Each Reference Matters**:
  - Moodle 官方回應結構是判讀 PASS/FAIL 的依據 — 不能靠「請求成功 == 可用」
  - evidence 路徑約定讓後續 F3 reviewer 知道去哪找證物

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: 相容性探測成功（PASS 路徑）
    Tool: Bash (curl + jq)
    Preconditions:
      - 使用者在 shell 環境變數注入真實 NTUST 帳密：export NTUST_USER="..." NTUST_PASS="..."
      - jq 已安裝（brew install jq 若無）
    Steps:
      1. 執行：
         curl -sS -X POST "https://moodle2.ntust.edu.tw/login/token.php" \
           --data-urlencode "username=$NTUST_USER" \
           --data-urlencode "password=$NTUST_PASS" \
           --data-urlencode "service=moodle_mobile_app" \
           -o .sisyphus/evidence/probe-result.json \
           -w "HTTP:%{http_code}\nREDIRECT:%{redirect_url}\n"
      2. 檢查 exit code 為 0
      3. 解析 JSON：jq -r '.token // empty' .sisyphus/evidence/probe-result.json
    Expected Result:
      - curl exit 0
      - 輸出含 `HTTP:200` 行
      - `jq -r '.token'` 輸出長度 ≥ 20 的十六進位字串
      - `jq -r '.errorcode // empty'` 輸出空
    Failure Indicators:
      - HTTP 非 200 / redirect_url 非空 → FAIL-FEDERATED
      - token 欄位缺失 + errorcode=invalidlogin → FAIL-CREDENTIAL（使用者可修正帳密重跑）
      - errorcode=enablewsdescription 或 servicenotloaded → FAIL-DISABLED
    Evidence: .sisyphus/evidence/probe-result.json + 命令輸出摘要存 .sisyphus/evidence/probe-summary.txt

  Scenario: 相容性探測失敗（FAIL-FEDERATED — 端點被 Shibboleth 保護）
    Tool: Bash (curl)
    Preconditions: 探測命令執行後得到 HTTP 3xx 或 HTML 回應
    Steps:
      1. 檢查 probe-result.json 開頭是否為 `{` — 若是 `<` 代表得到 HTML（登入頁）
      2. 檢查 curl 輸出 REDIRECT 欄位是否指向 ssoam2.ntust.edu.tw
    Expected Result: probe 被正確分類為 FAIL-FEDERATED；**整個計畫 halt**；把 JSON/HTML 片段附給使用者
    Evidence: .sisyphus/evidence/probe-result.{json|html} + 診斷摘要
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/probe-result.json`（或 .html 若是 FAIL-FEDERATED）
  - [ ] `.sisyphus/evidence/probe-summary.txt` 含 PASS/FAIL 分類與 HTTP 狀態

  **Commit**: NO（discovery 任務不產 commit）

- [x] 1a. **MoodleService 現況盤點（決定 Task 6 刪除範圍）**

  **What to do**:
  - 讀 `swift/TigerDuck/Services/Network/MoodleService.swift` 全檔
  - 用 `rg -n 'URLRequest|URLSession|session\.data|dataTask'` 掃 `swift/TigerDuck/Services/` 列出所有網路呼叫點
  - 用 `rg -n 'sesskey|SwiftSoup|<html|<table|<tr|<td'` 掃 `swift/TigerDuck/` 列出所有 HTML 解析/抓取位置
  - 讀 `swift/TigerDuck/Services/Network/SSOLoginService.swift` 找 Moodle 相關分支（特別是 `ensureServiceLogin(for: moodle_url)` 相關程式碼）
  - 建表：每個網路呼叫一列，欄位為 `{呼叫點 file:line, 目標 URL pattern, 回傳的資料型別, 被哪些 consumer 使用}`
  - 把表格寫到 `.sisyphus/evidence/moodle-inventory.md`
  - 同時列出**每個條目在 Moodle 2.9+ webservice 是否有等價 function**（根據 librarian 彙整與 Moodle 官方 function list）：
    - 作業清單 → `mod_assign_get_assignments` / `core_calendar_get_action_events_by_timesort`
    - 課程清單 → `core_enrol_get_users_courses` / `core_course_get_courses`
    - 公告 → `mod_forum_get_forum_discussions_paginated`（若有啟用）
    - 若任何條目找不到 webservice 等價，**明確在表格標記「需保留 scrape」**並交由 Task 6 特別處理

  **Must NOT do**:
  - 不得修改 source code
  - 不得猜測 webservice function 名稱 — 需引用 librarian 彙整或 Moodle 官方文件
  - 不得遺漏 SSOLoginService 中為 Moodle 存在的分支（那也是需要考量刪除的）

  **Recommended Agent Profile**:
  - **Category**: `explore`
    - Reason: 典型 codebase 盤點任務；explore agent 擅長讀多檔做對照表
  - **Skills**: 無
  - **Skills Evaluated but Omitted**:
    - `librarian`: Prometheus 階段已經取得 Moodle webservice 文件 — 可以在 prompt 裡直接引用

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (與 T1b, T1c, T1d, T1e 同時)
  - **Blocks**: T6（刪除 / 改寫範圍需要這份盤點）
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `swift/TigerDuck/Services/Network/MoodleService.swift` — 所有當前 Moodle 網路呼叫的起點
  - `swift/TigerDuck/Services/Network/SSOLoginService.swift:51-54` — Moodle cookie 選擇性保留邏輯（需盤點是否仍需要）
  - `swift/TigerDuck/Services/Network/NTUSTSessionManager.swift` — 目前 Moodle 呼叫透過這個 shared session

  **API/Type References**:
  - `swift/TigerDuck/Bridge/KMPServiceBridge.swift:19-24, 134-137` — MoodleService 的 primary consumer，回傳型別會影響 Task 7
  - `swift/TigerDuck/Features/Calendar/CalendarViewModel.swift:76-104` — Moodle events 消費點

  **External References**:
  - Moodle webservice function 清單（官方）：https://docs.moodle.org/dev/Web_service_API_functions（librarian 已引用）

  **WHY Each Reference Matters**:
  - SSOLoginService 中的 Moodle 分支是「隱性耦合」— 盤點必須涵蓋，否則 T6 會只刪表面
  - KMPServiceBridge 與 CalendarViewModel 定義了 consumer 合約，webservice function 的回傳結構必須能對映

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: MoodleService 網路呼叫完整枚舉
    Tool: Bash (rg)
    Preconditions: repo 在 HEAD
    Steps:
      1. rg -n 'URLRequest|URLSession\.shared\.data|session\.data' swift/TigerDuck/Services/ > /tmp/moodle-calls.txt
      2. rg -n 'moodle\.ntust\.edu\.tw|/mod/|/calendar/|/course/|sesskey' swift/TigerDuck/Services/ >> /tmp/moodle-calls.txt
      3. wc -l /tmp/moodle-calls.txt
      4. 確認 Task 1a 產出的 .sisyphus/evidence/moodle-inventory.md 含表格 header: file, line, url_pattern, return_type, consumers, webservice_replacement
      5. 檢查表格行數 ≥ /tmp/moodle-calls.txt 中明顯 Moodle 相關行數
    Expected Result:
      - .sisyphus/evidence/moodle-inventory.md 存在
      - 每個 sesskey 出現點、每個 moodle URL 呼叫點都在表中
      - 每列的 webservice_replacement 欄位非空（即便值是 "N/A - needs scrape fallback"）
    Failure Indicators:
      - 表格為空或行數遠少於實際呼叫點
      - 有 URL 呼叫點未分類 webservice_replacement
    Evidence: .sisyphus/evidence/moodle-inventory.md + /tmp/moodle-calls.txt copy 到 .sisyphus/evidence/moodle-calls-raw.txt

  Scenario: SSOLoginService 中 Moodle 分支被識別
    Tool: Bash (rg)
    Steps:
      1. rg -n 'moodle|Moodle' swift/TigerDuck/Services/Network/SSOLoginService.swift
      2. 確認 inventory 表格裡專門列出 SSOLoginService.swift 的 Moodle 相關條目（或明確寫「無 Moodle 耦合」）
    Expected Result: SSOLoginService 的 Moodle 觸及面有明確記錄
    Evidence: 併入 moodle-inventory.md「SSOLoginService Moodle footprint」章節
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/moodle-inventory.md`
  - [ ] `.sisyphus/evidence/moodle-calls-raw.txt`

  **Commit**: NO

- [x] 1b. **`AppState.isNTUSTLoggedIn` call-graph（驗證 #57 範圍）**

  **What to do**:
  - 用 LSP：`lsp_find_references(filePath="swift/TigerDuck/App/AppState.swift", line=<isNTUSTLoggedIn 行號>, character=<其位置>, includeDeclaration=false)` 取得所有消費者
  - 同步用 `rg -n 'appState\.isNTUSTLoggedIn|self\.isNTUSTLoggedIn' swift/TigerDuck/` 做交叉驗證
  - 同時用 LSP 查 `AuthService.isNTUSTAuthenticated` 的參照（因為 `AppState.isNTUSTLoggedIn` 只是 pass-through）
  - 建清單 `.sisyphus/evidence/isNTUSTLoggedIn-callers.txt`：每列 `file:line | context_snippet | decision`
  - `decision` 值為其中之一：
    - `KEEP`（不是 UI 判斷用途，例如 log / telemetry）
    - `MIGRATE_TO_hasStoredCredentials`（應該改綁 cached-first）
    - `MIGRATE_TO_ntustProtectedAccessState`（屬於保護畫面 gate）
    - `OUT_OF_SCOPE`（Task 2 僅處理 Settings，其他列入未來工作）
  - **本 task 不做任何 code 改動**；只產出清單供 T2 決策
  - 使用者原本說「只在設定頁面」；若發現其他 UI 也有類似風險，附在報告裡**但不自動 migrate**（尊重 user scope）

  **Must NOT do**:
  - 不得修改 source code
  - 不得自動擴大 #57 的修改範圍（user 明確說範圍限 Settings；超出只做 flag 不做 fix）

  **Recommended Agent Profile**:
  - **Category**: `explore`
    - Reason: LSP 參考查詢 + codebase 掃描屬於 explore 典型能力
  - **Skills**: 無

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: T2（T2 需要知道 Settings 以外是否還有需要一併處理的 binding）
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `swift/TigerDuck/App/AppState.swift:84` — `var isNTUSTLoggedIn: Bool { authService.isNTUSTAuthenticated }`
  - `swift/TigerDuck/Services/Auth/AuthService.swift:18-21` — `isNTUSTAuthenticated` computed 的真實定義
  - `swift/TigerDuck/Features/Settings/SettingsView.swift:281` — 已知消費者（T2 將處理）

  **API/Type References**:
  - `swift/TigerDuck/App/AppState.swift:95-98` — 正確的 cached-first gate `ntustProtectedAccessState(isEmpty:)`

  **External References**:
  - `/Users/xinshou/IdeaProjects/TigerDuck/AGENTS.md` — cached-first 準則：「Do not gate protected NTUST screens directly on cookie validity」

  **WHY Each Reference Matters**:
  - LSP 參考查詢比 rg 更可靠（會處理 extension / typealias）— 但 rg 做交叉驗證防漏
  - AGENTS.md 的 cached-first 準則是「為什麼要 migrate」的理據

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: call-graph 完整且標記清楚
    Tool: Bash (rg) + LSP (lsp_find_references)
    Steps:
      1. rg -n 'appState\.isNTUSTLoggedIn|self\.isNTUSTLoggedIn|\.isNTUSTLoggedIn' swift/TigerDuck/ | tee /tmp/callers-rg.txt
      2. 檢查 .sisyphus/evidence/isNTUSTLoggedIn-callers.txt 存在
      3. 行數 ≥ wc -l < /tmp/callers-rg.txt
      4. 每列符合格式 `<file>:<line> | <snippet> | <decision>`
      5. 檢查是否有列標記 MIGRATE_TO_*（Task 2 會用到）
    Expected Result:
      - SettingsView.swift 的對應列標記為 MIGRATE_TO_hasStoredCredentials 或 MIGRATE_TO_ntustProtectedAccessState
      - 其他消費者（若有）標記 OUT_OF_SCOPE 並附註「user scope 限 Settings；此處留待未來」
    Failure Indicators: 有 rg 找到的行未出現在 callers 清單中
    Evidence: .sisyphus/evidence/isNTUSTLoggedIn-callers.txt + /tmp/callers-rg.txt → .sisyphus/evidence/callers-rg.txt

  Scenario: 無假陽性（call-graph 條目確實為 isNTUSTLoggedIn 綁定）
    Tool: Bash (rg with -C context)
    Steps:
      1. rg -n -C 2 'isNTUSTLoggedIn' swift/TigerDuck/ > /tmp/callers-context.txt
      2. 人工/自動檢查每列 context（例如不是字串字面值、不是 comment）
    Expected Result: 清單每列都在實際 Swift 表達式中
    Evidence: .sisyphus/evidence/callers-rg-context.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/isNTUSTLoggedIn-callers.txt`
  - [ ] `.sisyphus/evidence/callers-rg.txt`
  - [ ] `.sisyphus/evidence/callers-rg-context.txt`

  **Commit**: NO

- [x] 1c. **Widget / LiveActivity Moodle 耦合審查**

  **What to do**:
  - `rg -n 'Moodle|moodleToken|moodle\.|MoodleService|MoodleTokenService' swift/TigerDuckLiveActivity/ swift/TigerDuck/LiveActivity/`
  - `rg -n 'KeychainKeys\.studentId|KeychainKeys\.password|AppConstants\.KeychainKeys' swift/TigerDuckLiveActivity/`
  - 找出 `swift/TigerDuckLiveActivity/` 目錄下所有 .swift 檔，讀一遍
  - 查 widget target 的 entitlements / Info.plist 檔案（若有）確認 Keychain access group 配置
  - 建 `.sisyphus/evidence/widget-moodle-audit.md`：
    - 若 widget **無** Moodle 資料存取 → 結論「moodleToken 僅需 app-only Keychain；T4 無需新增 access group 條目」
    - 若 widget **有** Moodle 資料存取 → 結論「moodleToken 需 shared access group；T4 必須比照 studentId/password 加入 SecureStore 的 shared group 條目」
  - **本任務不改 code**，只產結論

  **Must NOT do**:
  - 不得修改 source code
  - 不得修改 entitlements

  **Recommended Agent Profile**:
  - **Category**: `explore`
    - Reason: 檢視特定 target 的 source + 配置檔

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: T4（決定 Keychain key 是否需要 shared access group）、T9（widget compile 門檻）
  - **Blocked By**: None

  **References**:
  - `swift/TigerDuckLiveActivity/` 整個目錄
  - `swift/TigerDuck/Services/Auth/SecureStore.swift` — 現有 Valet shared group 的配置方式
  - `swift/TigerDuck/Services/Auth/KeychainManager.swift` — 判斷 studentId/password 是否已經是 shared group
  - AGENTS.md 提到「KeychainManager has shared group access for widget extension」— 需比對現況

  **WHY Each Reference Matters**:
  - 若 widget 不需 Moodle token，就不要為它新增 shared group entry（減少攻擊面）
  - 若 widget 需要，T4 就**必須**比照做，否則 widget runtime 會找不到 token

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: 無 Moodle 耦合（最簡可能）
    Tool: Bash (rg) + Read
    Steps:
      1. rg -c 'Moodle' swift/TigerDuckLiveActivity/ swift/TigerDuck/LiveActivity/
      2. 若總數 0 → 結論 NO_COUPLING，記入 audit md
    Expected Result: audit md 明確寫 "NO_COUPLING"；T4 可用 app-only key
    Evidence: .sisyphus/evidence/widget-moodle-audit.md

  Scenario: 有 Moodle 耦合（需要 shared group）
    Tool: Bash (rg)
    Steps:
      1. 若 rg 找到 ≥1 筆 → 逐筆列出位置並判斷是否真的需要讀 Moodle 資料（還是只是 token 字串面上出現）
      2. 讀 widget Info.plist / entitlements 檔確認現有 access group
      3. audit md 標示 "HAS_COUPLING"，列出檔案與需要的 group 名
    Expected Result: T4 收到明確指令需要擴充 SecureStore 設定
    Evidence: .sisyphus/evidence/widget-moodle-audit.md + 相關檔案引用
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/widget-moodle-audit.md`

  **Commit**: NO

- [x] 1d. **既有測試掃描（受影響檔案）+ 其他 NTUST 相關 UI binding 查核**

  **What to do**:
  - `rg -n 'AuthService|MoodleService|NTUSTSessionManager|isNTUSTLoggedIn|isNTUSTAuthenticated' swift/TigerDuckTests/ swift/TigerDuckUITests/`
  - 若有任何測試引用上列符號：列出 file:line，評估 Task 5/6 改動後是否會 compile fail；若會 fail，在報告中標註「需要同步更新測試檔」
  - 用 `xcodebuild -list -project swift/TigerDuck.xcodeproj` 列出所有 scheme 確認 test scheme 名稱
  - 建 `.sisyphus/evidence/test-impact.md`，標示每個受影響測試檔與處置方式（update / 暫時 skip / 留著但 TODO 註記）
  - 本 task **不改動測試檔**（user 禁止寫新測試；但既有測試若被打壞必須修，此處僅報告）

  **Must NOT do**:
  - 不得修改任何測試檔
  - 不得刪除既有測試（尤其 `TimeSliderViewModelTests.swift` 嚴禁動）

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 單純 rg 掃描 + 列表，不需 explore 深度

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: T5, T6, T9（實作若不看這份報告會撞壞測試 compile）
  - **Blocked By**: None

  **References**:
  - `swift/TigerDuckTests/TigerDuckTests.swift`
  - `swift/TigerDuckTests/TimeSliderViewModelTests.swift`
  - `swift/TigerDuckUITests/`
  - Explore 報告已確認：AuthService / MoodleService / AppState 目前無任何測試；此 task 用來**最終確認**沒有遺漏

  **WHY Each Reference Matters**:
  - Explore 報告是最佳推估但非權威；此 task 用 rg 做最終確認，避免改碼後 test target compile 壞

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: 既有測試無引用受影響符號（預期狀況）
    Tool: Bash (rg)
    Steps:
      1. rg -c 'AuthService|MoodleService|NTUSTSessionManager' swift/TigerDuckTests/ swift/TigerDuckUITests/
      2. 總數應為 0
      3. .sisyphus/evidence/test-impact.md 載明 "NO_TESTS_AFFECTED"
    Expected Result: 實作任務無需擔心測試 compile
    Evidence: .sisyphus/evidence/test-impact.md

  Scenario: 既有測試有引用（需處置）
    Tool: Bash (rg)
    Steps:
      1. 列出每筆 file:line
      2. 針對每筆決定處置：
         - 若只是 import 聲明：改動後仍應 compile pass → 標 OK
         - 若 mock / stub 對應的符號 signature：必須同步更新 → 標 NEED_UPDATE
    Expected Result: test-impact.md 明確標示每項處置；任一 NEED_UPDATE 會被 T5/T6 執行時處理
    Evidence: .sisyphus/evidence/test-impact.md
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/test-impact.md`

  **Commit**: NO

- [x] 1e. **GPG 簽章 + commit 格式 pre-flight**

  **What to do**:
  - 執行以下檢查命令：
    - `git config --get user.signingkey`（應回傳非空）
    - `git config --get commit.gpgsign`（應回傳 `true`）
    - `git config --get commit.gpgSign`（某些版本大小寫不同，作為 fallback）
    - `git config --get user.email`（確認使用的 email 對應到 GPG key 的 identity）
    - `gpg --list-secret-keys --keyid-format LONG`（確認 signing key 實際存在於 keyring）
    - 測簽：`echo test | gpg --clearsign 2>&1 | head -20` 確認無 prompt（若要 passphrase，會失敗，需使用者協助）
  - 如果以上任一項失敗：產出 `.sisyphus/evidence/gpg-preflight-fail.md` 指明哪一步缺什麼，把計畫從此 task 後 halt（等同 T0 邏輯），請使用者修好再 /start-work
  - 另外確認 commit 格式規範：列出預期 commit 前綴白名單 `(feat|fix|refactor|chore)\(<Scope>\): <desc>` 並寫入 `.sisyphus/evidence/commit-format-spec.md` 供後續 commit checkpoint 參考
  - 確認 `git log --format='%B' HEAD | head -20` 中沒有 `Co-Authored-By:`（僅作觀察，不強制現狀，只寫入 spec）

  **Must NOT do**:
  - 不得修改 `~/.gitconfig` 或 repo `.git/config`
  - 不得儲存或 echo GPG passphrase
  - 不得自動 commit 任何東西
  - 不得在 pre-flight 失敗後繼續；必須 halt 等使用者修正

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 一連串 git / gpg 讀取命令

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: 所有 commit checkpoints（C1–C6）
  - **Blocked By**: None

  **References**:
  - `~/.claude/CLAUDE.md` — commit 格式規範出處（`feat(Scope): short description`；不加 `Co-Authored-By:`）

  **WHY Each Reference Matters**:
  - GPG 未設定的話 C1 會失敗並中斷整個實作 wave；先行確認避免損失進度

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: GPG 已正確設定
    Tool: Bash (git / gpg)
    Steps:
      1. SK=$(git config --get user.signingkey); test -n "$SK"
      2. GSIGN=$(git config --get commit.gpgsign); test "$GSIGN" = "true"
      3. gpg --list-secret-keys --keyid-format LONG | grep -q "$SK"
      4. echo "probe" | gpg --clearsign > /tmp/gpg-probe.txt 2>&1 && head -1 /tmp/gpg-probe.txt | grep -q "BEGIN PGP SIGNED MESSAGE"
      5. .sisyphus/evidence/gpg-preflight-ok.md 標示 PASS + key fingerprint
    Expected Result: 所有檢查通過；計畫可進 Wave 2
    Evidence: .sisyphus/evidence/gpg-preflight-ok.md

  Scenario: GPG 未設定或無法簽章（失敗 halt）
    Tool: Bash (git / gpg)
    Steps:
      1. 任一檢查失敗即寫入 .sisyphus/evidence/gpg-preflight-fail.md
      2. 內容含：哪一步 fail、原命令輸出、建議修復步驟（`git config --global user.signingkey <key>` 之類）
      3. 計畫 halt
    Expected Result: halt + 回報
    Evidence: .sisyphus/evidence/gpg-preflight-fail.md
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/gpg-preflight-ok.md` 或 `gpg-preflight-fail.md`
  - [ ] `.sisyphus/evidence/commit-format-spec.md`

  **Commit**: NO

- [x] 2. **修復 Settings 閃爍（Issue #57）**

  **What to do**:
  - 讀 `.sisyphus/evidence/isNTUSTLoggedIn-callers.txt`（T1b 產出）確認僅 SettingsView 需處理
  - 開 `swift/TigerDuck/Features/Settings/SettingsView.swift`
  - 找到 `ntustAccountRow`（約在 278-286 行）中傳遞給 `accountRow` 的 `isLoggedIn` 參數
  - 把該參數來源從 `appState.isNTUSTLoggedIn` 改為 `appState.authService.hasStoredCredentials`（或同等 cached-first 訊號）
  - 若 AppState 未公開 `authService.hasStoredCredentials` 的便利存取，在 AppState 裡加一個 computed `var ntustHasCredentials: Bool { authService.hasStoredCredentials }`，並改 SettingsView 綁這個
  - 保留 `accountRow` 簽名與其餘邏輯不變（包含 `signInAction` / `signOutAction` 綁定）
  - 若 T1b 發現其他檔案也綁 `isNTUSTLoggedIn` 但標記 `OUT_OF_SCOPE`：**不動**，僅在 commit body 附一句「其他 NTUST binding caller 已記於 evidence，未來再評估」
  - 同時確認 `AppState.isNTUSTLoggedIn` 本身**保留不刪除**（其他 code 可能仍引用；刪除會超出 scope）

  **Must NOT do**:
  - 不得刪除 `AppState.isNTUSTLoggedIn` computed property
  - 不得修改 `accountRow` 函式簽名（保持 reusability）
  - 不得加 spinner / loading indicator / 新 UI 元素（user 選了「最簡無感」）
  - 不得改動 `AuthService.isNTUSTAuthenticated` 語意
  - 不得 migrate 其他被 T1b 標示為 OUT_OF_SCOPE 的檔案

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 單檔小改、語意清晰、有完整前置研究
  - **Skills**: 無

  **Parallelization**:
  - **Can Run In Parallel**: YES（與 T3, T4 同 wave）
  - **Parallel Group**: Wave 2
  - **Blocks**: T9（compile matrix）
  - **Blocked By**: T1b

  **References**:

  **Pattern References**:
  - `swift/TigerDuck/Features/Settings/SettingsView.swift:278-286` — `ntustAccountRow` 目前綁 `isNTUSTLoggedIn`
  - `swift/TigerDuck/Features/Settings/SettingsView.swift:299-344` — `accountRow` + 動作按鈕（保持不變的部分）
  - `swift/TigerDuck/App/AppState.swift:84` — `isNTUSTLoggedIn` 定義（保留）
  - `swift/TigerDuck/App/AppState.swift:95-98` — `ntustProtectedAccessState(isEmpty:)` 正規 cached-first 範例
  - `swift/TigerDuck/Services/Auth/AuthService.swift:28-31` — `hasStoredCredentials` 定義

  **API/Type References**:
  - `NTUSTProtectedAccessState` (in `swift/TigerDuck/SharedUI/NTUSTProtectedAccessState.swift`) — 其他畫面用的 enum；Settings 不需用整個 enum（只需 bool）但參考其語意

  **External References**:
  - `AGENTS.md`: 「Auth gating is cached-first: screens should derive NTUST access from `AppState.ntustProtectedAccessState(isEmpty:)`, not from cookie validity alone.」

  **WHY Each Reference Matters**:
  - `hasStoredCredentials` 是 Keychain-backed 穩定來源，不會因 cookie TTL 而 flip
  - 對齊 AGENTS.md cached-first 準則，讓 Settings 行為與其他保護畫面一致
  - 保留 `isNTUSTLoggedIn` 是為了避免意外破壞其他（尚未被 migrate 的）consumer

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: SettingsView 不再綁 isNTUSTLoggedIn
    Tool: Bash (rg)
    Preconditions: T2 完成 edit
    Steps:
      1. rg -n 'appState\.isNTUSTLoggedIn|isNTUSTLoggedIn' swift/TigerDuck/Features/Settings/
      2. 比對預期：
         - `SettingsView.swift` 內 `isNTUSTLoggedIn` 出現次數為 0
         - 其他 Settings 子檔（若有）若被 T1b 標 OUT_OF_SCOPE 可容許保留
    Expected Result: rg 輸出不含 `SettingsView.swift:.*appState.isNTUSTLoggedIn`
    Failure Indicators: SettingsView.swift 內仍有 `isNTUSTLoggedIn` 引用
    Evidence: 在 .sisyphus/evidence/task-2-settings-rg.txt 儲存 rg 完整輸出

  Scenario: SettingsView 改綁 hasStoredCredentials 或等價
    Tool: Bash (rg + ast-grep)
    Steps:
      1. rg -n 'hasStoredCredentials|ntustHasCredentials|ntustProtectedAccessState' swift/TigerDuck/Features/Settings/SettingsView.swift
      2. 比對預期：至少 1 筆在 `ntustAccountRow` 附近
    Expected Result: 新訊號來源存在
    Evidence: .sisyphus/evidence/task-2-new-binding.txt

  Scenario: Compile pass（Swift file 語法正確）
    Tool: Bash (xcodebuild)
    Steps:
      1. xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck \
         -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet 2>&1 | tee /tmp/xcb-t2.log
      2. 檢查 exit code 為 0
      3. grep -i 'error:' /tmp/xcb-t2.log 應為空
    Expected Result: exit 0, 無 error
    Failure Indicators: compile 失敗或出現 error:
    Evidence: .sisyphus/evidence/task-2-xcbuild.log（grep 結果）

  Scenario: AppState.isNTUSTLoggedIn 本身仍存在（避免意外刪除）
    Tool: Bash (rg)
    Steps:
      1. rg -n 'var isNTUSTLoggedIn' swift/TigerDuck/App/AppState.swift
    Expected Result: ≥1 match（保留）
    Failure Indicators: 0 matches 代表誤刪
    Evidence: 併入 task-2-rg.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-2-settings-rg.txt`
  - [ ] `.sisyphus/evidence/task-2-new-binding.txt`
  - [ ] `.sisyphus/evidence/task-2-xcbuild.log`

  **Commit**: YES（C1）
  - Message:
    ```
    fix(Settings): bind account row to stable credential state

    - Switch SettingsView account row from isNTUSTLoggedIn to hasStoredCredentials
      so the indicator no longer flickers to "not logged in" during silent
      cookie TTL re-auth.
    - Preserves cached-first policy documented in AGENTS.md.
    - Other isNTUSTLoggedIn callers remain unchanged; inventory in
      .sisyphus/evidence/isNTUSTLoggedIn-callers.txt for future scope.
    - Refs: #57
    ```
  - Files: `swift/TigerDuck/Features/Settings/SettingsView.swift`, 可能 `swift/TigerDuck/App/AppState.swift`（若加 `ntustHasCredentials` convenience）
  - Pre-commit: `xcodebuild build` TigerDuck scheme exit 0

- [x] 3. **MoodleTokenService + 錯誤 enum + actor 併發保護**

  **What to do**:
  - 新建 `swift/TigerDuck/Services/Auth/MoodleWebserviceError.swift`：
    ```swift
    enum MoodleWebserviceError: Error, Equatable {
      case invalidToken          // errorcode: invalidtoken / accessexception
      case invalidCredentials    // errorcode: invalidlogin (來自 /login/token.php)
      case webserviceDisabled    // errorcode: enablewsdescription / servicenotloaded
      case transientNetwork(underlying: String)  // URLError 等（只帶描述字串避免外露細節）
      case malformedResponse(detail: String)     // JSON 結構非預期
      case httpStatus(code: Int)                 // 非 200（e.g. 403 / 500 / 3xx）
    }
    ```
    - 提供一個靜態方法 `static func from(jsonData: Data) throws -> MoodleWebserviceError?` 從 Moodle error body 解析
    - 不引入多餘 subtype（遵循 Metis 指令：禁止 `TokenRefreshCoordinator` 等抽象）
  - 新建 `swift/TigerDuck/Services/Auth/MoodleTokenService.swift`：
    ```swift
    actor MoodleTokenService {
      static let shared = MoodleTokenService()

      private let siteBaseURL: URL  // 預設 https://moodle2.ntust.edu.tw (由 AppConstants 提供)
      private var inFlightTokenTask: Task<String, Error>?    // 併發 obtain guard
      private var inFlightRefreshTask: Task<String, Error>?  // 併發 refresh guard

      // 1. 首次取 token（interactive login 用 — AuthService.login 呼叫）
      func obtainToken(studentId: String, password: String) async throws -> String
      // 回傳 webservice token；內部會：
      //  a. 若已有 in-flight obtain task → 共享同一 task，直接 await
      //  b. 否則打 /login/token.php?service=moodle_mobile_app
      //  c. 取得後存 Keychain (moodleToken + moodlePrivateToken)
      //  d. 清除 inFlightTokenTask 並回傳 token

      // 2. 自動刷新 token（MoodleService 遇 invalidtoken 時呼叫 — 無需 UI 介入）
      func refreshTokenIfNeeded() async throws -> String
      // 目的：對齊 Moodle Mobile App 連續使用 3+ 個月無需重新授權的行為
      // 內部會：
      //  a. 若已有 in-flight refresh task → 共享同一 task（併發 guard）
      //  b. 讀 Keychain：AppConstants.KeychainKeys.studentId + .password
      //     - 若兩者任一缺 → throw MoodleWebserviceError.invalidCredentials
      //       （僅此情境才會外流到 UI，由上層決定是否 presentNTUSTLogin）
      //  c. 清除舊 Moodle token（保險）後打 /login/token.php 取新 token
      //     - 若回 invalidlogin（Keychain 密碼失效，代表使用者於網頁改了密碼）
      //       → throw MoodleWebserviceError.invalidCredentials（上層處理）
      //     - 若回 token 成功 → 存 Keychain、清 inFlightRefreshTask、回傳新 token
      //  d. 其他錯誤（網路 / HTTP 5xx）→ 不清 token，throw transientNetwork / httpStatus

      // 3. 清除 token（logout 用 / 遭遇 invalidtoken 時，由 MoodleService 呼叫）
      func clearToken()

      // 4. 讀目前 token（MoodleService 優先呼叫；若回 nil 表示無 token，MoodleService 會呼 refreshTokenIfNeeded）
      func currentToken() -> String?
    }
    ```
  - 網路實作原則：
    - 使用既有 `NTUSTSessionManager.shared.session` 發 request（共用 UA / timeout）但**不經過 HTTPCookieStorage**（token-based 不需 cookie；若 session 預設帶 cookie jar，送 request 時 URLRequest header 不需 Cookie — URLSession 會自動處理但實測不會因此造成影響；為保守起見 request 時可 `urlRequest.setValue("", forHTTPHeaderField: "Cookie")` 或使用 `URLSessionConfiguration.ephemeral`**決策：建一個獨立的 ephemeral URLSession（避免 cookie 干擾），大約 20 行 helper**）
    - URL 建構：`URLComponents` + `queryItems`，**禁止字串相加** URL
    - 回應處理：先檢 HTTP status → 再嘗試 decode `token`：成功返回；否則 `MoodleWebserviceError.from(jsonData:)` → 對應 error case
  - Token persistence：
    - `KeychainManager.save(value:key:)` / `.loadString(key:)` / `.delete(key:)` 既有 API
    - key 名稱由 T4 定義的 `AppConstants.KeychainKeys.moodleToken`、`.moodlePrivateToken` 提供
  - 安全：
    - 任何 `print` / `os_log` / `NSLog` 一律**不得出現 token 或 privateToken 字串值**；log 僅記 `"moodle token obtained (len=\(token.count))"` 這類摘要
  - Widget 共用：
    - 若 T1c 回報 `HAS_COUPLING`：此 task 在保存時使用 SecureStore 的 shared access group（和 studentId/password 一致）
    - 若 `NO_COUPLING`：用 app-only（保留最小攻擊面）

  **Must NOT do**:
  - 不得引入 protocol `MoodleTokenProviding` / `TokenRefreshCoordinator` / 泛型 `WebserviceClient<T>`（Metis 點名禁止）
  - 不得加重試迴圈 / exponential backoff（retry 由 MoodleService 層做一次性，不是這裡的事）
  - 不得把 token 暴露成 `@Observable` 或任何 SwiftUI binding
  - 不得用 `UserDefaults` 儲存 token
  - 不得加字串串接組 URL
  - 不得 log token/privateToken 字面值
  - 不得對外暴露 `URLSession` 或 `URLRequest` 細節
  - 不得硬編碼 siteBaseURL（從 AppConstants 讀，Task 4 定義）
  - **`refreshTokenIfNeeded()` 絕對不得彈 UI / 不得要求使用者輸入密碼**（整個目的是無感）
  - `refreshTokenIfNeeded()` 絕對不得觸發 NTUST SSO re-flow（只打 Moodle 的 `/login/token.php`）
  - 不得在 `refreshTokenIfNeeded()` 內部呼叫 `obtainToken(studentId:password:)` 以外的公開方法（單一 entry point）

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: 需要仔細設計 actor 序列化、error mapping、ephemeral session 保守策略；涉及 Keychain + 網路
  - **Skills**: 無特殊需要（Swift/SwiftUI 是 build agent 內建能力）

  **Parallelization**:
  - **Can Run In Parallel**: YES（與 T2, T4 同 wave）
  - **Parallel Group**: Wave 2
  - **Blocks**: T4, T5, T6
  - **Blocked By**: T0

  **References**:

  **Pattern References**:
  - `swift/TigerDuck/Services/Auth/AuthService.swift` — 現有 service 結構、Keychain 呼叫、錯誤處理風格
  - `swift/TigerDuck/Services/Network/SSOLoginService.swift` — URLSession 使用、JSON decode 既有慣例
  - `swift/TigerDuck/Services/Network/NTUSTSessionManager.swift` — User-Agent 設定、timeout 值（15s）

  **API/Type References**:
  - `swift/TigerDuck/Services/Auth/KeychainManager.swift` — `save/loadString/delete` 三個方法
  - `swift/TigerDuck/Services/Auth/SecureStore.swift` — 背後的 Valet / SecItem；Valet 會自動處理 shared group

  **External References**:
  - Moodle 官方 token endpoint: `POST /login/token.php` with params `username`, `password`, `service=moodle_mobile_app`, optional `lang`
  - Moodle 官方 webservice REST: `GET /webservice/rest/server.php?wstoken=X&wsfunction=core_webservice_get_site_info&moodlewsrestformat=json` — 用來驗證 token 有效性
  - 錯誤 code 參考：`invalidtoken`, `accessexception`, `invalidlogin`, `enablewsdescription`, `servicenotloaded`（librarian 彙整）

  **WHY Each Reference Matters**:
  - AuthService 風格保一致性，避免 reviewer 指為 AI slop
  - `core_webservice_get_site_info` 是最輕量的驗 token 呼叫（幾乎所有 Moodle 皆啟用）

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: 檔案與關鍵結構到位
    Tool: Bash (test + ast-grep)
    Steps:
      1. test -f swift/TigerDuck/Services/Auth/MoodleTokenService.swift
      2. test -f swift/TigerDuck/Services/Auth/MoodleWebserviceError.swift
      3. ast-grep --lang swift --pattern 'actor MoodleTokenService { $$$ }' swift/TigerDuck/Services/Auth/MoodleTokenService.swift | grep -q MoodleTokenService
      4. ast-grep --lang swift --pattern 'enum MoodleWebserviceError: $$$' swift/TigerDuck/Services/Auth/MoodleWebserviceError.swift | grep -q MoodleWebserviceError
      5. rg -n 'case invalidToken|case invalidCredentials|case webserviceDisabled|case transientNetwork|case malformedResponse|case httpStatus' swift/TigerDuck/Services/Auth/MoodleWebserviceError.swift
      6. 檢查 6 行（6 個 case 全到齊）
    Expected Result: 檔案存在、actor / enum 關鍵字正確、6 個 error case 全到齊
    Failure Indicators: 任一檔案缺、actor 被寫成 class、缺少任一 case
    Evidence: .sisyphus/evidence/task-3-structure.txt

  Scenario: 無禁用抽象 / 無 token log 洩漏
    Tool: Bash (ast-grep + rg)
    Steps:
      1. rg -n 'protocol MoodleToken|TokenRefreshCoordinator|WebserviceClient' swift/TigerDuck/Services/Auth/ 應為空
      2. ast-grep --lang swift --pattern 'UserDefaults.$$$.set($_, forKey: $_)' swift/TigerDuck/Services/Auth/MoodleTokenService.swift 應為 0
      3. rg -n 'print\(.*token|NSLog\(.*token|os_log.*token' swift/TigerDuck/Services/Auth/MoodleTokenService.swift 應無實際 token 值（可允許 `len=\(token.count)` 這種摘要；reviewer 判讀）
    Expected Result: 以上 3 項皆符合
    Evidence: .sisyphus/evidence/task-3-antipatterns.txt

  Scenario: 公開 API 符合約定
    Tool: ast-grep
    Steps:
      1. 確認以下三個公開方法存在：
         - `func obtainToken(studentId:password:) async throws -> String`
         - `func clearToken()`
         - `func currentToken() -> String?`
      2. ast-grep --lang swift --pattern 'func obtainToken($$$) async throws -> String' swift/TigerDuck/Services/Auth/MoodleTokenService.swift
    Expected Result: 三者皆在
    Evidence: .sisyphus/evidence/task-3-api.txt

  Scenario: Compile pass
    Tool: Bash (xcodebuild)
    Steps:
      1. xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck \
         -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet 2>&1 | tee /tmp/xcb-t3.log
      2. exit 0
      3. grep -i 'error:' /tmp/xcb-t3.log 為空
    Expected Result: compile 成功
    Evidence: .sisyphus/evidence/task-3-xcbuild.log
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-3-structure.txt`
  - [ ] `.sisyphus/evidence/task-3-antipatterns.txt`
  - [ ] `.sisyphus/evidence/task-3-api.txt`
  - [ ] `.sisyphus/evidence/task-3-xcbuild.log`

  **Commit**: YES（合併 C2，與 T4）— 見 T4

- [x] 4. **AppConstants Keychain keys + AppState fresh-install purge**

  **What to do**:
  - 開 `swift/TigerDuck/App/AppConstants.swift` 找 `KeychainKeys` 區塊（參考 studentId / password 的命名樣式）
  - 新增兩個 static let：
    ```swift
    static let moodleToken = "com.tigerduck.moodleToken"
    static let moodlePrivateToken = "com.tigerduck.moodlePrivateToken"
    ```
    （精確前綴 `com.tigerduck.` 需對齊現有鍵之前綴；必要時讀 studentId 的字面值採同風格）
  - 在同檔新增一個便利 siteURL：
    ```swift
    // 若 AppConstants 尚無 Moodle URL 區塊則新增
    static let moodleBaseURL = URL(string: "https://moodle2.ntust.edu.tw")!
    ```
    （位置放在既有 NTUST URL 常數附近；若已有則不重複）
  - 開 `swift/TigerDuck/App/AppState.swift` 找 fresh-install 清除區塊（約在 init 內 `if !Defaults[.appHasBeenInstalled]` 分支，行數約 28-38）
  - 在既有 `KeychainManager.delete(key: ...studentId)`、`.password` 下方加入兩行：
    ```swift
    KeychainManager.delete(key: AppConstants.KeychainKeys.moodleToken)
    KeychainManager.delete(key: AppConstants.KeychainKeys.moodlePrivateToken)
    ```
  - 注意：此 task **不**碰 `AuthService.logout()` 的清除邏輯（那是 T5 的範圍，避免兩 task 改同一函式造成 merge 衝突）

  **Must NOT do**:
  - 不得改動其他現有 Keychain keys 的字面值（兼容性）
  - 不得在 `AppConstants` 引入 enum 容器或 namespace 重構
  - 不得把 key 值改為動態 / 運算 (必須 static let string literal)
  - 不得在 `AppState.logoutNTUST()` 加任何邏輯（T5）

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 少量文字新增，精準位置可由前置研究找到

  **Parallelization**:
  - **Can Run In Parallel**: YES（依 T3）
  - **Parallel Group**: Wave 2
  - **Blocks**: T5, T6（兩者需要 key 名稱）
  - **Blocked By**: T3（T3 的 MoodleTokenService 依賴此處定義的 key；實際上 T4 可以先跑，T3 若等不及可先定義 local const 測試，但建議 T4 在 T3 完成後執行以對齊 key 字面值）

  **References**:

  **Pattern References**:
  - `swift/TigerDuck/App/AppConstants.swift` 中既有 `KeychainKeys.studentId`、`.password` 的命名（讀檔前先確認前綴）
  - `swift/TigerDuck/App/AppState.swift:28-38` — fresh-install 清除區塊

  **API/Type References**:
  - `swift/TigerDuck/Services/Auth/KeychainManager.swift:delete(key:)` — 清除 API
  - `swift/TigerDuck/App/AppDefaults.swift:appHasBeenInstalled` — fresh-install 判斷用的 flag

  **WHY Each Reference Matters**:
  - Moodle token 若 fresh-install 未清會造成「安裝新 app / 換帳號」使用舊 token 的 bug
  - AppConstants 集中管理避免各處 hardcode 字串

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Keychain keys 已定義
    Tool: Bash (rg)
    Steps:
      1. rg -n 'moodleToken|moodlePrivateToken' swift/TigerDuck/App/AppConstants.swift
      2. 預期：各 ≥1 match
      3. rg -n 'moodleBaseURL' swift/TigerDuck/App/AppConstants.swift
      4. 預期：≥1 match
    Expected Result: 三個 constant 都存在
    Evidence: .sisyphus/evidence/task-4-constants.txt

  Scenario: Fresh-install purge 涵蓋新 keys
    Tool: Bash (rg)
    Steps:
      1. rg -n 'KeychainKeys\.moodleToken|KeychainKeys\.moodlePrivateToken' swift/TigerDuck/App/AppState.swift
      2. 預期：≥2 match，位置在 fresh-install 區塊
      3. 人工（或 reviewer）確認兩行在 `if !Defaults[.appHasBeenInstalled]` 分支內
    Expected Result: 兩 key 皆在 purge 區塊
    Failure Indicators: key 有定義但 AppState purge 未加
    Evidence: .sisyphus/evidence/task-4-purge.txt

  Scenario: 無其他 Keychain keys 誤改
    Tool: Bash (git diff)
    Steps:
      1. git diff --stat HEAD -- swift/TigerDuck/App/AppConstants.swift
      2. 預期：只新增行，無刪除或修改既有 KeychainKeys 字面值
      3. git diff HEAD -- swift/TigerDuck/App/AppConstants.swift | grep -E '^-[^-]' | wc -l
      4. 預期 == 0（無 deletion）
    Expected Result: 新增性變更
    Evidence: .sisyphus/evidence/task-4-diff.txt

  Scenario: Compile pass
    Tool: Bash (xcodebuild)
    Steps:
      1. xcodebuild build ... -scheme TigerDuck ... -quiet 2>&1 | tee /tmp/xcb-t4.log
      2. exit 0
    Expected Result: compile 成功
    Evidence: .sisyphus/evidence/task-4-xcbuild.log
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-4-constants.txt`
  - [ ] `.sisyphus/evidence/task-4-purge.txt`
  - [ ] `.sisyphus/evidence/task-4-diff.txt`
  - [ ] `.sisyphus/evidence/task-4-xcbuild.log`

  **Commit**: YES（C2 合併 T3 + T4）
  - Message:
    ```
    feat(MoodleAuth): add MoodleTokenService with actor-based token exchange

    - Introduces POST /login/token.php?service=moodle_mobile_app flow that
      persists the returned token via KeychainManager under new
      KeychainKeys.moodleToken / .moodlePrivateToken.
    - Actor serialization prevents concurrent token exchanges.
    - Adds MoodleWebserviceError enum with explicit cases for invalidToken,
      invalidCredentials, webserviceDisabled, transientNetwork,
      malformedResponse, httpStatus.
    - Updates AppState fresh-install purge to clear the new keys.
    - Refs: #11
    ```
  - Files:
    - `swift/TigerDuck/Services/Auth/MoodleTokenService.swift`（new）
    - `swift/TigerDuck/Services/Auth/MoodleWebserviceError.swift`（new）
    - `swift/TigerDuck/App/AppConstants.swift`
    - `swift/TigerDuck/App/AppState.swift`
  - Pre-commit: `xcodebuild build TigerDuck` + `lsp_diagnostics` 0 error + T3/T4 的 AC 全部通過

- [x] 5. **AuthService.login/logout 串接（純 feature 本體，無 migration）**

  **What to do**:
  - 開 `swift/TigerDuck/Services/Auth/AuthService.swift`
  - 在 `login(studentId:password:)` 成功 branch（`markLoginSuccess()` 之後）新增一段：
    ```swift
    // 取 Moodle webservice token（非致命 — 失敗只 log）
    do {
      _ = try await MoodleTokenService.shared.obtainToken(studentId: studentId, password: password)
    } catch {
      // 絕對不得阻擋 NTUST login 成功結果；不 log token 值
      logger.warning("Moodle token obtain failed: \(String(describing: error))")
    }
    ```
  - 在 `logout()` 中，於 `KeychainManager.delete(...password)` 下方加：
    ```swift
    Task { await MoodleTokenService.shared.clearToken() }
    ```
    （actor 的 async call，fire-and-forget；不 block UI）
  - **`ensureAuthenticated()` 保持不動**（除非與 T3 必要介面串接有關的微調）；舊用戶升級路徑由 Task 5b 的 `MoodleTokenMigration` 負責，**不在此處處理**
  - 不動 `isNTUSTAuthenticated`、`hasStoredCredentials`、`loginGeneration` 的定義與語意

  **Must NOT do**:
  - **不得在 `AuthService` 內加入任何 migration 邏輯**（包括 `ensureAuthenticated` 裡「如果 Moodle token 缺就取一次」的分支 — 那是 T5b 的專屬職責）
  - 不得把 Moodle token 取得失敗當作 NTUST login 失敗（Moodle 錯誤不應 cascade 至 NTUST 登入狀態）
  - 不得改 `AuthService` 其他方法的 signature
  - 不得在 `logout()` 等 Moodle clearToken 完成才回傳（會阻塞 UI）
  - 不得取消或重寫既有 `loginGeneration` bump 邏輯
  - 不得 log 出 password / token 字面值
  - 不得在 AuthService 引用 `MoodleTokenMigration` 或任何 `Migrations/` 下的型別

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: 涉及時序（login → markSuccess → 取 token），以及 Moodle 錯誤不 cascade NTUST 的規則，需要謹慎

  **Parallelization**:
  - **Can Run In Parallel**: YES（與 T6 同 wave）
  - **Parallel Group**: Wave 3
  - **Blocks**: T8, T9
  - **Blocked By**: T3, T4, T1d

  **References**:

  **Pattern References**:
  - `swift/TigerDuck/Services/Auth/AuthService.swift:60-95` — `login()` 實作（需要找 `markLoginSuccess()` 呼叫點）
  - `swift/TigerDuck/Services/Auth/AuthService.swift:111-133` — `ensureAuthenticated()`
  - `swift/TigerDuck/Services/Auth/AuthService.swift:135-144` — `logout()`
  - `swift/TigerDuck/Services/Auth/AuthService.swift:16` — `loginGeneration` race guard（保留勿改）

  **API/Type References**:
  - `MoodleTokenService.obtainToken`（由 T3 提供）
  - `MoodleTokenService.clearToken`
  - `MoodleTokenService.currentToken`

  **External References**:
  - AGENTS.md cached-first 段落（確認 `ensureAuthenticated` 語意）

  **WHY Each Reference Matters**:
  - `login()` 的成功 branch 時機最關鍵：Moodle token 必須在使用者被視為登入成功「之後」才取；失敗不能 cascade
  - `logout()` fire-and-forget Moodle clear 保證 UI 不被 block

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: login 成功 branch 呼叫 MoodleTokenService.obtainToken
    Tool: Bash (rg) + ast-grep
    Steps:
      1. rg -n 'MoodleTokenService\.shared\.obtainToken' swift/TigerDuck/Services/Auth/AuthService.swift
      2. 預期 ≥1 match 在 `login(` 函式內
      3. ast-grep --lang swift --pattern 'func login($$$) async -> Bool { $$$ MoodleTokenService.shared.obtainToken($$$) $$$ }' swift/TigerDuck/Services/Auth/AuthService.swift
    Expected Result: 呼叫存在且在 login 函式內
    Evidence: .sisyphus/evidence/task-5-login-hook.txt

  Scenario: logout 清 Moodle token
    Tool: Bash (rg)
    Steps:
      1. rg -n 'MoodleTokenService\.shared\.clearToken' swift/TigerDuck/Services/Auth/AuthService.swift
      2. 預期 ≥1 match 在 `logout(` 附近
    Expected Result: clearToken 呼叫存在於 logout
    Evidence: .sisyphus/evidence/task-5-logout-hook.txt

  Scenario: Moodle token 失敗不阻擋 login 成功
    Tool: ast-grep
    Steps:
      1. 人工 review MoodleTokenService.shared.obtainToken 是否包在 do-catch 或 try?
      2. ast-grep --lang swift --pattern 'do { $$$ try await MoodleTokenService.shared.obtainToken($$$) $$$ } catch { $$$ }' swift/TigerDuck/Services/Auth/AuthService.swift
      3. 確認 catch block 沒有 `return false` 或 `self.loginError = ...`
    Expected Result: ast-grep 匹配成功且 catch 內無阻擋
    Failure Indicators: token error 造成 login 回 false
    Evidence: .sisyphus/evidence/task-5-error-isolation.txt

  Scenario: AuthService 零 migration 殘留
    Tool: Bash (rg)
    Steps:
      1. rg -n 'MoodleTokenMigration|migration|Migration' swift/TigerDuck/Services/Auth/AuthService.swift
      2. 預期：0 match（AuthService 完全不引用 migration）
      3. rg -n 'ensureAuthenticated' swift/TigerDuck/Services/Auth/AuthService.swift
      4. 讀該函式內文，確認無「if token is nil then obtain」這類 migration-ish 分支
    Expected Result: AuthService 本體完全不含 migration 邏輯
    Failure Indicators: 發現任何 MoodleTokenMigration import 或 migration-ish 條件判斷
    Evidence: .sisyphus/evidence/task-5-no-migration.txt

  Scenario: 未更動 loginGeneration / isNTUSTAuthenticated
    Tool: Bash (git diff)
    Steps:
      1. git diff HEAD -- swift/TigerDuck/Services/Auth/AuthService.swift | grep -E 'loginGeneration|isNTUSTAuthenticated|hasStoredCredentials'
      2. 預期：若 match，行數應只是新增的呼叫點（非修改既有定義）
    Expected Result: 核心語意未被動到
    Evidence: .sisyphus/evidence/task-5-diff-check.txt

  Scenario: Compile pass
    Tool: Bash (xcodebuild)
    Steps:
      1. xcodebuild build ... -scheme TigerDuck ... -quiet 2>&1 | tee /tmp/xcb-t5.log
      2. exit 0
    Expected Result: compile 成功
    Evidence: .sisyphus/evidence/task-5-xcbuild.log
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-5-login-hook.txt`
  - [ ] `.sisyphus/evidence/task-5-logout-hook.txt`
  - [ ] `.sisyphus/evidence/task-5-error-isolation.txt`
  - [ ] `.sisyphus/evidence/task-5-no-migration.txt`
  - [ ] `.sisyphus/evidence/task-5-diff-check.txt`
  - [ ] `.sisyphus/evidence/task-5-xcbuild.log`

  **Commit**: YES（C3）
  - Message:
    ```
    feat(Auth): wire MoodleTokenService into login/logout lifecycle

    - login() now obtains a Moodle webservice token right after
      markLoginSuccess(); failures are isolated and never cascade to
      NTUST login state.
    - logout() asynchronously clears the Moodle token via actor fire-and-forget
      so UI is not blocked.
    - No migration logic embedded here — legacy user upgrade is handled
      exclusively by Services/Migrations/MoodleTokenMigration.swift.
    - loginGeneration / isNTUSTAuthenticated semantics unchanged.
    - Refs: #11
    ```
  - Files: `swift/TigerDuck/Services/Auth/AuthService.swift`
  - Pre-commit: `xcodebuild build TigerDuck` + T5 AC 通過

- [x] 5b. **Migrations/ 資料夾 + MoodleTokenMigration.swift + AppState 觸發點**

  **What to do**:
  - 新建資料夾 `swift/TigerDuck/Services/Migrations/`
  - 新建 `swift/TigerDuck/Services/Migrations/AGENTS.md`，內容為本資料夾的長期契約（引用本計畫 Must Have 的 migration 規範）：
    ```markdown
    # Migrations — TigerDuck Compatibility Layer

    This folder is the ONLY location permitted for breaking-change compatibility code.

    ## Rules
    1. One migration = one Swift file. No cross-file imports within this folder.
    2. Every migration is self-contained: owns its idempotency flag (via Defaults), its run() method, its failure handling.
    3. Trigger point: AppState.runPendingMigrations() called once per app launch.
    4. Feature services (AuthService, MoodleService, MoodleTokenService, etc.) MUST NOT reference types declared here.
    5. When a migration is no longer needed (all users have been through it), delete the entire file. Do not leave empty shells.
    6. File naming: `<Subject><Action>Migration.swift` (e.g., MoodleTokenMigration, LibraryTokenResetMigration).

    ## When to add a migration here
    - Breaking change in stored data shape (Keychain / UserDefaults / SwiftData / JSON cache)
    - One-time bootstrap needed for existing users on app upgrade
    - Cleanup of deprecated artifacts left behind by previous versions

    ## When NOT to use this folder
    - Regular feature code — belongs in Features/ or Services/<area>/
    - Ongoing runtime policies (retry, refresh) — belongs in the relevant service
    - New features — never call anything in this folder from feature code
    ```
  - 新建 `swift/TigerDuck/Services/Migrations/MoodleTokenMigration.swift`：
    ```swift
    // 舊用戶升級：Keychain 已有 NTUST 帳密但無 Moodle token
    // 執行：靜默呼叫 MoodleTokenService.refreshTokenIfNeeded 取得 token
    // 冪等：成功取得後設旗標 Defaults[.moodleTokenMigrationDone] = true；之後 skip
    // 失敗：不標旗標（下次啟動再試一次），不彈 UI，不干擾任何 feature

    enum MoodleTokenMigration {
      static func runIfNeeded() async {
        guard !Defaults[.moodleTokenMigrationDone] else { return }
        // 僅在 Keychain 已有帳密（舊用戶）才執行
        guard KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId) != nil,
              KeychainManager.loadString(key: AppConstants.KeychainKeys.password) != nil else {
          // 無帳密 = 新用戶未登入 = 這個 migration 對他不適用；標為完成避免反覆檢查
          Defaults[.moodleTokenMigrationDone] = true
          return
        }
        // 若 Keychain 已有 Moodle token，視為已 migrate
        if await MoodleTokenService.shared.currentToken() != nil {
          Defaults[.moodleTokenMigrationDone] = true
          return
        }
        do {
          _ = try await MoodleTokenService.shared.refreshTokenIfNeeded()
          Defaults[.moodleTokenMigrationDone] = true
        } catch {
          // 靜默失敗：不記旗標、不彈 UI；由下次啟動 / 首次 Moodle API call 再嘗試
        }
      }
    }
    ```
  - 在 `swift/TigerDuck/App/AppDefaults.swift` 新增一個 boolean key `moodleTokenMigrationDone`（default false）
  - 在 `swift/TigerDuck/App/AppState.swift` 新增一個方法 `runPendingMigrations()`：
    ```swift
    func runPendingMigrations() {
      Task.detached(priority: .utility) {
        await MoodleTokenMigration.runIfNeeded()
        // 未來有其他 migration 時，在此依序呼叫
      }
    }
    ```
    並在 `AppState.init()` 尾端（fresh-install 清除區塊之後）呼叫一次
  - 本 task 不改 `AuthService` / `MoodleService` / `MoodleTokenService` 任何 feature service

  **Must NOT do**:
  - 不得把 migration 邏輯放在 `AuthService` / `MoodleService` / `MoodleTokenService` 等任何非 Migrations/ 檔案
  - 不得讓 `MoodleTokenMigration` 依賴其他 migration
  - 不得讓 feature service 反向 import `MoodleTokenMigration`
  - 不得讓 migration 彈任何 UI / 顯示任何錯誤訊息
  - 不得在 migration 失敗時標記完成（失敗就不標，下次再試）
  - 不得把 migration 觸發點放在 `login()` / `ensureAuthenticated()` / `MoodleService.fetchXxx()`（只放 AppState 一次性呼叫）
  - 不得在 `AGENTS.md` 引用本次特定 issue 編號（該文件是長期準則，不是一次性備忘）

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: 架構性新模式建立 + 長期準則書寫；需要把握「如何讓未來 agent 不誤用此資料夾」

  **Parallelization**:
  - **Can Run In Parallel**: YES（與 T5, T6 同 wave）
  - **Parallel Group**: Wave 3
  - **Blocks**: T9（compile matrix）
  - **Blocked By**: T3（需 MoodleTokenService API）, T4（需 Keychain keys）

  **References**:

  **Pattern References**:
  - `swift/TigerDuck/App/AppState.swift:28-38` — 現有 fresh-install 清除區塊（可參考 AppState init 的擴充風格）
  - `swift/TigerDuck/App/AppDefaults.swift` — 新增 `moodleTokenMigrationDone` flag 的位置
  - `swift/TigerDuck/Services/Auth/MoodleTokenService.swift`（T3）— `refreshTokenIfNeeded` / `currentToken` 介面

  **API/Type References**:
  - `MoodleTokenService.shared.refreshTokenIfNeeded()`
  - `MoodleTokenService.shared.currentToken()`
  - `KeychainManager.loadString(key:)`
  - `Defaults[.moodleTokenMigrationDone]`（本 task 新增）

  **External References**:
  - 無（本 task 純專案內部結構）

  **WHY Each Reference Matters**:
  - AppState fresh-install 清除區塊與 migration 觸發點位置相近，但語意不同（前者是新安裝時清除、後者是升級時補齊）；AGENTS.md 要說清楚兩者差異
  - `refreshTokenIfNeeded` 已具備「讀 Keychain 帳密靜默換 token」語意 — migration 只需一個冪等 wrapper

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: 資料夾結構與 AGENTS.md 存在
    Tool: Bash (test)
    Steps:
      1. test -d swift/TigerDuck/Services/Migrations
      2. test -f swift/TigerDuck/Services/Migrations/AGENTS.md
      3. test -f swift/TigerDuck/Services/Migrations/MoodleTokenMigration.swift
      4. 檢查 AGENTS.md 字數 ≥ 500 bytes 且包含 "Migrations" / "breaking-change" / "self-contained" 等關鍵字
    Expected Result: 資料夾 + 兩檔案 + AGENTS.md 內容完整
    Evidence: .sisyphus/evidence/task-5b-structure.txt

  Scenario: Feature service 未汙染
    Tool: Bash (rg)
    Steps:
      1. rg -n 'MoodleTokenMigration|Services/Migrations' swift/TigerDuck/Services/Auth/AuthService.swift swift/TigerDuck/Services/Network/MoodleService.swift swift/TigerDuck/Services/Auth/MoodleTokenService.swift
      2. 預期：0 match（feature service 絕對不引用 migration）
      3. rg -n 'migration|Migration' swift/TigerDuck/Services/Auth/ swift/TigerDuck/Services/Network/
      4. 預期：僅 Migrations/ 路徑內的 Swift 檔案出現（其餘 feature service 0 match）
    Expected Result: migration 隔離完好
    Failure Indicators: AuthService 等 feature service 出現 migration 引用
    Evidence: .sisyphus/evidence/task-5b-isolation.txt

  Scenario: AppState 觸發點存在且冪等
    Tool: Bash (rg) + ast-grep
    Steps:
      1. rg -n 'runPendingMigrations\|MoodleTokenMigration' swift/TigerDuck/App/AppState.swift
      2. 預期：≥2 match（一個是 func 定義 / 一個是 init 內呼叫）
      3. rg -n 'moodleTokenMigrationDone' swift/TigerDuck/App/AppDefaults.swift
      4. 預期：≥1 match
      5. 讀 `MoodleTokenMigration.runIfNeeded` 確認：
         - 成功才設旗標
         - 失敗不設旗標
         - 無帳密時直接設旗標（短路）
    Expected Result: 冪等旗標正確使用
    Evidence: .sisyphus/evidence/task-5b-idempotent.txt

  Scenario: Migration 無 UI 副作用
    Tool: Bash (rg)
    Steps:
      1. rg -n 'presentNTUSTLogin|isShowingNTUSTLoginSheet|alert\(|Alert\(' swift/TigerDuck/Services/Migrations/
      2. 預期：0 match
    Expected Result: migration 完全靜默
    Evidence: .sisyphus/evidence/task-5b-no-ui.txt

  Scenario: Compile pass
    Tool: Bash (xcodebuild)
    Steps:
      1. xcodebuild build ... -scheme TigerDuck ... -quiet 2>&1 | tee /tmp/xcb-t5b.log
      2. exit 0
    Expected Result: compile 成功
    Evidence: .sisyphus/evidence/task-5b-xcbuild.log
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-5b-structure.txt`
  - [ ] `.sisyphus/evidence/task-5b-isolation.txt`
  - [ ] `.sisyphus/evidence/task-5b-idempotent.txt`
  - [ ] `.sisyphus/evidence/task-5b-no-ui.txt`
  - [ ] `.sisyphus/evidence/task-5b-xcbuild.log`

  **Commit**: YES（C3b — 與 C3 分開，獨立一個 commit 讓未來刪 migration 時更乾淨）
  - Message:
    ```
    feat(Migrations): introduce Services/Migrations/ compatibility layer

    - Establishes Services/Migrations/ as the sole location for
      breaking-change compatibility code; documents long-lived rules
      in Services/Migrations/AGENTS.md.
    - Adds MoodleTokenMigration.runIfNeeded() — one-time silent token
      exchange for users who had NTUST credentials before this change
      but no Moodle webservice token yet.
    - Wires AppState.runPendingMigrations() to trigger at init, via
      detached Task to avoid blocking UI.
    - Feature services remain free of migration code.
    - Refs: #11
    ```
  - Files:
    - `swift/TigerDuck/Services/Migrations/AGENTS.md`（new）
    - `swift/TigerDuck/Services/Migrations/MoodleTokenMigration.swift`（new）
    - `swift/TigerDuck/App/AppDefaults.swift`（新增 flag）
    - `swift/TigerDuck/App/AppState.swift`（新增 `runPendingMigrations` + init 呼叫；**不含 migration 實作本體**）
  - Pre-commit: `xcodebuild build TigerDuck` + T5b AC 通過

- [x] 6. **MoodleService 改寫為 REST webservice 呼叫**

  **What to do**:
  - 讀 `.sisyphus/evidence/moodle-inventory.md`（T1a 產出），拿到「每個網路呼叫 → 對應 webservice function」表格
  - 開 `swift/TigerDuck/Services/Network/MoodleService.swift`
  - 依照 inventory 逐一改寫：每個舊「SSO + HTML parse」呼叫改為「`GET /webservice/rest/server.php?wstoken=<T>&wsfunction=<F>&moodlewsrestformat=json` + JSON decode」
  - 常用 function 對應（依 inventory 確認可用）：
    - Assignments list → `mod_assign_get_assignments`
    - Calendar events → `core_calendar_get_action_events_by_timesort`（預期 user upcoming）或 `core_calendar_get_calendar_upcoming_view`
    - Course list → `core_enrol_get_users_courses`
  - 在呼叫前取 token：`guard let token = await MoodleTokenService.shared.currentToken() else { throw MoodleWebserviceError.invalidToken }`
  - 回應處理：
    - HTTP != 200 → 分類為 `MoodleWebserviceError.httpStatus(code:)` / `.transientNetwork(...)`
    - JSON 若含 `{"errorcode": "invalidtoken"}` → 清 token 並拋 `.invalidToken`
    - JSON 若含 `{"errorcode": "accessexception"}` → 同上
    - JSON 若含其他 errorcode → `.malformedResponse(detail:)`（log 內容但不暴露完整 body）
  - 解析成功路徑：decode 成對應的 Swift model（若 inventory 指出現有 `Assignment` / `CalendarEvent` model 不符 Moodle REST 回應格式，新建 `MoodleWebserviceModels.swift` 放 intermediate DTO，再轉成既有 model；保持 consumer 契約不破）
  - **刪除**既有 HTML parse 與 sesskey 取得邏輯；刪除 `SSOLoginService.ensureServiceLogin(for:)` 中**只為 Moodle 服務**的分支（依 inventory 判定）
  - **保留** `SSOLoginService.ensureServiceLogin(...)` 其他用途（若有）；若 inventory 確認僅為 Moodle 用，可整個方法刪（但這需要 Task 1a 明確標註）

  **Must NOT do**:
  - 不得在 MoodleService 內直接呼叫 `/login/token.php`（那是 MoodleTokenService 的職責）
  - 不得保留 sesskey 相關程式碼（除非 inventory 明確標「需保留 scrape」）
  - 不得改變 MoodleService 的 public API signature（consumer 契約）— 若必須改，需在本 task 標示並連動 T7
  - 不得加重試 / backoff / 退避邏輯（Metis 禁止）
  - 不得把 token 附加到 URL 顯示在任何 log
  - 不得使用 `String(contentsOf:)` 或其他同步 API 取遠端資料

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: 重寫層面大、涉及 model mapping、需謹慎保持 consumer 契約

  **Parallelization**:
  - **Can Run In Parallel**: YES（與 T5 同 wave）
  - **Parallel Group**: Wave 3
  - **Blocks**: T7, T10
  - **Blocked By**: T1a, T3, T4, T1d

  **References**:

  **Pattern References**:
  - `swift/TigerDuck/Services/Network/MoodleService.swift` — 現況實作（改寫目標）
  - `swift/TigerDuck/Services/Network/NTUSTSessionManager.swift` — 可共用 session（非強制；也可用 ephemeral）
  - `swift/TigerDuck/Services/Auth/MoodleTokenService.swift`（T3）— `currentToken()` 取 token 的 API
  - `swift/TigerDuck/Services/Auth/MoodleWebserviceError.swift`（T3）

  **API/Type References**:
  - `swift/TigerDuck/Bridge/KMPServiceBridge.swift:fetchAssignments` — primary consumer；其 `loginGeneration` guard 必須**保留**
  - `swift/TigerDuck/Features/Calendar/CalendarViewModel.swift:fetchMoodleEvents` — 另一 consumer

  **External References**:
  - Moodle REST 文件：`GET /webservice/rest/server.php?wstoken=X&wsfunction=F&moodlewsrestformat=json` — 需 `moodlewsrestformat=json`，否則預設為 XML
  - Moodle function 清單：https://docs.moodle.org/dev/Web_service_API_functions

  **WHY Each Reference Matters**:
  - 保留 consumer signature 是「範圍忠實度」基本要求；否則 T7 會過度膨脹
  - Moodle REST 預設格式陷阱（XML vs JSON）— 少寫 `moodlewsrestformat=json` 會 regression

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: 無 sesskey / HTML scrape 殘留
    Tool: Bash (rg)
    Steps:
      1. rg -n 'sesskey|SwiftSoup|<tr|<td|<table|parseHTML' swift/TigerDuck/Services/
      2. 預期：0 match（除非 inventory 明確保留；若保留，評論需 reference inventory 條目）
    Expected Result: 0 match 或明確 documented 保留
    Failure Indicators: sesskey 字串仍出現
    Evidence: .sisyphus/evidence/task-6-scrape-removed.txt

  Scenario: 所有 Moodle 網路呼叫走 /webservice/rest/server.php
    Tool: Bash (rg) + ast-grep
    Steps:
      1. rg -n 'moodle\.ntust\.edu\.tw/webservice/rest/server\.php' swift/TigerDuck/Services/Network/MoodleService.swift
      2. 預期：≥1 match（視 function 數量）
      3. rg -n 'moodle\.ntust\.edu\.tw' swift/TigerDuck/Services/Network/MoodleService.swift | grep -v 'webservice/rest/server.php'
      4. 預期：0（所有 Moodle URL 皆走 webservice）
    Expected Result: 所有呼叫在 webservice endpoint
    Evidence: .sisyphus/evidence/task-6-endpoints.txt

  Scenario: moodlewsrestformat=json 無遺漏
    Tool: Bash (rg)
    Steps:
      1. rg -n 'wsfunction=' swift/TigerDuck/Services/Network/MoodleService.swift
      2. 每個 wsfunction 出現處，同檔同附近應有 moodlewsrestformat=json
      3. rg -n 'moodlewsrestformat=json' swift/TigerDuck/Services/Network/MoodleService.swift
      4. count ≥ wsfunction 出現次數
    Expected Result: 全部 wsfunction 都帶 json format
    Failure Indicators: 任一 wsfunction 呼叫缺 moodlewsrestformat
    Evidence: .sisyphus/evidence/task-6-restformat.txt

  Scenario: errorcode 路徑正確分類
    Tool: Bash (rg)
    Steps:
      1. rg -n 'invalidtoken|accessexception' swift/TigerDuck/Services/Network/MoodleService.swift
      2. 預期：≥2 match（各 errorcode 至少一次）
      3. 檢查對應分支呼叫 `MoodleTokenService.shared.clearToken()`（搭配 ast-grep）
    Expected Result: invalidtoken / accessexception 觸發 clearToken
    Evidence: .sisyphus/evidence/task-6-error-map.txt

  Scenario: consumer API signature 未變
    Tool: Bash (git diff)
    Steps:
      1. git diff HEAD -- swift/TigerDuck/Services/Network/MoodleService.swift | rg -E '^-.*func (fetch|get)'
      2. 對每條被刪除的 public func，檢查是否在新版同檔或他檔被同 signature 重建
      3. 若 consumer 呼叫的方法名稱/參數有變 → 必須在 commit body 列出遷移計畫並留 T7 處理
    Expected Result: public API 契約兼容（或明確遷移紀錄）
    Evidence: .sisyphus/evidence/task-6-api-diff.txt

  Scenario: Compile pass
    Tool: Bash (xcodebuild)
    Steps:
      1. xcodebuild build ... -scheme TigerDuck ... -quiet 2>&1 | tee /tmp/xcb-t6.log
      2. exit 0
    Expected Result: compile 成功
    Evidence: .sisyphus/evidence/task-6-xcbuild.log
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-6-scrape-removed.txt`
  - [ ] `.sisyphus/evidence/task-6-endpoints.txt`
  - [ ] `.sisyphus/evidence/task-6-restformat.txt`
  - [ ] `.sisyphus/evidence/task-6-error-map.txt`
  - [ ] `.sisyphus/evidence/task-6-api-diff.txt`
  - [ ] `.sisyphus/evidence/task-6-xcbuild.log`

  **Commit**: YES（C4）
  - Message:
    ```
    refactor(Moodle): rewrite MoodleService on top of webservice REST

    - Replaces HTML/sesskey scrape with /webservice/rest/server.php calls
      authenticated by the Moodle webservice token from MoodleTokenService.
    - Maps Moodle errorcodes (invalidtoken, accessexception) to
      MoodleWebserviceError cases; invalid token triggers clearToken().
    - Drops the Moodle-only branch of SSOLoginService.ensureServiceLogin
      as documented in .sisyphus/evidence/moodle-inventory.md.
    - Public API of MoodleService preserved; consumer call sites unchanged.
    - Refs: #11
    ```
  - Files: `swift/TigerDuck/Services/Network/MoodleService.swift`, `swift/TigerDuck/Services/Network/SSOLoginService.swift`（若有刪減 Moodle 分支）, 可能新建 `swift/TigerDuck/Services/Network/MoodleWebserviceModels.swift`
  - Pre-commit: `xcodebuild build TigerDuck` + T6 AC 通過

- [x] 7. **Consumer ViewModels 串接新 MoodleService（若 signature 變動）**

  **What to do**:
  - 讀 Task 6 產出 `.sisyphus/evidence/task-6-api-diff.txt`，判定是否有 consumer 需要調整
  - 若 T6 保留 public API signature → 本 task 僅做**驗證性**工作：compile + lsp_diagnostics 確認無破損，不產 commit；合併入 C4
  - 若 T6 有 API 變動：
    - 開 `swift/TigerDuck/Bridge/KMPServiceBridge.swift`，找 `fetchAssignments(authService:)` 相關區塊，更新呼叫位置
    - 開 `swift/TigerDuck/Features/Calendar/CalendarViewModel.swift:76-104`，更新 `fetchMoodleEvents` 呼叫方式
    - **保留** `loginGeneration` snapshot / guard 邏輯（`KMPServiceBridge.swift:19-24, 134-137`）— 這是 race safety，不得刪
    - 若現有錯誤處理原本假設 HTML 層錯（例如 sesskey 取不到）→ 改為處理 `MoodleWebserviceError` cases
  - Widget target：
    - 若 T1c 回報 widget 有 Moodle 依賴 → 此 task 必須同步更新 widget 對應的讀取邏輯（且 widget 一併 compile pass）
    - 若 T1c 回報 widget 無 Moodle 依賴 → 不碰 widget code

  **Must NOT do**:
  - 不得刪除 `KMPServiceBridge` 的 `loginGeneration` race guard
  - 不得改 ViewModel 對外 public API（保持 UI 層無感）
  - 不得加入新的重試或降級邏輯
  - 若 T6 未改 API 則**不得**做任何「為改而改」的修改

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 只有在 T6 signature 變動時才有實質工作；否則是驗證為主。品質要求高（不能打破 race guard）
  - **Skills**: 無

  **Parallelization**:
  - **Can Run In Parallel**: YES（與 T8 同 wave）
  - **Parallel Group**: Wave 4
  - **Blocks**: T9
  - **Blocked By**: T6

  **References**:

  **Pattern References**:
  - `swift/TigerDuck/Bridge/KMPServiceBridge.swift:19-24` — `loginGeneration snapshot`（勿動）
  - `swift/TigerDuck/Bridge/KMPServiceBridge.swift:134-137` — post-fetch generation check（勿動）
  - `swift/TigerDuck/Features/Calendar/CalendarViewModel.swift:76-104` — `fetchMoodleEvents`
  - `swift/TigerDuckLiveActivity/` — 若 T1c 判定有耦合才需動

  **API/Type References**:
  - `MoodleWebserviceError`（由 T3 定義）— consumer 若要處理錯誤需 import

  **WHY Each Reference Matters**:
  - Race guard 是既有正確機制，重寫時最容易被誤刪 — 必須顯式保留
  - Calendar 與 KMPServiceBridge 是唯二的 primary consumer；範圍邊界清楚

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: race guard 保留
    Tool: Bash (rg)
    Steps:
      1. rg -n 'loginGeneration' swift/TigerDuck/Bridge/KMPServiceBridge.swift
      2. 預期：≥2 match（snapshot + post-check）
      3. git diff HEAD -- swift/TigerDuck/Bridge/KMPServiceBridge.swift | rg '^-.*loginGeneration'
      4. 預期：0（未刪 race guard）
    Expected Result: race guard 完整保留
    Failure Indicators: loginGeneration 被刪或簡化
    Evidence: .sisyphus/evidence/task-7-race-guard.txt

  Scenario: Widget compile（若 T1c 判定需動）
    Tool: Bash (xcodebuild)
    Preconditions: 讀 .sisyphus/evidence/widget-moodle-audit.md 決定是否執行
    Steps:
      1. 若 audit 是 NO_COUPLING：跳過此 scenario，僅跑 TigerDuck scheme 即可
      2. 若 HAS_COUPLING：
         xcodebuild build -project swift/TigerDuck.xcodeproj \
           -scheme TigerDuckLiveActivityExtension \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet 2>&1 | tee /tmp/xcb-t7-widget.log
         預期 exit 0
    Expected Result: widget compile（若適用）
    Evidence: .sisyphus/evidence/task-7-widget-xcbuild.log 或 task-7-widget-skipped.txt

  Scenario: Compile pass（app）
    Tool: Bash (xcodebuild)
    Steps:
      1. xcodebuild build ... -scheme TigerDuck ... -quiet 2>&1 | tee /tmp/xcb-t7.log
      2. exit 0
    Expected Result: compile 成功
    Evidence: .sisyphus/evidence/task-7-xcbuild.log

  Scenario: 無 consumer 呼叫殘留舊 API（if applicable）
    Tool: Bash (rg)
    Steps:
      1. 針對 T6 移除的方法名稱（見 task-6-api-diff.txt）逐一 rg
      2. 每個應為 0 match（除非是在 MoodleService.swift 自身的註解 / doc）
    Expected Result: consumer 全部 migrate
    Evidence: .sisyphus/evidence/task-7-consumer-migration.txt
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-7-race-guard.txt`
  - [ ] `.sisyphus/evidence/task-7-widget-xcbuild.log` 或 `task-7-widget-skipped.txt`
  - [ ] `.sisyphus/evidence/task-7-xcbuild.log`
  - [ ] `.sisyphus/evidence/task-7-consumer-migration.txt`

  **Commit**: 條件式
  - 若 T6 API 無變動：不產生新 commit，只驗證 → 合併入 C4
  - 若 T6 API 有變動：C5
    ```
    refactor(Calendar): adapt consumers to new MoodleService API

    - Updates KMPServiceBridge.fetchAssignments and
      CalendarViewModel.fetchMoodleEvents to match MoodleService's
      webservice-based return types.
    - loginGeneration race guard preserved verbatim.
    - Widget target updated (if applicable per widget-moodle-audit).
    - Refs: #11
    ```
  - Pre-commit: app + widget compile pass

- [x] 8. **Logout cascade 檢查 + DataCache 互動驗證**

  **What to do**:
  - 讀 `swift/TigerDuck/App/AppState.swift:145-160`（`logoutNTUST()` 實作）
  - 驗證 logout 事件鏈順序正確：
    1. cancel in-flight sync tasks
    2. `authService.logout()`（此處現在會觸發 `MoodleTokenService.clearToken()` fire-and-forget — 來自 T5）
    3. `DataCache.shared.clearUserScopedData()`
    4. Live Activity end
    5. `loginGeneration` bumped（在 `authService.logout()` 內）
  - 若 T5 已正確串接 `MoodleTokenService.clearToken()` 且 T4 已把 moodleToken keys 加入 fresh-install purge — 此 task 多半是**純驗證**性工作（compile + rg）
  - 若驗證發現缺口（例如：logout 未能清乾淨 Moodle 殘留 state），補上最小修正
  - 加上一份 diagnostic markdown `.sisyphus/evidence/task-8-logout-sequence.md` 記錄完整事件鏈與每步驗證

  **Must NOT do**:
  - 不得改 `logoutNTUST` 的整體序列（僅在發現 bug 時才補）
  - 不得刪 `DataCache.clearUserScopedData()` 呼叫
  - 不得改 Live Activity 呼叫時序

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 多為檢查性工作；若 T4/T5 做得正確則近乎無改動

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4
  - **Blocks**: T9
  - **Blocked By**: T5

  **References**:
  - `swift/TigerDuck/App/AppState.swift:145-160` — `logoutNTUST()`
  - `swift/TigerDuck/Services/Auth/AuthService.swift:135-144` — `logout()` 已被 T5 擴充
  - `swift/TigerDuck/Services/Network/DataCache.swift:106-114` — `clearUserScopedData()` 清單

  **WHY Each Reference Matters**:
  - logout 事件鏈是安全關鍵；任何 race 都會讓舊用戶資料殘留或新 Moodle token 未清
  - 藉由靜態序列檢查（雖不跑 simulator）仍可藉 read 確認順序正確

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: logout 事件鏈完整
    Tool: Bash (rg) + Read
    Steps:
      1. rg -n 'logoutNTUST\(|authService\.logout\(|clearUserScopedData\(|MoodleTokenService\.shared\.clearToken' swift/TigerDuck/App/AppState.swift swift/TigerDuck/Services/Auth/AuthService.swift
      2. 驗證呼叫存在於預期位置
      3. Read AppState.swift logoutNTUST 片段並記錄順序至 .sisyphus/evidence/task-8-logout-sequence.md
    Expected Result: 順序符合「cancel → authLogout → clearCache → LA end → gen++」
    Evidence: .sisyphus/evidence/task-8-logout-sequence.md

  Scenario: 無 stale Moodle 資料殘留路徑
    Tool: Bash (rg)
    Steps:
      1. rg -n 'moodleToken|MoodleToken' swift/TigerDuck/App/AppState.swift swift/TigerDuck/Services/Auth/AuthService.swift swift/TigerDuck/Services/Auth/MoodleTokenService.swift
      2. 三處皆應有清除路徑（fresh-install purge / logout / clearToken）
    Expected Result: 三處 clear 點齊全
    Evidence: .sisyphus/evidence/task-8-clear-paths.txt

  Scenario: Compile pass（若有任何補修）
    Tool: Bash (xcodebuild)
    Steps:
      1. xcodebuild build ... -scheme TigerDuck ... -quiet 2>&1 | tee /tmp/xcb-t8.log
      2. exit 0
    Expected Result: compile 成功
    Evidence: .sisyphus/evidence/task-8-xcbuild.log
  ```

  **Evidence to Capture**:
  - [ ] `.sisyphus/evidence/task-8-logout-sequence.md`
  - [ ] `.sisyphus/evidence/task-8-clear-paths.txt`
  - [ ] `.sisyphus/evidence/task-8-xcbuild.log`

  **Commit**: 條件式 — 僅在發現缺口並補修時才產 C6
  - Message（若有改動）：
    ```
    fix(Auth): ensure Moodle token is cleared in every logout path

    - Adds missing clearToken invocation discovered during logout sequence
      audit (see .sisyphus/evidence/task-8-logout-sequence.md).
    - Refs: #11
    ```
  - 若無改動：不 commit；只把 evidence 併入 PR description

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents 並行跑。**所有 APPROVE 後把結果整理給使用者，等使用者明確「okay」再結束**；未得使用者同意前 F1–F4 不可打勾。使用者提出修正則 fix → 重跑 → 再呈現。

- [x] F1. **計畫合規 audit** — `oracle`
  讀 plan.md end-to-end。逐項檢查「Must Have」與「Must NOT Have」：
  - Must Have：存在性驗證（`rg`/`ast-grep`/檔案存在/compile pass）
  - Must NOT Have：負面搜尋（出現即 REJECT 附 file:line）
  - 核對 evidence 目錄（`.sisyphus/evidence/probe-result.json`, `moodle-inventory.md`, `isNTUSTLoggedIn-callers.txt`, `widget-moodle-audit.md` 等皆存在非空）
  - 對照 deliverables 清單（7 個檔案變更/新建 + 4 個 evidence）
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Evidence [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [x] F2. **Swift code 品質 / AI slop 檢查** — `unspecified-high`
  - 跑 `lsp_diagnostics(filePath="swift/TigerDuck/", severity="error")` 全樹 0 error
  - 新增檔案 (`MoodleTokenService.swift`, `MoodleWebserviceError.swift`, `MoodleTokenMigration.swift`) 檢查 AI slop：
    - `ast-grep --lang swift --pattern 'as! $_'` → 0（禁用強制轉型）
    - `ast-grep --lang swift --pattern 'try! $_'` → 0
    - `rg -n 'fatalError|preconditionFailure|assertionFailure'` → 0
    - `rg -n '// TODO|// FIXME|// XXX'` → 0
    - 無 generic `<T>` 容器類別（Metis 指名 anti-pattern）
    - 無 protocol `MoodleTokenProviding` / `TokenRefreshCoordinator`（Metis 點名禁止）
    - 無 `UserDefaults.*set.*forKey.*token`（token 不可存 UserDefaults）
    - 無 log 洩漏（`rg -n 'print|NSLog|os_log' <新檔>` 檢查後確認未 log token/privateToken 值）
    - 無多餘註解（`// 設置 token 為 input` 這類贅述）
    - 函式命名簡潔（非 `MoodleWebserviceTokenExchangeManagerFactory`）
  - **Migration 隔離**：
    - `rg -n 'MoodleTokenMigration|Services/Migrations' swift/TigerDuck/Services/Auth/AuthService.swift swift/TigerDuck/Services/Network/MoodleService.swift swift/TigerDuck/Services/Auth/MoodleTokenService.swift` → 0（feature service 零污染）
    - `test -f swift/TigerDuck/Services/Migrations/AGENTS.md` → exit 0
    - `wc -c swift/TigerDuck/Services/Migrations/AGENTS.md` → ≥ 500 bytes
    - `rg -n 'presentNTUSTLogin|alert\(|Alert\(' swift/TigerDuck/Services/Migrations/` → 0（migration 不彈 UI）
  - 所有 commit 皆 GPG 簽章：`git log --show-signature origin/dev..HEAD | grep -c 'Good signature'` == commit 數
  - commit 無 `Co-Authored-By`：`git log --format='%B' origin/dev..HEAD | grep -c 'Co-Authored-By'` == 0
  - commit 格式：`git log --format='%s' origin/dev..HEAD | grep -vE '^(feat|fix|refactor|chore)\([A-Za-z]+\): '` == 空
  Output: `Build [PASS/FAIL] | LSP errors [0/N] | AI-slop [PASS/N issues] | Commits [N signed, N bad format] | VERDICT`

- [x] F3. **靜態 QA 驗證** — `unspecified-high`
  對 T0–T10 每個任務的 Acceptance Criteria 裡的 shell 命令實際執行一次，比對預期輸出：
  - T0 probe evidence JSON schema
  - T1a/T1b/T1c evidence 檔存在且內容合理
  - T2 `rg -n 'appState\.isNTUSTLoggedIn' swift/TigerDuck/Features/Settings/` → 0
  - T3 `ast-grep` 確認 actor 結構
  - T4 `rg -n 'moodleToken'` 確認 key 與 purge 都有
  - T5 `rg -n 'obtainToken\|clearToken' swift/TigerDuck/Services/Auth/AuthService.swift` 確認串接
  - T6 `rg -n 'sesskey|SwiftSoup' swift/TigerDuck/Services/` → 0
  - T7 consumer side 確認沒有直接呼 scrape 方法
  - T9 compile matrix（app + widget）
  - T10 最終 sweep
  結果寫入 `.sisyphus/evidence/final-qa/F3-report.md`。
  Output: `AC commands [N/N pass] | Mismatches [list] | VERDICT`

- [x] F4. **範圍忠實度檢查** — `deep`
  對每個任務：讀「What to do」、讀實際 `git diff` 與新增檔案。驗證 1:1：
  - spec 要求的全部做了（無遺漏）
  - spec 以外的沒做（無 creep）
  - 「Must NOT do」遵守
  - 沒有跨 task 污染（T3 只應碰 `MoodleTokenService`/`MoodleWebserviceError`；T2 只碰 `SettingsView` 相關；等等）
  - 無未列入計畫的檔案變更（`git diff --name-only origin/dev..HEAD` 逐一比對計畫中提到的檔案）
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

每個 commit 由一個或多個緊密相關的實作任務產出；**GPG 簽章**；**不帶 `Co-Authored-By` 行**；中英文訊息視情況，但格式統一 `type(scope): short description`。

| # | Scope | 對應任務 | 關鍵檔案 | Pre-commit gate |
|---|------|---------|----------|-----------------|
| C1 | `fix(Settings)` | T2 | `SettingsView.swift` | `xcodebuild build TigerDuck` |
| C2 | `feat(MoodleAuth)` | T3, T4 | `MoodleTokenService.swift`, `MoodleWebserviceError.swift`, `AppConstants.swift`, `AppState.swift` (purge 區塊) | `xcodebuild build TigerDuck` |
| C3 | `feat(Auth)` | T5 | `AuthService.swift`（純 login/logout 串接） | `xcodebuild build TigerDuck` |
| C3b | `feat(Migrations)` | T5b | `Services/Migrations/AGENTS.md`, `MoodleTokenMigration.swift`, `AppDefaults.swift`, `AppState.swift`（`runPendingMigrations` + init 呼叫） | `xcodebuild build TigerDuck` |
| C4 | `refactor(Moodle)` | T6 | `MoodleService.swift`, 可能刪除 `SSOLoginService` 中純為 Moodle 用的分支 | `xcodebuild build TigerDuck` |
| C5 | `refactor(Calendar)` | T7 | `CalendarViewModel.swift`, `KMPServiceBridge.swift`（若有涉及） | `xcodebuild build TigerDuck` + `xcodebuild build TigerDuckLiveActivityExtension` |
| C6 | `fix(Auth)` | T8 | `AuthService.swift`（logout cascade），或 `AppState.swift` | `xcodebuild build TigerDuck` |

**Commit 訊息範本**：
```
feat(MoodleAuth): add MoodleTokenService with actor-based token exchange

- Introduces POST /login/token.php?service=moodle_mobile_app flow
- Persists token via KeychainManager using new KeychainKeys.moodleToken
- Actor serialization prevents concurrent token exchanges
- Refs: #11
```

**Discovery / verification tasks（T0, T1a–e, T9, T10, F1–F4）不產生 commit**，只產生 `.sisyphus/evidence/` 內的紀錄檔。

---

## Success Criteria

### Verification Commands

```bash
# 1. app 主目標 compile
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
# expect: exit 0

# 2. widget 目標 compile
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuckLiveActivityExtension \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
# expect: exit 0

# 3. Settings 已移除不穩定 binding
rg -n 'appState\.isNTUSTLoggedIn' swift/TigerDuck/Features/Settings/
# expect: empty output

# 4. 無殘留 Moodle HTML scrape
rg -n 'sesskey|SwiftSoup|<tr|<td' swift/TigerDuck/Services/
# expect: empty output (or 單一 Task 1a 明確保留之條目)

# 5. Keychain keys 已加入 fresh-install purge
rg -n 'moodleToken' swift/TigerDuck/App/AppState.swift swift/TigerDuck/App/AppConstants.swift
# expect: ≥3 matches（AppConstants 定義 2 個 + AppState purge 1+ 次）

# 6. 所有 commit GPG 簽章
git log --show-signature origin/dev..HEAD 2>&1 | grep -c 'Good signature'
# expect: == commit count (6)

# 7. 無 Co-Authored-By
git log origin/dev..HEAD --format='%B' | grep -c 'Co-Authored-By'
# expect: 0

# 8. commit format
git log origin/dev..HEAD --format='%s' | grep -vE '^(feat|fix|refactor|chore)\([A-Za-z]+\): '
# expect: empty output

# 9. Moodle token 不存 UserDefaults
ast-grep --lang swift --pattern 'UserDefaults.standard.set($_, forKey: $KEY)' swift/TigerDuck/Services/Auth/MoodleTokenService.swift
# expect: 0 matches

# 10. Migrations/ 資料夾與 AGENTS.md 到位
test -d swift/TigerDuck/Services/Migrations && \
test -f swift/TigerDuck/Services/Migrations/AGENTS.md && \
test -f swift/TigerDuck/Services/Migrations/MoodleTokenMigration.swift
# expect: all checks pass (exit 0)

# 11. Feature service 零 migration 污染
rg -n 'MoodleTokenMigration|Services/Migrations' swift/TigerDuck/Services/Auth/AuthService.swift swift/TigerDuck/Services/Network/MoodleService.swift swift/TigerDuck/Services/Auth/MoodleTokenService.swift
# expect: empty output

# 12. LSP 全樹無 error
# 透過 lsp_diagnostics(filePath="swift/TigerDuck/", severity="error") 呼叫回傳 []
```

### Final Checklist

- [ ] Task 0 probe 結果為 PASS 才進入後續；若為任一 FAIL 狀態，plan halt 並把 `.sisyphus/evidence/probe-result.json` 連同診斷摘要呈現給使用者
- [ ] 所有「Must Have」項目 present
- [ ] 所有「Must NOT Have」項目 absent
- [ ] compile 雙目標皆 exit 0
- [ ] 每個 commit 都 GPG 簽章通過、無 Co-Authored-By、格式合規
- [ ] F1–F4 四位 reviewer 皆 APPROVE
- [ ] 使用者明確回覆 okay
