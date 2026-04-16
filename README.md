<div align="center">
<img width="2000" src="https://github.com/user-attachments/assets/cf6a1d18-a348-4b83-adfd-81c6dc82855f" />
<!-- ![TigerDuck Banner](.github/assets/banner.png) -->
<br>

[![License](https://img.shields.io/github/license/tigerduck-app/tigerduck-app?style=for-the-badge)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![iOS](https://img.shields.io/badge/iOS-18%2B-black?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/ios)

[![TestFlight](https://img.shields.io/badge/TestFlight-Join-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/eVt9Gjkw)

**繁體中文** | [English](README_en.md)
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

### 🏛️ **圖書館**（實驗性）
- 秒開入館 QR-Code，無任何延遲

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
[![TestFlight](https://img.shields.io/badge/TestFlight-Join-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/eVt9Gjkw)

<br/>

## 開發規劃
> 以下功能為規劃中項目，實際開發順序與內容可能依需求調整。

### 🎓 教務與學習
- [x] **作業** – 全自動同步 Moodle 作業
- [x] **作業+** – 訊息與動態島通知
- [ ] **作業++** – 根據剩餘時間修改 App 圖標，致敬 Duolingo
- [x] **課表** – 擷取自選課系統
- [x] **課表+** – 可修改的課程名稱、可刪除的課程
- [x] **課表++** – 動態島課程狀態
- [x] **行事曆** – 整合校公告、Moodle 等行程資訊
- [ ] **行事曆+** – 追蹤使用者討論小間、講座、社團行程
- [ ] **歷年 GPA 與排名查詢** – 快速查詢歷年成績表現與排名資訊
- [ ] **畢業門檻學分計算** – 包含各個通識向度、院學分、系學分、體育、國文、英文等畢業條件檢核

### 📝 選課相關
- [ ] **選課查詢** – 同時顯示 GPA，提升選課決策效率
- [ ] **中籤機率估算與志願序建議** – 根據人數上限與目前選課人數估算中籤機率，並可自動重新排列志願序

### 📚 圖書館服務
- [x] **圖書館出入館 QR-Code** – 快速開啟入館 QR-Code
- [ ] **圖書館討論小間借用** – 支援討論室預約與借用查詢
- [ ] **臺科大圖書館講座活動** – 包含活動報名與查詢（需校內連線）

### 📣 校園資訊
- [ ] **各處室、中心公告** – 支援公告整合與 Filter 篩選
- [ ] **獎學金資訊** – 支援 Filter，可依低收、中低收、原住民等條件過濾
- [ ] **當日社團活動** – 整理每日社團活動資訊
- [ ] **空教室查詢** – 快速查詢目前可使用的教室

### 🍱 校園生活
- [ ] **免費便當通知** – 任何人可實名登記，並整合台科大、台大相關資訊，主動推播通知

## 系統需求
| 項目 | 需求 |
|------|------|
| 作業系統 | iOS 18 以上 |
| SSO 帳號 | 學生帳號（部分功能需要）|
| 圖書館 | 圖書館帳號（部分功能需要）|


<br/><br/>

---

<br/><br/>

## 開發環境建置

### 需求
- **macOS**
- Xcode 26+
- Swift 5
- [uv](https://github.com/astral-sh/uv) 套件管理器（網路請求方法驗證）

### iOS App
```bash
# clone 專案
git clone https://github.com/tigerduck-app/tigerduck-app.git
cd tigerduck-app

# 以 Xcode 開啟
open swift/TigerDuck.xcodeproj

# 開啟後，中間上方選擇模擬器或實體裝置，按 `⌘R` 執行
```


### 網路請求方法驗證（Python）

NTUST 課程、Moodle 作業、行事曆的資料抓取、爬蟲

```bash
cd backend

# 安裝 uv
brew install uv

# 安裝依賴
uv sync

# 複製環境變數範本
cp .env.example .env

# 在 .env 內填入 NTUST 學號與密碼
```

## 專案架構

```
tigerduck-app/
├── swift/
│   └── TigerDuck/
│       ├── Features/           # 各頁面功能模組
│       │   ├── Home/           # 首頁（時光機、作業、小工具）
│       │   ├── ClassTable/     # 課表
│       │   ├── Calendar/       # 行事曆
│       │   ├── Library/        # 圖書館
│       │   ├── Announcements/  # 公告
│       │   ├── Settings/       # 設定
│       │   └── Onboarding/     # 初次使用引導
│       ├── LiveActivity/       # 即時動態 
│       │   ├── Models/         # 各功能模型
│       │   ├── Preferences/    # 偏好設定
│       │   ├── Providers/      # 資料取得
│       │   ├── Resolvers/      # 解析器
│       │   ├── Runtime/        # 主邏輯
│       │   └── Scheduling/     # 排程器
│       ├── Models/
│       │   ├── Domain/         # 業務邏輯模型
│       │   └── SwiftData/      # 本地持久化模型
│       ├── Services/
│       │   ├── Auth/           # NTUST SSO 認證
│       │   └── Network/        # 網路請求
│       ├── SharedUI/           # 共用 UI 元件
│       └── Theme/              # 全域主題定義
└── backend/
    └── api/                    # Python 資料抓取腳本
        ├── ntust_sso.py        # NTUST SSO 登入
        ├── course_lookup.py    # 課程查詢
        ├── get_moodle_homework.py  # Moodle 作業
        └── get_calender.py     # 行事曆
```

## 貢獻
歡迎 PR 與 Issue！

送出前請確認
1. 遵循現有的 SwiftUI 程式碼風格與架構慣例
2. 測試於 iOS 18 & iOS 26 模擬器或實機上可正常運行
3. 以 `feature/your-feature` 或 `fix/your-fix` 命名分支
4. 發布 PR 時，目標分支為 `dev`，且必須勾選 Copilot 做 Revise

## 授權
本專案採用 [GNU Affero General Public License v3.0](LICENSE) 授權。
