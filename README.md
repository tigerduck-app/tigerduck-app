<div align="center">
<a href="https://tigerduck.app/">
  <img width="2000" src="https://github.com/user-attachments/assets/cf6a1d18-a348-4b83-adfd-81c6dc82855f" alt="TigerDuck Banner"/>
</a>
<!-- ![TigerDuck Banner](.github/assets/banner.png) -->
<br>

[![License](https://img.shields.io/github/license/tigerduck-app/tigerduck-app?style=for-the-badge)](LICENSE)
[![Version](https://img.shields.io/badge/Version-v2.0.0-00BB00?style=for-the-badge)](https://github.com/tigerduck-app/tigerduck-app/releases/tag/v2.0.0)
[![iOS](https://img.shields.io/badge/iOS-18%2B-black?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/ios)

[![App Store](https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://apps.apple.com/app/id6761084888)
[![TestFlight](https://img.shields.io/badge/TestFlight-Join-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/eVt9Gjkw)

**繁體中文** | [English](README.en.md)
</div>

## 總覽

<img align="right" width="330" alt="IMG_9202-portrait" src="https://github.com/user-attachments/assets/cf13806f-3419-4b50-8b9f-13fd77f979ef" />

TigerDuck 是由一群學生共同開發的校園助手  
為了解決資源零散、通知不及時與介面不直觀等問題  
有用過 [TAT](https://github.com/morris13579/tat_ntust) 嗎，我們努力把 TigerDuck 做得更 OAO

### 📚 **作業**
- 一眼就知道還有多少**作業沒有繳交**
- **全自動**從 Moodle 同步作業與截止日期，再也不被教授偷襲！
- **動態島**與訊息通知，別等倒最後一小時才收到 Moodle 的通知

### 📋 **課表**
- 從選課系統同步，不用再**等 Moodle 延遲**
- 動態島與即時動態告訴你下一節課在哪！

### 📣 **公告**
- 由後端 **LLM 自動分類、整理、去重複**，不用再被處室公告洗版
- 可篩選未讀、訂閱類別，有重要公告馬上通知你

### 📊 **歷年成績**
- 學期 / 累計 GPA、排名、各科成績一次看完
- 互動式圖表追蹤成績走勢

### 🏛️ **圖書館**（實驗性）
- 秒開入館 QR-Code，無任何延遲

### ⌚ **Apple Watch**
- 抬腕即見**入館 QR-Code**，全螢幕顯示、閒置自動淡出頁碼
- 透過 WatchConnectivity 自動同步登入憑證，無需在 Watch 上重新登入

### 🌏 **外觀**
- 內建 **67+ 種語系**，自行設定或跟著系統語言切換
- 名字過長？課程 / 教室名稱**自動簡寫**

### 🎨 **客製化**
- 要就加，不要就刪掉
- 自由拖放區塊排序、編輯 Tab、選擇主題色


<br clear="right"/>

## 示例圖

<details>
<summary><strong>展開查看 App 示例圖</strong></summary>

<br>

<div align="center">

| 作業 | 課表 | 圖書館 |
|:---:|:---:|:---:|
| <img width="300" src="https://github.com/user-attachments/assets/2c7e2e82-a1cf-4db7-9c51-08e2636d02e2" /> | <img width="300" src="https://github.com/user-attachments/assets/7f30603f-e0b7-4cdf-94c6-5d72c05efb3c" /> | <img width="300" src="https://github.com/user-attachments/assets/f9fb2b1a-3532-4037-ab04-566f015ef3bc" /> |

| 客製化設定 | 客製化 Tab | 客製化首頁 |
|:---:|:---:|:---:|
| <img width="300" src="https://github.com/user-attachments/assets/9dfa88e2-b0ef-4f06-9349-da97537dc4bb" /> | <img width="300" src="https://github.com/user-attachments/assets/b95f48d9-a18b-4ccc-bb21-610258fe25d0" /> | <img width="300" src="https://github.com/user-attachments/assets/6832b886-3e52-4bde-8b7d-8089bf13d4c7" /> |

</div>

</details>

<br/>

## 取得 App
[![App Store](https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://apps.apple.com/app/id6761084888)

[![TestFlight](https://img.shields.io/badge/TestFlight-Join-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/eVt9Gjkw)

<br/>

## 版本歷程
> 完整 Release Notes 請見 [GitHub Releases](https://github.com/tigerduck-app/tigerduck-app/releases)。

| 版本 | 日期 | 重點 |
|:---:|:---:|---|
| **`v2.0.0`** | 2026-06-20 | 🚀 **雲端同步正式上線** — 課程/作業即時上傳、macOS 推播與帳號同步、401 自動恢復、伺服器推播頻道設定 |
| **`v1.7.0`** | 2026-05-18 | 🔔 **Apple Watch App 上線** — Library QR 作為左側分頁、WatchConnectivity 即時推送憑證、全螢幕 QR 與閒置淡出頁碼、QR 頁面字串在地化；macOS 儀表板與課表統一走 `CanonicalCourseProvider`、下一堂課時間區間加長；Home / 課表卡片等高鎖定、衝堂並排顯示各自時段；圖書館 QR 顯示時自動最大亮度；Onboarding 登入鍵盤錨點與授權後推播啟用修正；後端拆出獨立 `tigerduck-backend` repo；升級至 Xcode 26.4、Swift 6 strict concurrency 全綠 |
| **`v1.6.1`** | 2026-05-01 | 🤖 **Android FCM 推播通道**（為 Android 版鋪路、批次 fan-out、bad-token 分類）、API base path 從 `/v1` 升 `/v2`（`/v1` 保留為 deprecated alias）、iOS 註冊裝置帶 `platform=apple` |
| **`v1.6.0`** | 2026-05-01 | 🌏 **多語言（67+ 語系）**、in-app 語言切換、RTL 版面修正、課程/教室**簡稱**子模組、locale 隔離的課表快取 |
| **`v1.5.2`** | 2026-04-24 | Live Activity 推播 token 重送/清理、Push 排程器 token 修剪、mismatched snapshot 防護 |
| **`v1.5.1`** | 2026-04-24 | 課表「今日課程」邏輯與作業列表洗資料的修正 |
| **`v1.5.0`** | 2026-04-24 | 📣 **公告大改版** — 改由後端推、LLM 分類去重、可訂閱類別、NULL-safe 分頁 |
| **`v1.4.0`** | 2026-04-22 | 🚀 **推播後端上線** — FastAPI + APNs Push-to-Start、Schedule Sync、shared secret 驗證 |
| **`v1.3.6`** | 2026-04-22 | 📊 **歷年成績** 接進主分頁、互動式圖表 |
| **`v1.3.3`** | 2026-04-21 | 作業狀態語意色標、submission timemodified |
| **`v1.3.2`** | 2026-04-21 | Moodle OIDC 改版、`30ms` server probe 取代 `1h` TTL、24h 課程快取 |
| **`v1.3.0`** | 2026-04-17 | 動態島（Live Activity）重新設計、設定頁優化 |

<br/>

## 開發規劃

### 🎓 教務與學習
- [x] **作業** – 全自動同步 Moodle 作業 `v1.0`
- [x] **作業+** – 訊息與動態島通知 `v1.3.0`
- [x] **作業 狀態追蹤** – submission / cutoff、語意色標 `v1.3.3`
- [ ] **作業++** – 根據剩餘時間修改 App 圖標，致敬 Duolingo
- [x] **課表** – 擷取自選課系統 `v1.0`
- [x] **課表+** – 可修改的課程名稱、可刪除的課程 `v1.0`
- [x] **課表++** – 動態島課程狀態 `v1.3.0`
- [x] **行事曆** – 整合校公告、Moodle 等行程資訊 `v1.0`
- [ ] **行事曆+** – 追蹤使用者討論小間、講座、社團行程
- [x] **歷年 GPA 與排名查詢** – 學期 / 累計 / 各科成績 + 互動式圖表 `v1.3.6`
- [ ] **畢業門檻學分計算** – 包含各個通識向度、院學分、系學分、體育、國文、英文等畢業條件檢核

### 📝 選課相關
- [ ] **選課查詢** – 同時顯示 GPA，提升選課決策效率
- [ ] **中籤機率估算與志願序建議** – 根據人數上限與目前選課人數估算中籤機率，並可自動重新排列志願序

### 📚 圖書館服務
- [x] **圖書館出入館 QR-Code** – 快速開啟入館 QR-Code `v1.0`
- [ ] **圖書館討論小間借用** – 支援討論室預約與借用查詢
- [ ] **臺科大圖書館講座活動** – 包含活動報名與查詢（需校內連線）

### 📣 校園資訊
- [x] **各處室、中心公告** – 支援公告整合 `v1.0`
- [x] **公告 LLM 分類 + 訂閱通知** – 後端自動分類去重、可訂閱類別、未讀篩選 `v1.5.0`
- [ ] **獎學金資訊** – 支援 Filter，可依低收、中低收、原住民等條件過濾
- [ ] **當日社團活動** – 整理每日社團活動資訊
- [ ] **空教室查詢** – 快速查詢目前可使用的教室

### 🍱 校園生活
- [ ] **免費便當通知** – 任何人可實名登記，並整合台科大、台大相關資訊，主動推播通知

### 🌏 在地化與無障礙
- [x] **多語言（67+ 語系）** – 跟著系統或在 App 內單獨切換 `v1.6.0`
- [x] **課程 / 教室名稱簡稱** – 一鍵切換、可還原 `v1.6.0`
- [x] **RTL 版面修正** – 阿拉伯語 / 希伯來語等右至左語系排版 `v1.6.0`

## 系統需求
| 項目 | 需求 |
|------|------|
| 作業系統 | iOS 18 以上 |
| Apple Watch（選用） | watchOS 11 以上，需配對 iPhone |
| SSO 帳號 | 學生帳號（部分功能需要）|
| 圖書館 | 圖書館帳號（部分功能需要）|


<br/><br/>

---

<br/><br/>

## 開發環境建置
[![Swift](https://img.shields.io/badge/Swift-5-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![Python](https://img.shields.io/badge/Python-3.13-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://python.org)

### 需求
- **macOS**
- Xcode 26+
- Swift 5
- [uv](https://github.com/astral-sh/uv) 套件管理器（後端 / POC 腳本）
- Docker Desktop（要跑完整推播後端時才需要）

### iOS App
```bash
# clone 專案（含子模組：localization、name-abbr）
git clone --recurse-submodules https://github.com/tigerduck-app/tigerduck-app.git
cd tigerduck-app

# 已經 clone 過的話，補抓子模組
git submodule update --init --recursive

# 以 Xcode 開啟
open swift/TigerDuck.xcodeproj

# 開啟後，中間上方選擇模擬器或實體裝置，按 `⌘R` 執行
```

> 💡 名稱簡稱（`name-abbr/`）與多語系字串（`localization/generated/apple/`）皆透過 symlink 綁進 Xcode synchronized group，clone 後**務必**先抓子模組再開 Xcode，否則 build 會找不到資源檔。

### 推播後端
正式環境的 FastAPI 推播服務（APNs Push-to-Start、排程同步、公告抓取與 LLM 分類）已獨立成 [tigerduck-backend](https://github.com/tigerduck-app/tigerduck-backend) 專案；iOS App 透過 `https://api.tigerduck.app/v2/*` HTTP 契約溝通，本地端開發 iOS 時不需要把它跑起來。

### 網路請求方法驗證（`api-poc/`）

NTUST 課程、Moodle 作業、行事曆等抓取邏輯**進入 Swift 之前**用 Python 先驗證，純粹是 POC 腳本，不是長期服務。

```bash
cd api-poc

# 安裝 uv
brew install uv

# 安裝依賴
uv sync

# 複製環境變數範本
cp api/.env.template api/.env

# 在 .env 內填入 NTUST 學號與密碼
```

## 專案架構

```
tigerduck-app/
├── swift/                              # iOS App + 周邊 target（Xcode 26+ / iOS 18+ / watchOS 11+）
│   ├── TigerDuck/                      # 主 iOS App 來源
│   │   ├── App/                        # 全域狀態（AppState）、語言管理、推播代理
│   │   ├── Bridge/                     # 服務協調層（KMP / 原生抓取 bridge）
│   │   ├── Features/                   # 各分頁功能模組
│   │   │   ├── Home/                   # 首頁（時光機、作業、小工具）
│   │   │   ├── ClassTable/             # 課表
│   │   │   ├── Calendar/               # 行事曆
│   │   │   ├── Bulletins/              # 公告（後端 LLM 分類、訂閱、推播）
│   │   │   ├── Score/                  # 歷年成績與排名
│   │   │   ├── Library/                # 圖書館
│   │   │   ├── More/                   # 「更多」聚合頁與功能釘選
│   │   │   ├── Settings/               # 設定（語言、簡稱、主題、來源碼）
│   │   │   └── Onboarding/             # 初次使用引導
│   │   ├── LiveActivity/               # 即時動態 / 動態島（App 內邏輯）
│   │   │   ├── Models/  Preferences/  Providers/
│   │   │   ├── Resolvers/  Runtime/  Scheduling/
│   │   ├── Models/
│   │   │   ├── Domain/                 # 業務邏輯模型
│   │   │   └── SwiftData/              # 本地持久化模型
│   │   ├── Services/
│   │   │   ├── Auth/                   # NTUST SSO 認證
│   │   │   ├── Network/                # 網路請求
│   │   │   ├── Push/                   # APNs / Push 註冊
│   │   │   ├── Logging/                # 結構化日誌
│   │   │   └── Migrations/             # 一次性遷移
│   │   ├── SharedUI/                   # 共用 UI 元件
│   │   └── Theme/                      # 主題、配色、視覺預設
│   ├── TigerDuckLiveActivity/          # Live Activity / 動態島 Widget Extension
│   ├── TigerDuckWidgets/               # iOS 主畫面 / 鎖定畫面 Widget
│   ├── TigerDuckWatch Watch App/       # Apple Watch App（Library QR）
│   ├── TigerDuckWatchWidget/           # Apple Watch 複雜功能 (Complication)
│   └── Shared/                         # 跨 target 共用程式碼（感測器、Watch 通訊、Theme）
├── api-poc/                            # 第三方 API 驗證腳本（NTUST / Moodle / Calendar）
│   └── api/                            # ntust_sso / course_lookup / moodle / calendar
├── docs/                               # 規劃文件、移轉計畫（iOS 端）
├── localization/                       # ⤴ git submodule：67+ 語系翻譯
└── name-abbr/                          # ⤴ git submodule：課程 / 教室簡稱字典

> 推播 / 公告後端（FastAPI + Postgres + APNs + LLM）已分拆至 [tigerduck-backend](https://github.com/tigerduck-app/tigerduck-backend)。
```

## 貢獻
歡迎 PR 與 Issue！

送出前請確認
1. 遵循現有的 SwiftUI 程式碼風格與架構慣例
2. 於以下版本的模擬器或實機上測試可正常運行
- iOS 18 / 26 (/ 27 如果可以的話)
- watchOS 11 / 26 (/ 27 如果可以的話)
- macOS 15 / 26 (/ 27 如果可以的話)
3. 以 `feature/your-feature` 或 `fix/your-fix` 命名分支
4. 發布 PR 時，目標分支為 `dev`，且必須勾選 Copilot 做 Revise
5. 翻譯字串請改 `localization/` 子模組（透過獨立 PR），不要直接改 `swift/.../*.lproj` 內的 symlink

## 授權
本專案採用 [GNU Affero General Public License v3.0](LICENSE) 授權。
