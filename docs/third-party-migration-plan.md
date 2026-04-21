# TigerDuck 第三方庫導入遷移計畫

> 版本：2026-04-18
> 目標：將目前全手刻的核心元件逐步替換為業界成熟庫，以降低維護負擔、減少邊界案例 bug、提升可觀測性。
> 策略：**每個庫獨立一個分支**，完整閉環（導入 → 遷移 → 驗證 → 合併 → 觀察）。

---

## 目錄

- [總體原則](#總體原則)
- [遷移項目總表](#遷移項目總表)
- [① Keychain 升級 → Valet](#-keychain-升級--valet)
- [② HTML 解析 → SwiftSoup](#-html-解析--swiftsoup)
- [③ 網路層 → Alamofire](#-網路層--alamofire)
- [④ Crash / Error 監控 → Sentry](#-crash--error-監控--sentry)
- [⑤ 版本更新提醒 → Siren](#-版本更新提醒--siren)
- [⑥ Release Notes → WhatsNewKit](#-release-notes--whatsnewkit)
- [⑦ UserDefaults 型別安全 → Defaults](#-userdefaults-型別安全--defaults)
- [⑧ 開發期網路除錯 → Pulse](#-開發期網路除錯--pulse-僅-debug-build)
- [⑨ 圖片快取 → Nuke（可選）](#-圖片快取--nuke可選)
- [不建議更換的元件](#不建議更換的元件)
- [附帶發現：架構債](#附帶發現架構債)
- [建議執行順序](#建議執行順序)

---

## 總體原則

1. **一個庫一個分支**，命名：`feature/lib-<名稱>`（例：`feature/lib-valet`）
2. **每個分支獨立 PR**，不合併別的庫
3. **每次遷移保留舊介面 shim 一個版本**：例如 `KeychainManager.saveString(...)` 先改成呼叫 Valet，再用幾天確認沒問題，下個 PR 才移除 shim
4. **不動業務邏輯**：只替換底層實作，上層 Service / ViewModel 不變
5. **測試優先**：每個遷移 PR 都要附一份「人工驗證清單」；有單元測試更好
6. iOS 最低版本：本 App 用了 `@Observable`（iOS 17+），以下所有庫都至少支援 iOS 17

---

## 遷移項目總表

| # | 項目 | 建議庫 | 分支名稱 | 優先級 | 風險 |
|---|------|--------|----------|--------|------|
| ① | Keychain wrapper | **Valet** | `feature/lib-valet` | 🔴 高 | 低 |
| ② | HTML parser | **SwiftSoup** | `feature/lib-swiftsoup` | 🔴 高 | 中（SSO 流程改動） |
| ③ | 網路層 | **Alamofire** | `feature/lib-alamofire` | 🔴 高 | 中 |
| ④ | Crash 監控 | **Sentry** | `feature/lib-sentry` | 🟡 中 | 低 |
| ⑤ | 版本更新提醒 | **Siren** | `feature/lib-siren` | 🟡 中 | 低 |
| ⑥ | Release notes | **WhatsNewKit** | `feature/lib-whatsnewkit` | 🟡 中 | 低 |
| ⑦ | UserDefaults | **Defaults** (Sindre) | `feature/lib-defaults` | 🟢 低 | 低 |
| ⑧ | 網路除錯 | **Pulse** | `feature/lib-pulse` | 🟢 低 | 低（僅 Debug） |
| ⑨ | 圖片快取 | **Nuke** | `feature/lib-nuke` | 🟢 低 | 低 |

---

## ① Keychain 升級 → Valet

- **分支**：`feature/lib-valet`
- **庫**：[Square/Valet](https://github.com/square/Valet)
- **理由**：類型安全、Access Group 支援（Live Activity 共用憑證）、Accessibility 細緻控制、Square 持續維護

### 現況

**檔案**：`swift/TigerDuck/Services/Auth/KeychainManager.swift`

目前是 `enum KeychainManager` 提供五個靜態函數：

- `save(key:data:)` — 直接 `SecItemDelete` + `SecItemAdd`，沒處理錯誤
- `load(key:)` — `SecItemCopyMatching`，錯誤靜默吞掉
- `delete(key:)`
- `loadString(key:)` / `saveString(key:value:)`

**問題**：
1. 沒設定 `kSecAttrAccessible`（預設 `.whenUnlocked` → App 背景啟動讀不到 → Live Activity 背景更新可能失敗）
2. 沒有 access group → **Live Activity Extension 無法共用憑證**（目前可能繞過這問題但未來會卡）
3. 所有錯誤被吞掉，使用者看不到「Keychain 寫失敗」
4. 沒有命名空間，多個 app / extension 共用同一個 key 會衝突

**呼叫方**：
- `Services/Auth/AuthService.swift`
  - `storedStudentId` / `storedPassword` (computed)
  - `login(studentId:password:)`
  - `logout()`
- `Services/Network/LibraryService.swift`
  - `storedUsername`, `storedToken`, `storedTokenExpiry`
  - `saveCredentials(username:password:)`, `clearCredentials()`
  - `saveToken(_:expirationMs:)`, `clearToken()`
  - `ensureToken()`
- `App/AppConstants.swift` 應該有 `KeychainKeys` 常數定義

### 建議實作

新檔：`swift/TigerDuck/Services/Auth/SecureStore.swift`

```swift
import Valet

enum SecureStore {
    // 一般 app 本體用
    static let shared: Valet = .valet(
        with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
        accessibility: .afterFirstUnlock
    )

    // App Group 共享（Live Activity Extension 要讀憑證時用）
    static let shared群組: Valet = .sharedGroupValet(
        with: SharedGroupIdentifier(appIDPrefix: "<TEAM_ID>", nonEmptyGroup: "group.org.ntust.app.TigerDuck")!,
        accessibility: .afterFirstUnlock
    )
}
```

保留 `KeychainManager` 作 shim（一個版本後移除）：

```swift
enum KeychainManager {
    static func saveString(key: String, value: String) {
        try? SecureStore.shared.setString(value, forKey: key)
    }
    static func loadString(key: String) -> String? {
        try? SecureStore.shared.string(forKey: key)
    }
    // ...
}
```

### 遷移步驟

1. Xcode → File → Add Package Dependencies → `https://github.com/square/Valet`
2. 新增 `SecureStore.swift`
3. 把 `KeychainManager` 內部改為委派給 `SecureStore`（上層呼叫不變）
4. 人工驗證（見下）
5. 下個 PR 移除 `KeychainManager` shim，全部改直接用 `SecureStore`

### 驗證清單

- [ ] 乾淨裝：登入 NTUST → 殺 app → 重開 → 仍已登入
- [ ] 登入後切到背景 → iPhone 重啟（模擬背景解鎖前啟動）→ 開 app → 憑證可讀
- [ ] 登出 → 所有 keychain items 確實被清除（用 Keychain Dump 工具檢查）
- [ ] 圖書館憑證儲存、QR 產生正常
- [ ] Live Activity 若有讀 keychain 仍然正常

### 風險

- Access Group 若設錯會導致 Extension 讀不到憑證 → 先在模擬器驗證
- **不要**同時遷移 keychain 又改變 key 名稱，否則現有使用者會被登出

---

## ② HTML 解析 → SwiftSoup

- **分支**：`feature/lib-swiftsoup`
- **庫**：[scinfu/SwiftSoup](https://github.com/scinfu/SwiftSoup)
- **理由**：NTUST 的 HTML 用 regex 解是定時炸彈；SwiftSoup 是純 Swift 實作的 jsoup port，無 C 依賴

### 現況

**主檔案**：`swift/TigerDuck/Services/Network/HTMLParser.swift`

目前是 `enum HTMLParser`，提供：

- `struct FormData { action, inputs }`
- `isSSOLoginPage(html:url:)` — 用 `html.contains("id=\"loginForm\"")` 判斷
- `findFormById(_:id:)` — 動態組 regex 抓 `<form id="xxx">`
- `findOIDCBridgeForm(_:)` — 走完所有 form、用 regex 抽 name/value，再用集合比對判斷是不是 OIDC 的跳板 form
- `extractInputFields(_:)` — regex 抓所有 `<input>` 的 name/value

此外還有**散落在別處的 HTML 正則**：

- `Services/Network/MoodleService.swift` → `sesskeyRegex` 抽 Moodle 的 `"sesskey":"..."`（這其實不是 HTML，是嵌在 JS 裡的，可以保留 regex）
- `Features/Announcements/Components/AnnouncementDetailView.swift` → `HTMLContentView` 用 `NSAttributedString` 解公告 HTML

**呼叫方**：
- `Services/Network/SSOLoginService.swift` 整個 SSO 流程仰賴這個 parser
- `Services/Network/AuthService.swift` 間接仰賴

**風險點**：
- NTUST SSO / Moodle 前端任何一次改版（空格、屬性順序、加新 attribute）都可能讓 regex miss
- `findFormById` 每次呼叫都動態編譯 regex（效能次要，但 API 設計不夠好）

### 建議實作

替換檔：`swift/TigerDuck/Services/Network/HTMLParser.swift`

```swift
import SwiftSoup

enum HTMLParser {
    struct FormData {
        let action: String
        let inputs: [(name: String, value: String)]
    }

    static func isSSOLoginPage(html: String, url: URL) -> Bool {
        guard url.host?.contains("ssoam2.ntust.edu.tw") == true else { return false }
        guard let doc = try? SwiftSoup.parse(html) else { return false }
        return (try? doc.select("form#loginForm").first()) != nil
            || ((try? doc.select("input[name=Username]").first()) != nil
                && (try? doc.select("input[name=Password]").first()) != nil)
    }

    static func findFormById(_ html: String, id: String) -> FormData? {
        guard let doc = try? SwiftSoup.parse(html),
              let form = try? doc.select("form#\(id)").first() else { return nil }
        return formData(from: form)
    }

    static func findOIDCBridgeForm(_ html: String) -> FormData? {
        guard let doc = try? SwiftSoup.parse(html),
              let forms = try? doc.select("form") else { return nil }
        for form in forms.array() {
            guard let data = formData(from: form) else { continue }
            if data.action.lowercased().contains("logout") || data.action.isEmpty { continue }
            let names = Set(data.inputs.map(\.name))
            if names.contains("Username") || names.contains("Password") { continue }

            let isOIDC = (names.contains("code") && names.contains("state") && names.contains("iss"))
                || names.contains("id_token")
                || names.contains("SAMLResponse")
                || names.contains("RelayState")
                || names.contains("wresult")
                || names.contains("wctx")

            if isOIDC { return data }
        }
        return nil
    }

    private static func formData(from form: Element) -> FormData? {
        guard let action = try? form.attr("action") else { return nil }
        guard let inputs = try? form.select("input").array() else { return nil }
        let pairs: [(String, String)] = inputs.compactMap { input in
            guard let name = try? input.attr("name"), !name.isEmpty else { return nil }
            let value = (try? input.attr("value")) ?? ""
            return (name, value)
        }
        return FormData(action: action, inputs: pairs)
    }
}
```

### 遷移步驟

1. 加入 SwiftSoup SPM
2. 替換 `HTMLParser.swift` 內容（介面不變）
3. **不**動 `MoodleService.sesskeyRegex`（那是解 JS 不是 HTML）
4. 單元測試：用 fixture HTML（存在 repo 裡）跑 `SSOLoginService.ensureServiceLogin` 全流程
5. 人工驗證全套登入流程

### 驗證清單

- [ ] 乾淨狀態登入 NTUST → 成功
- [ ] 登入後 cookie 過期 → 自動重認證 → 成功
- [ ] Moodle 作業拉取 → 正常
- [ ] 圖書館登入 → 正常
- [ ] SSO 錯誤密碼 → 顯示正確錯誤訊息
- [ ] 同時開兩個 service（課表 + Moodle）→ 都成功

### 風險

- SwiftSoup 對非常破碎的 HTML 的解析行為可能跟 regex 不同 → 若 NTUST 回傳非標準 HTML 要額外測
- 建議在 `SSOLoginService` 裡加 log，記錄每次 form 解析結果 → Sentry 可抓

---

## ③ 網路層 → Alamofire

- **分支**：`feature/lib-alamofire`
- **庫**：[Alamofire/Alamofire](https://github.com/Alamofire/Alamofire)
- **理由**：統一 cookie 自動重認證、retry policy、request adapter、logging hook

### 現況

**目前架構**：單例 `NTUSTSessionManager.shared.session: URLSession`，每個 Service 拿這個 session 手刻 `URLRequest`

**相關檔案**：
- `Services/Network/NTUSTSessionManager.swift` — 管 cookie、TTL、User-Agent
- `Services/Network/SSOLoginService.swift` — SSO 登入流程，`ensureServiceLogin(session:serviceURL:studentId:password:)`
- `Services/Network/MoodleService.swift` — `fetchAssignments(...)`
- `Services/Network/LibraryService.swift` — `login`, `ensureToken`, `generateQRCode`
- `Services/Network/CalendarService.swift`
- `Services/Network/CourseService.swift`

**問題**：
1. **sesskey 過期重認證**邏輯硬編碼在 `MoodleService.fetchAssignments` 內（try 一次 → 抽 sesskey → 抽不到就重登 → 再試一次），這種 pattern 應該是 interceptor
2. 每個 service 都要判斷 `NTUSTSessionManager.cookiesValid` 決定要不要先登入
3. 沒有統一 log（Alamofire 有 `EventMonitor` / 搭配 Pulse 完美）
4. 沒有 retry policy
5. timeout、header 綁在 session config，要改得改全體

### 建議架構

新檔：`Services/Network/APIClient.swift`

```swift
import Alamofire

final class APIClient {
    static let shared = APIClient()

    let ntust: Session
    let library: Session

    private init() {
        let ntustConfig = URLSessionConfiguration.default
        ntustConfig.httpCookieStorage = HTTPCookieStorage.shared
        ntustConfig.timeoutIntervalForRequest = 15
        ntustConfig.httpAdditionalHeaders = [
            "User-Agent": NTUSTSessionManager.browserUserAgent,
            "Accept-Language": "zh-TW,zh;q=0.9",
        ]

        self.ntust = Session(
            configuration: ntustConfig,
            interceptor: NTUSTAuthInterceptor(),
            eventMonitors: [NTUSTEventMonitor()]
        )

        self.library = Session() // 簡單、無 cookie
    }
}

/// 拉通 SSO 過期自動重認證的閉環 — 所有 NTUST request 經過這裡
final class NTUSTAuthInterceptor: RequestInterceptor {
    func retry(_ request: Request, for session: Session, dueTo error: Error,
               completion: @escaping (RetryResult) -> Void) {
        // 只對 SSO 登入頁跳轉 / 401 類錯誤做重登
        guard let response = request.task?.response as? HTTPURLResponse,
              response.statusCode == 401 || /* 偵測 SSO 跳轉 */ false,
              request.retryCount < 1 else {
            return completion(.doNotRetry)
        }

        Task {
            let ok = await AppState.shared.authService.ensureAuthenticated()
            completion(ok ? .retry : .doNotRetry)
        }
    }
}
```

### 遷移步驟

**建議分兩個 PR**（此分支 / 合併後再開第二個分支 `feature/lib-alamofire-interceptor`）：

**PR 1**：引入 Alamofire，純替換底層
- 加入 Alamofire
- 把各 service 的 `session.data(for: request)` 改成 `session.request(...).serializingDecodable(T.self).value`
- 介面不變、行為不變、不加 interceptor
- 這一步可以單獨合併，風險最低

**PR 2**：加入 `NTUSTAuthInterceptor`
- 把 `MoodleService` 裡 sesskey 重登邏輯移到 interceptor
- 移除各 service 裡對 `cookiesValid` 的判斷
- 這步風險較高，單獨一個 PR

### 驗證清單

- [ ] 所有現有登入 / 資料拉取流程功能完全一致
- [ ] cookie 過期時自動重登（不要求使用者重輸入密碼）
- [ ] 密碼錯誤時 → 不要無限 retry → 顯示錯誤
- [ ] 離線狀態 → `NetworkMonitor` 顯示離線提示，不要重試到死
- [ ] Request timeout 仍是 15 秒

### 風險

- Alamofire 對 redirect 的預設行為跟 URLSession 不完全相同 → SSO 跳轉流程要特別測
- `httpShouldSetCookies` 在 Alamofire 裡預設行為要確認
- interceptor 的 retry 邏輯若寫錯會造成**無限重試**風暴 → 一定要加 `retryCount < 1` 守衛

---

## ④ Crash / Error 監控 → Sentry

- **分支**：`feature/lib-sentry`
- **庫**：[Sentry Cocoa SDK](https://github.com/getsentry/sentry-cocoa)
- **理由**：你**還沒上 Firebase**，Sentry 獨立、免費額度夠用、對 error context 的捕捉比 Crashlytics 更完整

### 現況

**幾乎沒有任何錯誤監控**。

已有的 `os.Logger` 使用僅在：
- `LiveActivity/Scheduling/AssignmentReminderScheduler.swift`
- `LiveActivity/Runtime/SharedSnapshotStore.swift`
- `LiveActivity/Runtime/LiveActivityCoordinator.swift`

**完全沒有**：
- Crash 回報
- 業務錯誤（登入失敗、API 失敗）的遠端觀測
- Breadcrumb（發生錯誤前的使用者路徑）
- Performance trace

### 建議實作

1. 註冊 Sentry 帳號，建立 iOS 專案，拿 DSN
2. `TigerDuckApp.swift` init 時啟動：

```swift
import Sentry

@main
struct TigerDuckApp: App {
    init() {
        SentrySDK.start { options in
            options.dsn = "<DSN>"
            options.debug = false
            options.tracesSampleRate = 0.2  // 20% 交易取樣
            options.profilesSampleRate = 0.1
            options.enableAutoPerformanceTracing = true
            options.attachScreenshot = true
            options.attachViewHierarchy = true
            // 注意：不要把 PII 上傳（studentId / 密碼）
            options.sendDefaultPii = false
        }
        // ...
    }
}
```

3. 建立 `Services/Logging/AppLogger.swift`：

```swift
import Sentry
import os

enum AppLogger {
    static let auth = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Auth")
    static let network = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Network")
    static let moodle = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Moodle")

    static func captureError(_ error: Error, context: [String: Any] = [:]) {
        SentrySDK.capture(error: error) { scope in
            for (k, v) in context { scope.setExtra(value: v, key: k) }
        }
    }

    static func breadcrumb(_ message: String, category: String, level: SentryLevel = .info) {
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }
}
```

4. 把 `try?` / `catch` 吞錯誤的地方改為 `AppLogger.captureError(error)`

**優先上報點**：
- `AuthService.login` 失敗
- `SSOLoginService.ensureServiceLogin` 失敗
- `MoodleService.fetchAssignments` 失敗
- `DataCache` 的 `try?` 寫入失敗（資料遺失前兆）
- `HTMLParser.findFormById` 回 nil（SSO 頁面改版訊號）

### 遷移步驟

1. 加入 Sentry SDK
2. 註冊 DSN、寫入 `TigerDuckApp.init`
3. 建立 `AppLogger`
4. 把關鍵錯誤點改為回報（一次改 10~15 個，分 commit）
5. Release 前確認**不要上報 PII**（studentId / 密碼 / 身份證字號）

### 驗證清單

- [ ] 故意觸發 crash（測試按鈕）→ Sentry dashboard 有收到
- [ ] 登入錯誤密碼 → Sentry 有 error 記錄（但密碼不在 payload 裡）
- [ ] App 首頁停留 10 秒 → Sentry 有 transaction
- [ ] Release build 關閉 debug mode

### 風險

- **隱私**：絕對不能把學號 / 密碼 / Cookie 上傳 → 寫一個 `beforeSend` scrubber
- **Sample rate** 別設 1.0（免費額度很快會爆）

### PII 過濾器（必寫）

```swift
options.beforeSend = { event in
    // 移除可能含密碼的 request body
    event.request?.data = nil
    // 把 URL query string 裡的 token scrub 掉
    if let url = event.request?.url {
        event.request?.url = url.replacingOccurrences(
            of: #"token=[^&]+"#, with: "token=***", options: .regularExpression)
    }
    return event
}
```

---

## ⑤ 版本更新提醒 → Siren

- **分支**：`feature/lib-siren`
- **庫**：[ArtSabintsev/Siren](https://github.com/ArtSabintsev/Siren)
- **理由**：自動查 App Store 版本、三檔強度（annoying / persistent / critical），零後端

### 現況

**完全沒有版本更新提醒機制**。使用者若停留在舊版，無從得知有新版。

### 建議實作

`TigerDuckApp.swift`：

```swift
import Siren

// App onAppear
Siren.shared.rulesManager = RulesManager(
    majorUpdateRules: .critical,    // 大版本差 → 強制
    minorUpdateRules: .persistent,  // 中版本差 → 每次提
    patchUpdateRules: .default,     // 小版本 → 一天一次
    revisionUpdateRules: .relaxed   // 修訂版 → 一週一次
)
Siren.shared.wail()
```

### 遷移步驟

1. 加入 Siren
2. 選定規則（建議如上）
3. 測試：把 Info.plist 的 `CFBundleShortVersionString` 手動改小，模擬舊版 → 確認有 alert

### 驗證清單

- [ ] 低版本啟動 → 顯示更新對話框
- [ ] 「下次再說」點擊後 → 下次 cold start 仍會顯示（視規則）
- [ ] 點「更新」→ 正確跳 App Store 頁

### 風險

- Siren 查的是 iTunes Lookup API → App 剛上架、Apple CDN 還沒同步時可能短暫失準
- **Bundle ID 要對**，不然查不到

### 進階（未來）

若將來需要「強制最低版本」的自訂規則（例如 API 有 breaking change 要擋舊版），可改用 **Firebase Remote Config** 或自建一個 `/api/v1/minimum-ios-version` endpoint。

---

## ⑥ Release Notes → WhatsNewKit

- **分支**：`feature/lib-whatsnewkit`
- **庫**：[SvenTiigi/WhatsNewKit](https://github.com/SvenTiigi/WhatsNewKit)
- **理由**：更新後首次啟動自動彈「新功能」sheet，UI 原生 SwiftUI，文案跟著 app bundle 走、不需後端

### 現況

**沒有任何新功能介紹機制**。使用者更新後完全不知道這版改了什麼。

### 建議實作

新檔：`Features/WhatsNew/WhatsNewStore.swift`

```swift
import WhatsNewKit

extension WhatsNewCollectionProvider where Self == TigerDuckWhatsNewProvider {
    static var tigerDuck: TigerDuckWhatsNewProvider { .init() }
}

struct TigerDuckWhatsNewProvider: WhatsNewCollectionProvider {
    var whatsNewCollection: WhatsNewCollection {
        WhatsNew(
            version: "1.2.0",
            title: "Live Activity 全新升級",
            features: [
                .init(image: .init(systemName: "clock.badge"),
                      title: "即將上課倒數", subtitle: "...")
            ]
        )
        WhatsNew(
            version: "1.3.0",
            // ...
        )
    }
}
```

`TigerDuckApp`:

```swift
.environment(\.whatsNew, WhatsNewEnvironment(
    versionStore: UserDefaultsWhatsNewVersionStore(),
    whatsNewCollection: .tigerDuck
))
```

### 遷移步驟

1. 加入 WhatsNewKit
2. 每次 release 前在 `TigerDuckWhatsNewProvider` 加一筆
3. 文案跟 App Store release notes 對齊（避免分叉）

### 驗證清單

- [ ] 舊版升到新版首次啟動 → 顯示 What's New sheet
- [ ] 同版本第二次啟動 → 不顯示
- [ ] 跨版本升級（例如 1.0 跳到 1.3）→ 顯示最新一筆（或累積？看 library 行為）

### 風險

- 版本字串要跟 `CFBundleShortVersionString` 完全一致
- 別忘了本地化（zh-Hant / en）

---

## ⑦ UserDefaults 型別安全 → Defaults

- **分支**：`feature/lib-defaults`
- **庫**：[sindresorhus/Defaults](https://github.com/sindresorhus/Defaults)
- **理由**：型別安全、Codable 直接支援、KVO 可以 observe

### 現況

**散落的 `UserDefaults.standard.set/object(forKey:)` 呼叫**。

已知點（有更多待掃）：
- `Services/Network/NTUSTSessionManager.swift` → `timestampKey = "ssoLoginTimestamp"`，用 `Double`
- `App/AppState.swift` — 各種使用者偏好（browserPreference 等）
- `LiveActivity/Preferences/LiveActivityPreferencesStore.swift`

**問題**：
1. Key 是 stringly-typed，typo 不會編譯錯
2. 型別每次要手轉（`object(forKey:) as? Double`）
3. 沒有統一位置定義所有 key

### 建議實作

新檔：`App/AppDefaults.swift`

```swift
import Defaults

extension Defaults.Keys {
    static let ssoLoginTimestamp = Key<Date?>("ssoLoginTimestamp")
    static let browserPreference = Key<BrowserPreference>("browserPreference", default: .inApp)
    static let liveActivityClassReminderMinutes = Key<Int>("liveActivity.class.minutes", default: 60)
    // ...
}
```

使用：

```swift
Defaults[.ssoLoginTimestamp] = Date()
if let ts = Defaults[.ssoLoginTimestamp] { ... }
```

### 遷移步驟

1. 加入 Defaults
2. 建 `AppDefaults.swift` 集中定義所有 key
3. 一個檔案一個檔案遷移（一次一個 feature 的 UserDefaults 用法）
4. **key 名稱保持不變** → 現有使用者資料不遺失

### 驗證清單

- [ ] 升級後，之前的偏好（browserPreference、LiveActivity 設定）仍然正確
- [ ] 登入狀態（`ssoLoginTimestamp`）仍然有效，不會被強制重登

### 風險

- 如果 key 名稱改了 → 現有使用者資料遺失 → **一定要保留原 key 字串**

---

## ⑧ 開發期網路除錯 → Pulse（僅 Debug build）

- **分支**：`feature/lib-pulse`
- **庫**：[kean/Pulse](https://github.com/kean/Pulse)
- **理由**：每個 request / response 都可以在 app 內看、支援搜尋、分享 trace；SSO 流程 debug 神器

### 現況

Debug network 只能靠 Charles Proxy 或手動塞 `print`。

### 建議實作

只在 Debug build 加入（用 `#if DEBUG` 包）：

```swift
#if DEBUG
import Pulse
import PulseUI

// In App init
NetworkLogger.enableProxy()  // 自動攔截 URLSession

// 加一個隱藏設定 → 進 Pulse console
NavigationLink(destination: ConsoleView()) { Text("Network Log (Debug)") }
#endif
```

### 遷移步驟

1. Pulse SPM 加入（用 `#if DEBUG` 條件化）
2. 在 More / Settings 某個隱藏位置（例如長按某個東西）加 ConsoleView 入口
3. **不要**放進 Release build

### 驗證清單

- [ ] Debug 跑任意登入流程 → Console 有記錄
- [ ] Release build 確認 Pulse code 沒被編進去（`nm` 檢查）

### 風險

- 如果不小心編進 Release → 使用者可以看到所有 network trace 含 cookie → **必須 `#if DEBUG`**

---

## ⑨ 圖片快取 → Nuke（可選）

- **分支**：`feature/lib-nuke`
- **庫**：[kean/Nuke](https://github.com/kean/Nuke)
- **理由**：公告 HTML 內嵌的 `<img>` 目前用 `NSAttributedString` 解，**沒有快取、不能取消、無法處理載入失敗**

### 現況

**檔案**：`Features/Announcements/Components/AnnouncementDetailView.swift` 的 `HTMLContentView`

目前用 `NSAttributedString(data:options: [.documentType: .html])` 解 HTML，iOS 會自動下載 `<img>` → 慢、不快取、UI 會卡

### 建議實作（進階）

拆兩步：

1. 先用 SwiftSoup 把 HTML 裡的 `<img src>` 抽出來
2. 文字用 `AttributedString` 呈現
3. 圖片用 Nuke 的 `LazyImage` 單獨渲染

```swift
struct HTMLContentView: View {
    let html: String
    var body: some View {
        let segments = HTMLSegmenter.segment(html)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(segments) { segment in
                switch segment {
                case .text(let attr): Text(attr)
                case .image(let url): LazyImage(url: url).processors([.resize(width: 360)])
                }
            }
        }
    }
}
```

### 遷移步驟

1. 這個**依賴 SwiftSoup 先導入**（要先做 ②）
2. 寫 `HTMLSegmenter` 把 HTML 拆段
3. 替換 `HTMLContentView`

### 驗證清單

- [ ] 純文字公告 → 正常顯示
- [ ] 含圖公告 → 圖片載入、可快取、滾動不卡
- [ ] 離線看已載入過的公告 → 圖片從 cache 出來

### 風險

- HTML 結構複雜時，segmenter 可能切錯 → 需要好好測
- 若公告圖片極少，這個改動**可以延後甚至不做**（現有 `NSAttributedString` 夠用）

---

## 不建議更換的元件

| 元件 | 檔案 | 理由 |
|------|------|------|
| Network 狀態監測 | `Services/Network/NetworkMonitor.swift` | NWPathMonitor 20 行夠乾淨，無 lib 可超越 |
| In-App Browser | `SharedUI/InAppBrowserView.swift` | `SFSafariViewController` 是 Apple 官方方案 |
| 載入骨架 | `SharedUI/LoadingShimmer.swift` | 28 行 SwiftUI，換 lib 是過度設計 |
| 月曆 | `Features/Calendar/Components/MonthCalendarView.swift` | 你的 UI 需求跟 stock 日曆 lib 差很遠，手刻控制度更高 |
| Onboarding | `Features/Onboarding/OnboardingView.swift` | TabView `.page` 夠用，`PaperOnboarding` 等 lib 太過重 |
| QR Code 顯示 | `Features/Library/Components/LibraryQRCodeView.swift` | 圖由 server 回傳，不需要生成 lib |
| SwiftData Models | `Models/SwiftData/SDxxx.swift` | SwiftData 是 Apple 官方，已經是「第三方庫」了 |

---

## 附帶發現：架構債

**這個不是「第三方庫」能解的，但要記一下。**

### 🔴 雙寫：SwiftData vs DataCache

**現況**：
- `Models/SwiftData/SDCourse.swift`、`SDAssignment.swift`、`SDCalendarEvent.swift`、`SDAnnouncement.swift` 看起來是 SwiftData `@Model`
- 同時 `Services/Network/DataCache.swift` 又用 `CachedCourse`、`CachedAssignment`、`CachedCalendarEvent` DTO 把資料寫成 JSON 檔案到 cachesDirectory / applicationSupportDirectory

**問題**：
- 你既沒真的用 SwiftData 的自動持久化能力
- 又多維護了一整套序列化 / 反序列化
- 兩份資料可能不同步 → bug 溫床

**兩條路線（未來決定）**：

**路線 A（推薦）**：全 SwiftData
- 讓 SwiftData `ModelContainer` 落地到 `appGroupContainer(identifier:)` → Live Activity Extension 可以直接讀
- 刪掉整個 `DataCache.swift`
- 省下 ~250 行序列化 code

**路線 B**：全 JSON
- `SD` prefix 的檔案改成純 `struct` + `Codable`
- 放棄 SwiftData 的查詢 / 關聯能力
- 保留 `DataCache` 就好

**不要兩個都留**。

### 🟡 SSO 重認證邏輯散落

現狀：`MoodleService.fetchAssignments` 裡手刻 sesskey 過期 → 重登 → 再 fetch 的邏輯。
這個屬於 `RequestInterceptor` 該做的事。搭 ③ Alamofire 遷移一起解。

### 🟡 PII 在 log 的風險

現況：`AuthService.login(studentId:password:)` 的 `print` / `os.Logger` 沒有 scrubber。
**上 Sentry 前要先 audit 一次**所有 log 有沒有把 studentId / password 印出來。

---

## 建議執行順序

```
Week 1 (風險低、收益立即)
├─ ① feature/lib-valet          ← 最簡單，打通 Live Activity 共用憑證
└─ ⑦ feature/lib-defaults       ← 跟 Valet 類似性質，順手做

Week 2 (核心，最重要)
├─ ② feature/lib-swiftsoup      ← 拆定時炸彈（SSO HTML parser）
└─ ④ feature/lib-sentry         ← 先上 Sentry 才看得到 SwiftSoup 遷移有沒有戳爆什麼

Week 3 (網路層重構)
├─ ③ feature/lib-alamofire      ← PR 1：純替換
└─ ③.2 feature/lib-alamofire-interceptor  ← PR 2：加 interceptor

Week 4 (對外體驗)
├─ ⑤ feature/lib-siren          ← 版本更新提醒
└─ ⑥ feature/lib-whatsnewkit    ← Release notes

Backlog (可選)
├─ ⑧ feature/lib-pulse          ← Debug 工具
└─ ⑨ feature/lib-nuke           ← 依賴 ② 先做
```

---

## 每個分支的 PR 範本

```markdown
## 目的
[一句話]

## 變動
- 新增依賴：<lib>
- 替換：<哪些檔案 / 哪些函數>
- 保留 shim：<是 / 否>

## 驗證清單
（從本文件對應章節複製）

## 風險 & Rollback
- 若有問題：revert commit `<sha>` 並移除 SPM 依賴即可
- 無資料格式變更（keychain key / userdefaults key 皆保持原名）

## 截圖 / 影片
- [ ] 登入流程
- [ ] 核心功能 x 3
```

---

**報告結束。每個分支請獨立討論、獨立 PR、獨立驗證。**
