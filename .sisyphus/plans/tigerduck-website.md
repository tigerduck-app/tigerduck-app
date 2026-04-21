# TigerDuck 官方網站 — Next.js + Cloudflare Workers + Three.js

## TL;DR

> **Quick Summary**: 在 TigerDuck monorepo 新增 `/web` 子目錄，建立中英雙語官方網站（Next.js 15 App Router + `@opennextjs/cloudflare` 部署到 tigerduck.app），單頁長捲動首頁內含 Three.js 3D 漂浮手機 hero、iOS 玻璃擬態 / Android Material 3 雙區塊，搭配獨立的 Policy / Delete-account 頁面供商店審核。
>
> **Deliverables**:
> - `/web/` Next.js 15 App Router 專案（TS strict、Tailwind v4、next-intl i18n）
> - 單頁長捲動首頁 `/` + `/en`，含 9 個區段 + 3D Hero
> - 獨立頁面：`/privacy-policy`、`/delete-account`（zh + en 共 4 頁）
> - `wrangler.jsonc` + OpenNext 部署配置、`tigerduck.app` custom domain route
> - Playwright E2E smoke tests（5 個關鍵路徑）
> - CF Web Analytics + OG + sitemap + hreflang + robots + console 彩蛋
>
> **Estimated Effort**: Large
> **Parallel Execution**: YES — 4 waves
> **Critical Path**: T1（scaffolding）→ T8（layout）→ T15（home 組合）→ T21（E2E smoke）→ F1-F4 review wave

---

## Context

### Original Request
> 幫我在這個目錄的 /web 撰寫這個應用程式的網站介紹和說明。nextjs + react、cloudflare worker、最新協議（查過最佳實踐，不要使用過世方法）。詳細深入討論需要具備的內容。可以留圖片佔位符，展示機型 iPhone 17 Pro、Pixel 10 Pro。有 Android 和 iOS 兩個版本；iOS TestFlight 已有，App Store 申請中；Android 需 email 手動內測，F-Droid / Play 申請中。Policy 頁面參考現有 tigerduck-app/website。校園風格 + Three.js 效果。

### Interview Summary

**Wave 1 決策**
- ✅ **頁面架構**：`/` 單頁長捲動（Home）+ 獨立頁 `/privacy-policy`、`/delete-account`（App Store 審核規範）
- ✅ **語言**：zh-TW 預設 + `/en` 英文版
- ✅ **美學方向（創意雙語言）**：iOS section = 玻璃擬態 (Liquid Glass) / Android section = Material 3（網站本身 demo 兩邊 app 的原生體驗）
- ✅ **3D 主場景**：iPhone 17 Pro + Pixel 10 Pro 漂浮 + 光暈
- ✅ **域名**：`tigerduck.app`（custom domain on Cloudflare Workers）

**Wave 2 決策**
- ✅ **下載 CTA（雙階段）**：
  - iOS beta → TestFlight `https://testflight.apple.com/join/eVt9Gjkw`
  - Android beta → redirect to `https://tigerduck.app/discord`（placeholder，使用者進 Discord 開 ticket）
  - 正式版 CTA（App Store / Play Store / F-Droid badges）**一併設計但用 `{/* */}` 註解隱藏**，上架時取消註解即可
- ✅ **Policy 內容**：沿用既有中文 + 追加英文翻譯
- ✅ **內容區塊（long scroll 順序）**：Hero → Stats → Features → iOS 玻璃 → Android M3 → Roadmap → Team → FAQ → Footer
- ✅ **Dark mode**：自動跟隨系統 + 手動 toggle
- ✅ **測試**：Build 檢查 + Playwright E2E smoke
- ✅ **SEO/Analytics**：CF Web Analytics、OG + Twitter Card、sitemap、robots、hreflang、console 彩蛋
- ✅ **NTUST 關聯口徑**：「由臺科學生建造」+ footer/FAQ 清楚免責聲明（非 NTUST 官方專案）

### Research Findings

**Stack（2026 最新，已驗證）**
- Next.js 15+ App Router（App Router 為官方推薦，Pages Router deprecated）
- `@opennextjs/cloudflare`（**非** `@cloudflare/next-on-pages`，後者已 deprecated）
- `wrangler.jsonc` 配 `nodejs_compat` + `global_fetch_strictly_public` compat flags
- `@react-three/fiber` v10 + `@react-three/drei`
- 本機預覽：`npx opennextjs-cloudflare preview`；部署：`npx opennextjs-cloudflare deploy`

**產品資料（從 3 個 repo 綜合）**
- iOS repo: `tigerduck-app/tigerduck-app`（SwiftUI、iOS 18+、33 stars、5 contributors、AGPL-3.0、TestFlight）
- Android repo: `tigerduck-app/tigerduck-app-android`（Jetpack Compose + M3、Android 8.0+、5 stars、v1.1.5 on 2026-04-13、AGPL-3.0、email beta）
- 既有 website repo: `tigerduck-app/website`（static HTML，僅 privacy-policy + delete-account 有內容）
- 聯絡：`tigerduckapp@gmail.com`

**核心功能（雙平台皆有）**
1. 📚 作業（Moodle 同步 + 通知）
2. 📋 課表（選課系統同步 + 時光機）
3. 🗓️ 行事曆（校公告 ICS + Moodle）
4. 🏛️ 圖書館（入館 QR Code）
5. 🎨 客製化（拖放、主題色、Tab 編輯）
6. ⚙️ 平台特色：iOS Dynamic Island / Widget、Android 時光機雙樣式

### Metis Review

**已修正的缺口**
- Team 人數不虛報 → 改為 build-time 從兩個 GitHub repo 拉真實 contributors
- 截圖 hotlink 脆弱 → 下載到 `public/screenshots/<feature>-<platform>.png` 並版本化
- 本地缺 brand asset → 新增 T1a asset 盤點任務 + SVG logo placeholder
- Android 存在性 → 已確認獨立 repo，計畫引用 `tigerduck-app-android` 真實 release v1.1.5
- 「時光機」平台歸屬 → 雙平台都有（但 Android 有雙樣式特色），在兩邊各自展示各自強項
- OAO 語氣 vs 正式 → 保留學生社群幽默為品牌定位

**已套用預設**
- Tailwind v4（新專案無歷史包袱，利用 CSS-first config）
- next-intl（App Router 對 i18n routing 推薦的第三方方案）
- Lighthouse 目標：Performance ≥ 90, Accessibility ≥ 95, SEO = 100
- Bundle size budget：初始 JS ≤ 180kb gzipped（不含 3D chunk；3D 為 lazy chunk ≤ 300kb）
- WCAG 2.2 AA 合規

---

## Work Objectives

### Core Objective
建立 TigerDuck 在 `/web` 的官方行銷/產品網站，**單一 Next.js 專案、中英雙語、Cloudflare Workers 部署、Three.js 3D 主視覺**，供終端使用者了解 app、下載/加入內測、閱讀 policy。

### Concrete Deliverables
1. `/web/` 目錄含完整 Next.js 15 App Router 專案（TS strict）
2. `/` + `/en/` 單頁長捲動首頁（Hero → Stats → Features → iOS → Android → Roadmap → Team → FAQ → Footer）
3. `/privacy-policy` + `/en/privacy-policy`（內容沿用既有中文 + 英譯）
4. `/delete-account` + `/en/delete-account`（內容沿用既有中文 + 英譯）
5. `sitemap.xml` + `robots.txt` + hreflang alternates
6. `wrangler.jsonc` + `open-next.config.ts` + `npm run deploy` 可一鍵部署到 Cloudflare Workers
7. Playwright E2E smoke tests（5 scenarios）
8. `/web/README.md` 說明本地開發與部署流程
9. CF Web Analytics script 嵌入、OG meta + Twitter Card、favicon 全套

### Definition of Done
- [ ] `cd web && npm run build` pass（TS strict、零 ESLint error、零 warning）
- [ ] `cd web && npx opennextjs-cloudflare build` 產出 `.open-next/worker.js`
- [ ] `cd web && npx playwright test` 5/5 pass
- [ ] `cd web && npx opennextjs-cloudflare preview` 本機開 `http://localhost:8787/` 可看首頁 + 3D 運作
- [ ] Lighthouse mobile：Perf ≥ 85、A11y ≥ 95、SEO = 100（本地測量）
- [ ] 所有 6 個核心功能都有獨立 section + 截圖（或 placeholder）
- [ ] Policy/Delete-account 中英 4 頁皆上線

### Must Have
- Cloudflare Workers 部署（非 Pages）使用 `@opennextjs/cloudflare` adapter
- Three.js 3D hero（R3F，非原生 Three.js）+ 無 WebGL fallback image
- 中英雙語完整對應（含 hreflang）
- Dark mode（auto + manual toggle）
- iOS 區塊使用玻璃擬態、Android 區塊使用 Material 3 視覺語言（各自獨立實作，不混用）
- Policy 中英 + Delete-account 中英 4 頁皆有且與既有 repo 內容一致
- NTUST 關聯明確框架：「由臺科學生建造」+ footer/FAQ 免責聲明
- 下載 CTA 雙階段設計：beta 階段（TestFlight + Discord）可見、正式版（store badges）用註解隱藏待上線
- Playwright E2E smoke test（至少 5 scenarios）
- 所有 GitHub user-attachments 截圖下載到 `public/screenshots/`（不能 hotlink）

### Must NOT Have (Guardrails)
- ❌ **不使用 `@cloudflare/next-on-pages`**（已 deprecated，會被 reject）
- ❌ **不使用 Pages Router**（Next.js 15 官方推薦 App Router）
- ❌ **不 hotlink GitHub user-attachments 圖片**（脆弱，會 403）
- ❌ **不在 Server Component 直接 import `three` / R3F**（會 SSR crash；必須 `dynamic({ ssr: false })`）
- ❌ **不使用 NTUST logo、校徽、校名縮寫作為品牌符號**（未授權）
- ❌ **不虛報 team 人數**（必須 build-time 從 GitHub API 拉實際 contributors）
- ❌ **不使用 Lorem ipsum 或「Revolutionary AI-powered」等 AI slop 行銷詞**（保留學生社群幽默為品牌定位）
- ❌ **不在 Free plan 啟用 Cloudflare Images binding**（確認是否收費；預設不用）
- ❌ **不使用 CSS-in-JS (styled-components / emotion)**（違反 Tailwind v4 一致性 + SSR 開銷）
- ❌ **不引入 GA4 / Google Analytics**（違反 CF Web Analytics 決策 + 增加 privacy-policy 複雜度）
- ❌ **不在 `next.config` 寫 `output: "export"`**（會破壞 OpenNext）
- ❌ **不動 `/swift`、`/backend`、既有 `/tigerduck-app/website` repo**（scope 邊界）

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** — 全部 agent-executed。

### Test Decision
- **Infrastructure exists**: NO（`/web` 為新目錄，無既有測試）
- **Automated tests**: YES — Tests-after with Playwright smoke（marketing site 常規作法）
- **Framework**: Playwright（CF Workers 環境相容）
- **Policy**: 每個任務的 QA scenarios 使用 Playwright / Bash（curl）驗證實際行為

### QA Policy
- Frontend/UI → Playwright 打開 `npm run dev` 的 localhost 或 `wrangler dev` 的 Worker，檢查 DOM、截圖
- Config/Build → Bash 執行 `npm run build`、檢查輸出
- Deploy → Bash 執行 `opennextjs-cloudflare preview`，curl localhost:8787 驗證 response
- Evidence 存 `.sisyphus/evidence/task-{N}-{slug}.{png|txt|json}`

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (foundation, MAX PARALLEL — 7 tasks):
├── T1: Next.js 15 scaffolding + pm scripts [quick]
├── T2: Tailwind v4 + design tokens + dark mode theming [visual-engineering]
├── T3: next-intl i18n setup + zh/en message files [quick]
├── T4: Type definitions + data schemas [quick]
├── T5: Asset pipeline (download screenshots, icons, logo SVG placeholder) [quick]
├── T6: Font setup (next/font + Noto Sans TC + fallback) [quick]
└── T7: wrangler.jsonc + @opennextjs/cloudflare config [quick]

Wave 2 (building blocks, MAX PARALLEL — 7 tasks):
├── T8: Shared Layout (Header w/ lang+theme toggle, Footer) [visual-engineering]
├── T9: 3D Hero (R3F Canvas w/ dynamic ssr:false + fallback img) [artistry]
├── T10: Glassmorphism component lib (iOS section) [visual-engineering]
├── T11: Material 3 component lib (Android section) [visual-engineering]
├── T12: GitHub data source (build-time API fetch: stars/version/contributors) [quick]
├── T13: Feature showcase component [visual-engineering]
└── T14: FAQ + Roadmap + Team components [visual-engineering]

Wave 3 (page composition, MAX PARALLEL — 6 tasks):
├── T15: Home page `/` long-scroll composition + `/en` mirror [visual-engineering]
├── T16: Privacy policy pages (zh + en) [quick]
├── T17: Delete-account pages (zh + en) [quick]
├── T18: SEO: OG tags, sitemap, robots, hreflang [quick]
├── T19: Console ASCII art easter egg [quick]
└── T20: /web/README.md dev+deploy docs [writing]

Wave 4 (validation, MAX PARALLEL — 2 tasks):
├── T21: Playwright E2E smoke tests (5 scenarios) [unspecified-high]
└── T22: Lighthouse + a11y audit + bundle size budget check [unspecified-high]

Wave FINAL (4 parallel reviews):
├── F1: Plan compliance audit [oracle]
├── F2: Code quality review [unspecified-high]
├── F3: Real manual QA [unspecified-high]
└── F4: Scope fidelity check [deep]
→ Present → User okay

Critical Path: T1 → T7 → T8 → T15 → T21 → F1-F4 → user okay
Max Concurrent: 7 (Waves 1 & 2)
Parallel Speedup: ~65% faster than sequential
```

### Dependency Matrix

- **T1**: `-` → all others
- **T2**: T1 → T8, T10, T11, T13, T14
- **T3**: T1 → T8, T15, T16, T17
- **T4**: T1 → T12, T13, T14
- **T5**: T1 → T9, T13
- **T6**: T1 → T8
- **T7**: T1 → T21, deploy
- **T8**: T1, T2, T3, T6 → T15, T16, T17
- **T9**: T1, T5 → T15
- **T10**: T1, T2 → T15
- **T11**: T1, T2 → T15
- **T12**: T1, T4 → T13, T14, T15
- **T13**: T1, T2, T4, T5 → T15
- **T14**: T1, T2, T4 → T15
- **T15**: T8, T9, T10, T11, T12, T13, T14 → T18, T21
- **T16**: T1, T3, T8 → T18, T21
- **T17**: T1, T3, T8 → T18, T21
- **T18**: T15, T16, T17 → T21
- **T19**: T1 → T21
- **T20**: T1, T7 → F1
- **T21**: T7, T15, T16, T17, T18, T19 → F1-F4
- **T22**: T21 → F1-F4

### Agent Dispatch Summary

- **Wave 1 (7)**: T1→`quick`, T2→`visual-engineering`, T3→`quick`, T4→`quick`, T5→`quick`, T6→`quick`, T7→`quick`
- **Wave 2 (7)**: T8→`visual-engineering`, T9→`artistry`, T10→`visual-engineering`, T11→`visual-engineering`, T12→`quick`, T13→`visual-engineering`, T14→`visual-engineering`
- **Wave 3 (6)**: T15→`visual-engineering`, T16→`quick`, T17→`quick`, T18→`quick`, T19→`quick`, T20→`writing`
- **Wave 4 (2)**: T21→`unspecified-high`, T22→`unspecified-high`
- **FINAL (4)**: F1→`oracle`, F2→`unspecified-high`, F3→`unspecified-high`, F4→`deep`

---

## TODOs

- [x] 1. **Next.js 15 scaffolding + package manager scripts**

  **What to do**:
  - `mkdir -p web && cd web`
  - `npx create-next-app@latest . --typescript --app --tailwind --eslint --no-src-dir --import-alias "@/*" --turbopack`
  - 確認 TS strict 模式（`"strict": true` in `tsconfig.json`）
  - 在 `package.json` 加 scripts: `"deploy": "opennextjs-cloudflare deploy"`、`"preview": "opennextjs-cloudflare preview"`、`"cf-build": "opennextjs-cloudflare build"`、`"typecheck": "tsc --noEmit"`
  - 安裝 `@opennextjs/cloudflare`、`wrangler` 為 devDependencies
  - `next.config.ts` 加 `transpilePackages: ['three']`（R3F 要求）+ `initOpenNextCloudflareForDev()` 初始化

  **Must NOT do**:
  - 不使用 Pages Router
  - 不安裝 `@cloudflare/next-on-pages`（已 deprecated）
  - 不用 `src/` layout（使用者未指定時預設 flat）

  **Recommended Agent Profile**:
  - **Category**: `quick` — 純 scaffolding，命令列 + 配置檔
  - **Skills**: `[]`（無需特殊 skill）
  - **Skills Evaluated but Omitted**: `frontend-design`（此階段無視覺工作）

  **Parallelization**:
  - **Can Run In Parallel**: NO（foundation task）
  - **Parallel Group**: Wave 1 起點
  - **Blocks**: All other tasks
  - **Blocked By**: None

  **References**:
  - Context7 `/opennextjs/opennextjs-cloudflare` 文件（已檢索）
  - `create-next-app` 官方 docs: `https://nextjs.org/docs/app/getting-started/installation`
  - `@opennextjs/cloudflare` GitHub: `https://github.com/opennextjs/opennextjs-cloudflare`

  **Acceptance Criteria**:
  - [ ] `ls web/package.json web/next.config.ts web/tsconfig.json` → all exist
  - [ ] `cd web && npm run build` → exits 0
  - [ ] `cd web && npx tsc --noEmit` → no errors
  - [ ] `cd web/package.json` 含 deploy/preview/cf-build 三個 scripts

  **QA Scenarios**:
  ```
  Scenario: 專案 scaffold 完成並可建置
    Tool: Bash
    Preconditions: 乾淨 workspace
    Steps:
      1. `cd /Users/xinshou/IdeaProjects/TigerDuck/web && npm install`
      2. `npm run build`
      3. `npx tsc --noEmit`
    Expected Result: 三個命令全部 exit code 0，產生 `.next/` 目錄
    Evidence: .sisyphus/evidence/task-1-build-success.txt（存命令輸出）

  Scenario: OpenNext adapter 可呼叫
    Tool: Bash
    Preconditions: T1 build 成功
    Steps:
      1. `cd web && npx opennextjs-cloudflare build 2>&1 | tee /tmp/opennext.log`
      2. `test -f .open-next/worker.js && echo OK || echo FAIL`
    Expected Result: `.open-next/worker.js` 存在
    Evidence: .sisyphus/evidence/task-1-opennext-build.txt
  ```

  **Commit**: YES
  - Message: `feat(web): scaffold Next.js 15 App Router project with OpenNext Cloudflare adapter`
  - Files: `web/**`
  - Pre-commit: `cd web && npm run build && npm run typecheck`

- [x] 2. **Tailwind v4 設定 + design tokens + dark mode theming**

  **What to do**:
  - 在 `web/app/globals.css` 使用 Tailwind v4 CSS-first config（`@import "tailwindcss"`）
  - 定義 design tokens（`@theme` block）：
    - 主色：`--color-brand-tiger` (#F05138 橘紅)、`--color-brand-duck` (#FFD54F 鴨黃)、`--color-accent-blue` (#4a90d9，沿用既有 policy)
    - 語意色：`--color-bg`、`--color-surface`、`--color-text`、`--color-muted`
    - 每個 token 都要有 light / dark 兩套（用 `@media (prefers-color-scheme: dark)`）
  - 新增 `web/lib/theme.ts` 提供 `useTheme` hook（讀寫 `localStorage` + `data-theme` attr），支援 "system" / "light" / "dark"
  - 確保 `<html suppressHydrationWarning>` 配合 theme inline script（避免 FOUC）

  **Must NOT do**:
  - 不用 CSS-in-JS（styled-components / emotion）
  - 不用 Tailwind v3 的 `tailwind.config.js`（v4 改用 CSS config）

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering` — 設計系統與主題工作
  - **Skills**: `[frontend-design]`、`[design-system]` — 建立一致的色票與主題系統

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 1)
  - **Blocks**: T8, T10, T11, T13, T14
  - **Blocked By**: T1

  **References**:
  - Tailwind v4 docs: `https://tailwindcss.com/docs/v4-beta`
  - 既有 policy 視覺色：`#f9f9f9` bg, `#fff` surface, `#4a90d9` accent, `#1a1a1a` heading text（從 `tigerduck-app/website/privacy-policy` 提取）
  - React theme pattern: `next-themes` 邏輯但**不**裝 `next-themes` 套件（改手寫，減少依賴）

  **Acceptance Criteria**:
  - [ ] `web/app/globals.css` 有 `@theme` block + dark mode overrides
  - [ ] `web/lib/theme.ts` 匯出 `useTheme()` hook（TS strict）
  - [ ] `npm run build` pass

  **QA Scenarios**:
  ```
  Scenario: 色票在 light/dark 下皆正確渲染
    Tool: Playwright
    Preconditions: T1, T2 完成; `npm run dev` 跑起來
    Steps:
      1. Playwright navigate `http://localhost:3000`
      2. 執行 `document.documentElement.setAttribute('data-theme', 'light')`
      3. 截圖 viewport
      4. 執行 `document.documentElement.setAttribute('data-theme', 'dark')`
      5. 截圖 viewport
      6. 比對 body background 差異 > 50 (RGB distance)
    Expected Result: 兩次截圖背景明顯不同（light 為淡灰、dark 為深色）
    Evidence: .sisyphus/evidence/task-2-theme-light.png + task-2-theme-dark.png

  Scenario: `useTheme` 將選擇寫入 localStorage
    Tool: Playwright
    Preconditions: T2 完成
    Steps:
      1. Navigate; 執行 `window.__useTheme?.('dark')` 或透過 toggle button 點擊
      2. `localStorage.getItem('theme')` 應為 `"dark"`
      3. Reload，`document.documentElement.dataset.theme` 仍為 `"dark"`
    Expected Result: 主題跨 reload 保持
    Evidence: .sisyphus/evidence/task-2-persist.txt
  ```

  **Commit**: YES — see Commit Strategy

- [x] 3. **next-intl i18n 設置 + zh-TW / en 訊息檔**

  **What to do**:
  - `npm install next-intl`
  - 建立 `web/messages/zh-TW.json` 與 `web/messages/en.json`，初始至少含 `hero.title`、`hero.subtitle`、`cta.ios`、`cta.android`、`nav.features`、`nav.download`、`nav.policy`、`footer.disclaimer`
  - 建立 `web/i18n/routing.ts`（locales: `["zh-TW", "en"]`, defaultLocale: `"zh-TW"`, localePrefix: `"as-needed"`）
  - 建立 `web/middleware.ts` 使用 `createMiddleware`
  - 建立 `web/i18n/request.ts` + `web/app/[locale]/layout.tsx`
  - 首頁 path 結構：`/`（zh 預設）、`/en`、`/privacy-policy`、`/en/privacy-policy`

  **Must NOT do**:
  - 不自己手寫 i18n routing（next-intl 已處理）
  - 不把所有文字都用英文 key（中英對應務必完整）

  **Recommended Agent Profile**:
  - **Category**: `quick` — 主要是 setup + 設定檔
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 1)
  - **Blocks**: T8, T15, T16, T17
  - **Blocked By**: T1

  **References**:
  - next-intl App Router guide: `https://next-intl.dev/docs/getting-started/app-router`
  - 既有 `tigerduck-app/README.md` 與 `README_en.md` → 可作為 feature 文案來源

  **Acceptance Criteria**:
  - [ ] `web/messages/zh-TW.json` + `web/messages/en.json` 存在，keys 一致
  - [ ] `web/middleware.ts` + `web/i18n/routing.ts` 存在
  - [ ] `curl localhost:3000/` 回 zh-TW HTML（`lang="zh-TW"`）
  - [ ] `curl localhost:3000/en` 回 en HTML（`lang="en"`）

  **QA Scenarios**:
  ```
  Scenario: 根路徑回繁中
    Tool: Bash (curl)
    Preconditions: `npm run dev`
    Steps:
      1. `curl -s http://localhost:3000/ | grep -Eo 'lang="[^"]+"'`
    Expected Result: 輸出 `lang="zh-TW"`
    Evidence: .sisyphus/evidence/task-3-root-lang.txt

  Scenario: /en 回英文
    Tool: Bash (curl)
    Preconditions: `npm run dev`
    Steps:
      1. `curl -s http://localhost:3000/en | grep -Eo 'lang="[^"]+"'`
    Expected Result: 輸出 `lang="en"`
    Evidence: .sisyphus/evidence/task-3-en-lang.txt

  Scenario: messages 檔 zh/en key 完全對應（無遺漏）
    Tool: Bash (jq)
    Preconditions: T3 完成
    Steps:
      1. `diff <(jq -r 'paths | join(".")' web/messages/zh-TW.json | sort) <(jq -r 'paths | join(".")' web/messages/en.json | sort)`
    Expected Result: diff 為空
    Evidence: .sisyphus/evidence/task-3-key-parity.txt
  ```

  **Commit**: YES

- [x] 4. **Domain types + data schemas**

  **What to do**:
  - 建立 `web/types/feature.ts`（`Feature = { id, icon, title, description, screenshot, platform: "ios" | "android" | "both" }`）
  - 建立 `web/types/roadmap.ts`（`RoadmapItem = { id, category, title, description, status: "done" | "in-progress" | "planned" }`）
  - 建立 `web/types/contributor.ts`（`Contributor = { login, avatar, html_url, contributions, platform: "ios" | "android" }`）
  - 建立 `web/types/stats.ts`（`ProjectStats = { iosStars, androidStars, iosContributors, androidContributors, latestVersion, latestReleaseDate }`）
  - 建立 `web/data/features.ts`（6 個 core features，資料從 README 提取）
  - 建立 `web/data/roadmap.ts`（從 README 的 Roadmap section 提取，對應 done/planned 狀態）
  - 建立 `web/data/faq.ts`（5-7 題常見問題：SSO 安全、NTUST 關聯、資料儲存、系統需求、如何加入內測）

  **Must NOT do**:
  - 不把 feature 文案寫死在 component 內（必須從 `data/` 讀）
  - 不在此任務發真實 GitHub API call（那是 T12 的工作；這裡只是靜態 FAQ/features/roadmap）

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 1)
  - **Blocks**: T12, T13, T14
  - **Blocked By**: T1

  **References**:
  - `/Users/xinshou/IdeaProjects/TigerDuck/README.md` — features, roadmap 來源
  - `/Users/xinshou/IdeaProjects/TigerDuck/README_en.md` — 英文 features
  - Android README: `https://github.com/tigerduck-app/tigerduck-app-android/blob/main/README.md`

  **Acceptance Criteria**:
  - [ ] `web/types/*.ts` 5 個 type 定義齊全（feature, roadmap, contributor, stats, faq）
  - [ ] `web/data/features.ts` 有 6 個 feature
  - [ ] `web/data/roadmap.ts` 至少 10 個 roadmap items
  - [ ] `web/data/faq.ts` 至少 5 題

  **QA Scenarios**:
  ```
  Scenario: Type check 通過
    Tool: Bash
    Preconditions: T1, T4 完成
    Steps:
      1. `cd web && npx tsc --noEmit`
    Expected Result: exit 0
    Evidence: .sisyphus/evidence/task-4-types.txt

  Scenario: Data 陣列長度符合預期
    Tool: Bash (node REPL)
    Preconditions: T4 完成
    Steps:
      1. `cd web && node -e "import('./data/features.ts').then(m=>console.log(m.features.length))"` (adapt for tsx)
      2. 或用 `grep -c "id:" web/data/features.ts`
    Expected Result: features 6 個、roadmap ≥ 10、faq ≥ 5
    Evidence: .sisyphus/evidence/task-4-data-counts.txt
  ```

  **Commit**: YES

- [x] 5. **Asset pipeline：下載產品截圖 + logo placeholder**

  **What to do**:
  - 建立 `web/public/screenshots/` 目錄
  - 從 GitHub user-attachments 下載 README 中的 6 張 app 截圖（作業、課表、圖書館、客製化設定、客製化 Tab、客製化首頁）存為：
    - `web/public/screenshots/homework-ios.png`
    - `web/public/screenshots/classtable-ios.png`
    - `web/public/screenshots/library-ios.png`
    - `web/public/screenshots/customize-settings-ios.png`
    - `web/public/screenshots/customize-tab-ios.png`
    - `web/public/screenshots/customize-home-ios.png`
  - 從 Android README 下載截圖為 `web/public/screenshots/*-android.png`（至少 1 張）
  - 從 README 下載 banner 存為 `web/public/brand/banner.png`
  - 建立 `web/public/brand/logo-placeholder.svg`（簡單的 tiger + duck 幾何 SVG，純 placeholder，使用者會補）
  - 建立 `web/public/devices/iphone-17-pro.png.placeholder` 空檔 + `web/public/devices/pixel-10-pro.png.placeholder` 空檔（使用者會補）
  - 建立 `web/public/screenshots/README.md` 說明：來源 URL、授權、使用者如何替換

  **Must NOT do**:
  - 不在 JSX 中 hotlink `https://github.com/user-attachments/...`（違反 Must NOT）
  - 不生成 AI 假圖（使用者會補真圖）

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 1)
  - **Blocks**: T9, T13
  - **Blocked By**: T1

  **References**:
  - 原始截圖 URL 列表（從 `tigerduck-app/tigerduck-app` README 與 Android README 提取，執行者應在任務執行時用 `gh api` 或 `curl` 取得最新可用連結；若 JWT 失效需改抓 repo `main` branch 的截圖 fallback 到 placeholder）

  **Acceptance Criteria**:
  - [ ] `ls web/public/screenshots/*.png | wc -l` ≥ 6
  - [ ] `web/public/brand/logo-placeholder.svg` 存在且為有效 SVG
  - [ ] `web/public/screenshots/README.md` 存在

  **QA Scenarios**:
  ```
  Scenario: 所有截圖可被 Next.js Image 載入
    Tool: Playwright
    Preconditions: T5 完成 + `npm run dev`
    Steps:
      1. 建立臨時 test page 引用所有 screenshot，navigate to it
      2. `await page.waitForLoadState('networkidle')`
      3. 檢查 no 404 in console
    Expected Result: 所有圖片 HTTP 200
    Evidence: .sisyphus/evidence/task-5-screenshots-loaded.png

  Scenario: SVG placeholder 有效
    Tool: Bash
    Steps:
      1. `xmllint --noout web/public/brand/logo-placeholder.svg`
    Expected Result: exit 0（合法 XML）
    Evidence: .sisyphus/evidence/task-5-svg-valid.txt
  ```

  **Commit**: YES

- [x] 6. **Fonts：next/font + Noto Sans TC**

  **What to do**:
  - 在 `web/app/layout.tsx`（root）引入 `next/font/google`：
    ```ts
    import { Noto_Sans_TC, Inter } from "next/font/google";
    const notoSansTC = Noto_Sans_TC({ subsets: ["latin"], variable: "--font-noto-tc", display: "swap" });
    const inter = Inter({ subsets: ["latin"], variable: "--font-inter", display: "swap" });
    ```
  - 在 `<html>` class 加 `${notoSansTC.variable} ${inter.variable}`
  - 在 `globals.css` 的 `@theme` block 加 `--font-sans: var(--font-noto-tc), var(--font-inter), system-ui, sans-serif;`
  - 確保 Cloudflare Workers 可處理 next/font（OpenNext 支援，但要避免 `@next/font` legacy package）

  **Must NOT do**:
  - 不用 `@next/font`（已 deprecated，統一用 `next/font`）
  - 不用 `<link>` 直接連到 Google Fonts（失去 next/font 的 self-hosting 優化）

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 1)
  - **Blocks**: T8
  - **Blocked By**: T1

  **References**:
  - next/font docs: `https://nextjs.org/docs/app/api-reference/components/font`
  - 既有 policy 用 `-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Noto Sans TC"` → 我們改用 next/font 的 self-hosted Noto Sans TC

  **Acceptance Criteria**:
  - [ ] `web/app/layout.tsx` 匯入 `Noto_Sans_TC`
  - [ ] `npm run build` 不出現 font fetch error
  - [ ] 頁面 CSS 中 `--font-noto-tc` 定義存在

  **QA Scenarios**:
  ```
  Scenario: 頁面渲染使用 Noto Sans TC
    Tool: Playwright
    Preconditions: T6 完成; dev server 運行
    Steps:
      1. Navigate `http://localhost:3000`
      2. `const fontFamily = await page.evaluate(() => getComputedStyle(document.body).fontFamily)`
      3. 斷言 `fontFamily.includes("Noto")` 或 `getComputedStyle` 顯示 `--font-noto-tc` 解析成功
    Expected Result: body computed font-family 含 Noto Sans TC
    Evidence: .sisyphus/evidence/task-6-font-family.txt
  ```

  **Commit**: YES

- [x] 7. **Wrangler config + @opennextjs/cloudflare adapter 配置**

  **What to do**:
  - 建立 `web/wrangler.jsonc`：
    ```jsonc
    {
      "$schema": "node_modules/wrangler/config-schema.json",
      "main": ".open-next/worker.js",
      "name": "tigerduck-website",
      "compatibility_date": "2024-12-01",
      "compatibility_flags": ["nodejs_compat", "global_fetch_strictly_public"],
      "assets": { "directory": ".open-next/assets", "binding": "ASSETS" },
      "routes": [{ "pattern": "tigerduck.app/*", "zone_name": "tigerduck.app" }]
    }
    ```
  - 建立 `web/open-next.config.ts`：
    ```ts
    import { defineCloudflareConfig } from "@opennextjs/cloudflare";
    export default defineCloudflareConfig({});
    ```
  - 在 `next.config.ts` 呼叫 `initOpenNextCloudflareForDev()`（已在 T1 加，此處確認）
  - 建立 `.dev.vars.example`（空 placeholder，以後放 env vars）
  - 更新 `.gitignore`：加 `.open-next/`、`.wrangler/`、`.dev.vars`

  **Must NOT do**:
  - 不 commit `.dev.vars`（含 secrets）
  - 不用舊 `wrangler.toml`（改用 `.jsonc` 為 2026 推薦格式）
  - 不開啟 `images.binding`（Free plan 不支援，需確認 paid plan）

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 1)
  - **Blocks**: T21, production deploy
  - **Blocked By**: T1

  **References**:
  - `@opennextjs/cloudflare` 文件（已用 Context7 檢索）
  - Wrangler config schema: `https://developers.cloudflare.com/workers/wrangler/configuration/`

  **Acceptance Criteria**:
  - [ ] `web/wrangler.jsonc` 存在，含 `nodejs_compat` + `global_fetch_strictly_public`
  - [ ] `web/open-next.config.ts` 存在
  - [ ] `cd web && npm run cf-build` 成功（產出 `.open-next/worker.js`）
  - [ ] `npx opennextjs-cloudflare preview` 可啟動本機 Worker

  **QA Scenarios**:
  ```
  Scenario: OpenNext build 產出有效 worker
    Tool: Bash
    Preconditions: T1-T7 完成
    Steps:
      1. `cd web && npm run cf-build 2>&1 | tee /tmp/cf-build.log`
      2. `test -f .open-next/worker.js`
      3. `test -d .open-next/assets`
    Expected Result: worker.js 與 assets 目錄存在
    Evidence: .sisyphus/evidence/task-7-cf-build.log

  Scenario: 本機 Worker preview 可回 200
    Tool: Bash (curl)
    Preconditions: T7 完成
    Steps:
      1. `cd web && npx opennextjs-cloudflare preview --port 8787 &`
      2. `sleep 5 && curl -sf -o /dev/null -w "%{http_code}" http://localhost:8787/`
      3. `kill %1`
    Expected Result: HTTP 200
    Evidence: .sisyphus/evidence/task-7-preview-http.txt
  ```

  **Commit**: YES

- [x] 8. **Shared Layout：Header（含 lang + theme toggle）+ Footer**

  **What to do**:
  - 建立 `web/components/layout/Header.tsx`（client component）：
    - 左側 logo + 品牌名「TigerDuck」
    - 中間 nav：Features / Download / Roadmap / Team / FAQ（anchor links 指向 `#features` 等）
    - 右側：LanguageSwitcher（zh ↔ en，保留當前路徑）、ThemeToggle（system/light/dark 三態 icon button）、GitHub link icon
    - 響應式：手機 <768px 折疊成漢堡選單
  - 建立 `web/components/layout/Footer.tsx`：
    - 三欄：About（由臺科學生建造 + **免責聲明：本專案為學生獨立開發，非 NTUST 官方專案**）/ Links（iOS repo、Android repo、Policy、Delete-account、Discord、GitHub Releases APK、TestFlight）/ Contact（tigerduckapp@gmail.com）
    - 底部：© 2026 TigerDuck Contributors, AGPL-3.0 licensed
  - 建立 `web/components/LanguageSwitcher.tsx` 與 `web/components/ThemeToggle.tsx`
  - 在 `web/app/[locale]/layout.tsx` 引用 Header + Footer

  **Must NOT do**:
  - 不用 NTUST logo 或校徽
  - 不在 Header/Footer 寫死文字（全部走 next-intl messages）

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
  - **Skills**: `[frontend-design]` — 品牌一致性 + a11y

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 2)
  - **Blocks**: T15, T16, T17
  - **Blocked By**: T1, T2, T3, T6

  **References**:
  - 既有 policy 視覺：Noto Sans TC + 720px container + 4a90d9 accent
  - next-intl `Link` 與 `useRouter`：`https://next-intl.dev/docs/routing/navigation`

  **Acceptance Criteria**:
  - [ ] Header + Footer 在所有頁面皆顯示
  - [ ] LanguageSwitcher 切換後 URL 有 `/en` prefix 且內容為英文
  - [ ] ThemeToggle 三態輪替且寫入 localStorage
  - [ ] Footer 包含「非 NTUST 官方專案」免責聲明

  **QA Scenarios**:
  ```
  Scenario: Language 切換保留路徑
    Tool: Playwright
    Preconditions: T8 + /about 類長頁 scroll 到某位置
    Steps:
      1. Navigate `http://localhost:3000/#features`
      2. Click LanguageSwitcher → "English"
      3. `await expect(page).toHaveURL(/\/en/)`
      4. Scroll 位置保留（tolerance 200px）
    Expected Result: URL 變 `/en#features`，頁面用英文
    Evidence: .sisyphus/evidence/task-8-lang-switch.png

  Scenario: Theme toggle 三態輪替
    Tool: Playwright
    Steps:
      1. Navigate, click ThemeToggle → `data-theme="light"`
      2. Click again → `"dark"`
      3. Click again → `"system"`
      4. `localStorage.getItem('theme')` 為 `"system"`
    Expected Result: 三態循環正確
    Evidence: .sisyphus/evidence/task-8-theme-toggle.txt

  Scenario: Footer 免責聲明可見
    Tool: Playwright
    Steps:
      1. Navigate，scroll to footer
      2. 斷言文字「非 NTUST 官方專案」或等效英文存在於 DOM
    Expected Result: disclaimer 存在
    Evidence: .sisyphus/evidence/task-8-disclaimer.png
  ```

  **Commit**: YES

- [x] 9. **3D Hero：R3F Canvas + dynamic ssr:false + WebGL fallback**

  **What to do**:
  - `npm install three @react-three/fiber @react-three/drei`
  - 建立 `web/components/hero/Hero3D.tsx`（**default export**，client component：`"use client"`）：
    - `<Canvas frameloop="demand" dpr={[1, 1.5]} performance={{ min: 0.5, debounce: 200 }}>`
    - 兩個漂浮手機：一個帶 iOS screenshot texture，一個帶 Android screenshot texture
    - 使用 `@react-three/drei` 的 `Float` 製作漂浮
    - 環境光 + rim light（glow 光暈）
    - `<OrbitControls enableZoom={false} autoRotate autoRotateSpeed={0.3} />`
    - `prefers-reduced-motion` 時停用 autoRotate + Float
  - 建立 `web/components/hero/HeroSection.tsx`（非 client）：
    - 動態載入 Hero3D：`const Hero3D = dynamic(() => import('./Hero3D'), { ssr: false, loading: () => <HeroFallback /> })`
    - 建立 `HeroFallback.tsx`（靜態 2D 圖片 fallback）
    - WebGL 偵測：在 client 初始化時 try `document.createElement('canvas').getContext('webgl2')`；失敗則渲染 fallback
  - 背景：加一個 subtle 粒子 field（`@react-three/drei` `Points` 或自行 buffer geometry）
  - 靠左 overlay：標語（從 messages 讀）+ 雙平台 CTA 按鈕（連結 TestFlight / Discord）

  **Must NOT do**:
  - 不在 Server Component 中 import `three` 或 `@react-three/fiber`（SSR 會 crash）
  - 不用 `useFrame` 做重度每幀計算（耗電）
  - 不把 3D 作為阻塞主要內容的元素（fallback 必須在 3D 失敗時展示完整 hero）

  **Recommended Agent Profile**:
  - **Category**: `artistry` — 需要結合 R3F、效能、fallback、a11y 的創意整合
  - **Skills**: `[frontend-design]`

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 2)
  - **Blocks**: T15
  - **Blocked By**: T1, T5

  **References**:
  - R3F docs（Context7 已檢索）：on-demand rendering、adaptive DPR、instancing
  - `@react-three/drei` Float + Points + OrbitControls
  - `next/dynamic` `ssr: false` pattern: `https://nextjs.org/docs/app/building-your-application/optimizing/lazy-loading`

  **Acceptance Criteria**:
  - [ ] `Hero3D.tsx` 是 client component 且由 `dynamic(ssr: false)` 載入
  - [ ] `HeroFallback.tsx` 無 WebGL 時可完整展示 hero
  - [ ] 在 prefers-reduced-motion 下 autoRotate 關閉
  - [ ] Bundle size budget：3D 相關 chunk ≤ 300kb gzipped

  **QA Scenarios**:
  ```
  Scenario: WebGL 可用時 3D Canvas 渲染
    Tool: Playwright
    Preconditions: T9 + dev server
    Steps:
      1. Navigate `http://localhost:3000`
      2. `await page.waitForSelector('canvas')`
      3. Screenshot hero area
      4. 斷言 canvas element 存在且 > 200px 高
    Expected Result: canvas 出現，截圖可見手機 3D 漂浮
    Evidence: .sisyphus/evidence/task-9-3d-hero.png

  Scenario: WebGL 不可用時 fallback
    Tool: Playwright
    Steps:
      1. Launch browser with `--disable-webgl` flag 或 override `HTMLCanvasElement.prototype.getContext`
      2. Navigate，waitForSelector `[data-testid="hero-fallback"]`
      3. 斷言 `<canvas>` 不存在，但 hero 標語、CTA 仍可見
    Expected Result: fallback 可見，CTAs 正常
    Evidence: .sisyphus/evidence/task-9-fallback.png

  Scenario: Reduced motion 關閉動畫
    Tool: Playwright
    Steps:
      1. `await page.emulateMedia({ reducedMotion: 'reduce' })`
      2. Navigate
      3. 等 3 秒後比對兩次截圖（應一致，無自動旋轉）
    Expected Result: 兩次截圖 pixel diff < 1%
    Evidence: .sisyphus/evidence/task-9-reduced-motion-a.png + task-9-reduced-motion-b.png
  ```

  **Commit**: YES

- [x] 10. **Glassmorphism component library（iOS section 專用）**

  **What to do**:
  - 建立 `web/components/ios/` 目錄
  - 建立 `GlassCard.tsx`：`backdrop-blur-xl bg-white/10 dark:bg-white/5 border border-white/20 rounded-3xl` + soft shadow + noise texture overlay
  - 建立 `DynamicIslandMock.tsx`：模擬 iOS 26 Dynamic Island 的 pill 形狀 + expand/compress 動畫（CSS only，無 JS）
  - 建立 `IOSDeviceFrame.tsx`：iPhone 17 Pro frame（device mockup），內嵌 `<img>` 為截圖，使用 `.placeholder` 檔時顯示灰框
  - 建立 `IOSShowcase.tsx`：整合區塊，包含標題「原汁原味 iOS 體驗」、子標「Dynamic Island、Widget、Live Activity 全支援」、GlassCard 列表 3 張
  - 色系：使用 `--color-bg` 的 iOS tint（偏藍灰），背景加一層 glass gradient

  **Must NOT do**:
  - 不在 Android section 重用 GlassCard（視覺衝突）
  - 不過度使用 backdrop-filter 導致 Safari mobile 卡頓（限制在 < 5 個同時可見 GlassCard）

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
  - **Skills**: `[frontend-design]`、`[liquid-glass-design]` — 專門處理 iOS 26 Liquid Glass 設計語言

  **Parallelization**: YES (Wave 2) | **Blocks**: T15 | **Blocked By**: T1, T2

  **References**:
  - iOS 26 Liquid Glass 官方設計：`https://developer.apple.com/design/human-interface-guidelines/`
  - 既有 `swift/TigerDuck` SwiftUI Theme 定義作為色彩參考

  **Acceptance Criteria**:
  - [ ] 5 個 component 都在 `web/components/ios/`
  - [ ] GlassCard 在 dark mode 下仍清楚可讀（WCAG AA）

  **QA Scenarios**:
  ```
  Scenario: GlassCard 渲染含 backdrop-filter
    Tool: Playwright
    Preconditions: T10 + dev 頁面引用 GlassCard
    Steps:
      1. Navigate test page with GlassCard
      2. `const bf = await page.evaluate(() => getComputedStyle(document.querySelector('[data-glass-card]')).backdropFilter)`
      3. 斷言 bf 含 `blur`
    Expected Result: `backdrop-filter: blur(...)` 套用
    Evidence: .sisyphus/evidence/task-10-glass-bf.txt

  Scenario: IOSDeviceFrame 在缺少截圖時退化為 placeholder
    Tool: Playwright
    Steps:
      1. Remove `public/screenshots/homework-ios.png`（臨時）
      2. Navigate, 斷言 `[data-testid="device-placeholder"]` 可見
      3. 還原檔案
    Expected Result: placeholder 顯示
    Evidence: .sisyphus/evidence/task-10-placeholder.png
  ```

  **Commit**: YES

- [x] 11. **Material 3 component library（Android section 專用）**

  **What to do**:
  - 建立 `web/components/android/` 目錄
  - 建立 `M3Card.tsx`：Material 3 filled/elevated card，圓角 16px、shadow elevation、press state ripple（CSS-only）
  - 建立 `M3Chip.tsx`：assist chip / filter chip
  - 建立 `M3FAB.tsx`：Floating Action Button（作為 Android 區塊的 CTA 風格元素）
  - 建立 `AndroidDeviceFrame.tsx`：Pixel 10 Pro frame 設備外框
  - 建立 `TimeSliderDemo.tsx`：示範 Android 時光機「流動軌道 / 課程區塊」切換（CSS 動畫，非互動）
  - 建立 `AndroidShowcase.tsx`：整合區塊，標題「Material You，讓手機感覺是你的」、M3Card 展示時光機、自訂主題色、M3 expressive 元素
  - 色系：使用 Material You dynamic color tokens，accent 主色可以參考 Android Monet 的 tonal palette 生成

  **Must NOT do**:
  - 不用 `@mui/material`（過重且非 M3 純實作；用 CSS 手寫）
  - 不把 Android 特色（時光機雙樣式）錯放到 iOS 區塊

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
  - **Skills**: `[frontend-design]`、`[compose-multiplatform-patterns]` — M3 視覺規範

  **Parallelization**: YES (Wave 2) | **Blocks**: T15 | **Blocked By**: T1, T2

  **References**:
  - Material 3 specs: `https://m3.material.io/`
  - Android README 時光機描述：「支援流動軌道與課程區塊兩種樣式」

  **Acceptance Criteria**:
  - [ ] 6 個 component 都在 `web/components/android/`
  - [ ] TimeSliderDemo 動畫在 prefers-reduced-motion 時暫停

  **QA Scenarios**:
  ```
  Scenario: M3Card 有 Material elevation shadow
    Tool: Playwright
    Steps:
      1. Navigate test page with M3Card
      2. `const shadow = await page.evaluate(() => getComputedStyle(document.querySelector('[data-m3-card]')).boxShadow)`
      3. 斷言 shadow 非 `"none"`
    Expected Result: box-shadow 存在
    Evidence: .sisyphus/evidence/task-11-m3-shadow.txt

  Scenario: TimeSliderDemo 兩種樣式切換
    Tool: Playwright
    Steps:
      1. Navigate，截圖 `[data-style="track"]`
      2. 等 3s（CSS animation），截圖 `[data-style="block"]`
      3. 斷言兩者像素差異 > 5%
    Expected Result: 兩種樣式可辨識
    Evidence: .sisyphus/evidence/task-11-slider-a.png + task-11-slider-b.png
  ```

  **Commit**: YES

- [x] 12. **GitHub 資料源（build-time API fetch）**

  **What to do**:
  - 建立 `web/lib/github.ts`：
    - `fetchRepoStats(owner, repo)` → 回 `{ stars, latestRelease, latestVersion }` 用 `https://api.github.com/repos/{owner}/{repo}` + `/releases/latest`
    - `fetchContributors(owner, repo)` → 回 `Contributor[]`（從 `/repos/{owner}/{repo}/contributors`）
  - 在 `web/app/[locale]/page.tsx` 使用 React Server Component 的 `async`，call `fetchRepoStats('tigerduck-app', 'tigerduck-app')` + `fetchRepoStats('tigerduck-app', 'tigerduck-app-android')` + 合併 contributors
  - **重要**：使用 ISR `export const revalidate = 3600`（每小時刷新），避免 Cloudflare Workers 每次 request 打 GitHub API 被 rate-limit
  - API fetch 失敗時 fallback 到靜態資料（`data/stats-fallback.ts` 定義合理預設）
  - 過濾 bot accounts（`[bot]` suffix、claude bot、dependabot）

  **Must NOT do**:
  - 不 hardcode stars 數字或 contributor 名單
  - 不在 client component 直接 fetch GitHub API（CORS + 洩漏可能的 token）
  - 不做 DDoS 式每 request fetch（用 ISR）

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `[]`

  **Parallelization**: YES (Wave 2) | **Blocks**: T13, T14, T15 | **Blocked By**: T1, T4

  **References**:
  - GitHub REST API: `https://docs.github.com/en/rest/repos/repos#get-a-repository`
  - Next.js ISR with App Router: `https://nextjs.org/docs/app/building-your-application/caching#time-based-revalidation`

  **Acceptance Criteria**:
  - [ ] `web/lib/github.ts` 匯出 `fetchRepoStats` + `fetchContributors` + `mergeContributors`
  - [ ] 具 fallback 機制
  - [ ] `export const revalidate = 3600` 在使用該函式的 page 中

  **QA Scenarios**:
  ```
  Scenario: 真實 API call 回傳 schema 正確
    Tool: Bash (node tsx)
    Preconditions: T12 完成
    Steps:
      1. `cd web && npx tsx -e "import {fetchRepoStats} from './lib/github'; fetchRepoStats('tigerduck-app','tigerduck-app').then(r=>console.log(JSON.stringify(r)))"`
      2. 驗證回傳含 `stars: number`, `latestVersion: string`
    Expected Result: object 含 stars >= 30（實際至少 33 顆），latestVersion 非空字串
    Evidence: .sisyphus/evidence/task-12-api.json

  Scenario: API 失敗時 fallback
    Tool: Bash
    Steps:
      1. 修改 `fetchRepoStats` 暫時 throw
      2. 確認 page 仍渲染（使用 fallback data）
      3. 還原
    Expected Result: fallback 生效，頁面不 crash
    Evidence: .sisyphus/evidence/task-12-fallback.txt
  ```

  **Commit**: YES

- [x] 13. **Feature showcase component（6 核心功能）**

  **What to do**:
  - 建立 `web/components/features/FeatureCard.tsx`：接收 `Feature` props，呈現 icon + title + description + screenshot（IOSDeviceFrame / AndroidDeviceFrame / 兩者並列）
  - 建立 `web/components/features/FeaturesSection.tsx`：讀 `data/features.ts`，渲染 6 張 FeatureCard
    - 排版：desktop 2×3 grid、mobile 單欄
    - 每張 card 顯示 `platform` badge（iOS / Android / 雙平台）
  - 動畫：scroll-in fade-up（`prefers-reduced-motion` 時停用）
  - 每個 feature 的 description 從 `messages` i18n 讀取，不直接寫在 component

  **Must NOT do**:
  - 不為每個 feature 寫獨立 component（違反 DRY，6 個共用 FeatureCard）
  - 不在 feature description 中塞入 roadmap 未完成項目

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
  - **Skills**: `[frontend-design]`

  **Parallelization**: YES (Wave 2) | **Blocks**: T15 | **Blocked By**: T1, T2, T4, T5

  **Acceptance Criteria**:
  - [ ] FeatureCard 可重用，無硬編碼文案
  - [ ] FeaturesSection 渲染 6 張
  - [ ] 每張 card 顯示平台 badge

  **QA Scenarios**:
  ```
  Scenario: 6 個 feature 都渲染
    Tool: Playwright
    Steps:
      1. Navigate `http://localhost:3000/#features`
      2. `const cards = await page.locator('[data-testid="feature-card"]').count()`
      3. 斷言 cards === 6
    Expected Result: 6 張 card
    Evidence: .sisyphus/evidence/task-13-features.png

  Scenario: 平台 badge 正確
    Tool: Playwright
    Steps:
      1. 檢查「作業」card 的 badge 為「雙平台」、「Live Activity」card 為「iOS」
    Expected Result: badges 對應 data 設定
    Evidence: .sisyphus/evidence/task-13-badges.txt
  ```

  **Commit**: YES

- [x] 14. **FAQ + Roadmap + Team components**

  **What to do**:
  - 建立 `web/components/sections/RoadmapSection.tsx`：讀 `data/roadmap.ts`，依 category 分組（教務/選課/圖書館/校園資訊/校園生活），每項顯示 title + status icon（✓ 已完成 / 🛠 開發中 / ○ 規劃中）+ description
  - 建立 `web/components/sections/TeamSection.tsx`：從 T12 的 `fetchContributors` 兩個 repo 合併去重，顯示 avatar + name + GitHub link + 貢獻數；右下角顯示「成為貢獻者」CTA 連到 iOS / Android repo
  - 建立 `web/components/sections/FAQSection.tsx`：讀 `data/faq.ts`，使用原生 `<details>` + `<summary>` 實作可展開的 FAQ（a11y 原生）
  - 建立 `web/components/sections/StatsSection.tsx`：顯示 T12 抓到的 stars、版本、contributors 數，用大字呈現（`7xl font-bold`）
  - 所有區段加 `id="roadmap"`、`id="team"`、`id="faq"` 供 anchor nav

  **Must NOT do**:
  - 不用 JS 模擬 accordion（`<details>` 原生免費 a11y）
  - 不在 TeamSection 虛報人數（只顯示實際 API 回傳）

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
  - **Skills**: `[frontend-design]`

  **Parallelization**: YES (Wave 2) | **Blocks**: T15 | **Blocked By**: T1, T2, T4

  **Acceptance Criteria**:
  - [ ] 4 個 section component 齊全
  - [ ] 每個 section 有可 anchor 的 `id`
  - [ ] Team 成員不虛報

  **QA Scenarios**:
  ```
  Scenario: FAQ 原生展開
    Tool: Playwright
    Steps:
      1. Navigate `/#faq`
      2. Click 第一個 `<summary>`
      3. 斷言對應 `<details>` 有 `open` attribute
    Expected Result: 原生展開工作
    Evidence: .sisyphus/evidence/task-14-faq-open.png

  Scenario: Roadmap status icon 正確
    Tool: Playwright
    Steps:
      1. Navigate `/#roadmap`
      2. 檢查「作業」項目為 ✓、「行事曆+」為 ○
    Expected Result: icon 對應 data
    Evidence: .sisyphus/evidence/task-14-roadmap.png

  Scenario: Team 實際人數顯示
    Tool: Playwright
    Steps:
      1. Navigate `/#team`
      2. count avatars
      3. 斷言 count >= 5 且 count <= 20（合理範圍）
    Expected Result: 顯示實際 contributors
    Evidence: .sisyphus/evidence/task-14-team-count.txt
  ```

  **Commit**: YES

- [x] 15. **Home page `/` long-scroll 組合 + `/en` mirror**

  **What to do**:
  - 建立 `web/app/[locale]/page.tsx`（Server Component，`async`）：
    ```tsx
    export const revalidate = 3600;
    export default async function Home() {
      const stats = await fetchRepoStats(...);
      const contributors = await fetchContributors(...);
      return (
        <>
          <HeroSection />
          <StatsSection stats={stats} />
          <FeaturesSection />
          <IOSShowcase />
          <AndroidShowcase />
          <RoadmapSection />
          <TeamSection contributors={contributors} />
          <FAQSection />
        </>
      );
    }
    ```
  - 每個區段之間加 scroll margin（nav anchor 偏移）
  - CTAs：Hero 有主 CTA（加入 iOS 內測 + 加入 Android 內測），各區塊末尾重複 CTA
  - **正式版 CTA 預留區塊**：在每個 CTA 位置附近放 `{/* FUTURE: <AppStoreBadge /> <PlayStoreBadge /> <FDroidBadge /> */}` 註解（待上架時取消註解），同步建立這些 component 但目前不渲染
  - 在 `web/components/cta/` 建立 `TestFlightCTA.tsx`、`DiscordCTA.tsx`、`AppStoreBadge.tsx`（暫未使用）、`PlayStoreBadge.tsx`（暫未使用）、`FDroidBadge.tsx`（暫未使用）

  **Must NOT do**:
  - 不把任何段落內容寫死在 page.tsx（全部走 section components）
  - 不直接 import `three` / `@react-three/fiber`（透過 `HeroSection` 的 dynamic import 間接使用）

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
  - **Skills**: `[frontend-design]`

  **Parallelization**: NO (critical path) | **Blocks**: T18, T21 | **Blocked By**: T8, T9, T10, T11, T12, T13, T14

  **Acceptance Criteria**:
  - [ ] `/` 渲染全部 8 個區段 + Hero
  - [ ] `/en` 渲染英文版
  - [ ] 5 個 CTA component 存在（2 可見、3 註解隱藏）
  - [ ] `npm run build` pass

  **QA Scenarios**:
  ```
  Scenario: 長捲動首頁包含所有區段
    Tool: Playwright
    Steps:
      1. Navigate `http://localhost:3000`
      2. 檢查 DOM 中 id="hero", "stats", "features", "ios", "android", "roadmap", "team", "faq" 皆存在
    Expected Result: 8 個 section id 都存在
    Evidence: .sisyphus/evidence/task-15-sections.txt

  Scenario: 正式版 CTA 目前為 HTML 註解
    Tool: Bash (grep)
    Steps:
      1. `grep -c "FUTURE: <AppStoreBadge" web/app/[locale]/page.tsx`
    Expected Result: ≥ 1（確實用註解隱藏，未渲染）
    Evidence: .sisyphus/evidence/task-15-hidden-ctas.txt

  Scenario: iOS beta CTA 指向 TestFlight
    Tool: Playwright
    Steps:
      1. Navigate
      2. `const href = await page.locator('[data-testid="ios-beta-cta"]').getAttribute('href')`
      3. 斷言 `href === "https://testflight.apple.com/join/eVt9Gjkw"`
    Expected Result: href 完全一致
    Evidence: .sisyphus/evidence/task-15-testflight-cta.txt

  Scenario: Android beta CTA 指向 Discord placeholder
    Tool: Playwright
    Steps:
      1. `const href = await page.locator('[data-testid="android-beta-cta"]').getAttribute('href')`
      2. 斷言 `href === "https://tigerduck.app/discord"`
    Expected Result: 連結正確
    Evidence: .sisyphus/evidence/task-15-discord-cta.txt
  ```

  **Commit**: YES

- [x] 16. **Privacy policy pages（zh + en）**

  **What to do**:
  - 建立 `web/app/[locale]/privacy-policy/page.tsx`
  - 中文內容：**逐字沿用** `https://github.com/tigerduck-app/website/blob/main/privacy-policy/index.html` 的 7 大項內容（隱私權條款、個人資料蒐集處理利用、資料保護、外部連結、與第三人共用、Cookie、修正）
  - 英文內容：將中文內容翻譯成英文（使用 LLM 翻譯後人工 review）
  - 版面：沿用既有 policy 的乾淨風格：720px max-width、白卡、淺灰背景；但要整合我們的 Header/Footer + design tokens（自動 dark mode）
  - 頁面頂部加 `Last updated: 2026-04-19`（從 env 或 build-time 注入）
  - Contact email 連結到 `mailto:tigerduckapp@gmail.com`

  **Must NOT do**:
  - 不創造新法律文字（沿用既有）
  - 不漏掉任何一項既有條款

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `[]`

  **Parallelization**: YES (Wave 3) | **Blocks**: T18, T21 | **Blocked By**: T1, T3, T8

  **References**:
  - 既有 privacy-policy HTML：`https://raw.githubusercontent.com/tigerduck-app/website/main/privacy-policy/index.html`（已於規劃階段下載原文）

  **Acceptance Criteria**:
  - [ ] `/privacy-policy` + `/en/privacy-policy` 皆可訪問
  - [ ] 中文版完整包含 7 大項原文（grep 驗證）
  - [ ] 英文版有對應翻譯

  **QA Scenarios**:
  ```
  Scenario: 中文 policy 有 7 項大標題
    Tool: Playwright
    Steps:
      1. Navigate `/privacy-policy`
      2. `const h2Count = await page.locator('h2').count()`
      3. 斷言 h2Count >= 7
    Expected Result: 至少 7 個 h2
    Evidence: .sisyphus/evidence/task-16-zh-h2-count.txt

  Scenario: 英文版存在並可讀
    Tool: Playwright
    Steps:
      1. Navigate `/en/privacy-policy`
      2. 斷言 `h1` 含 "Privacy" 字樣
      3. 斷言 lang attribute 為 "en"
    Expected Result: 英文版獨立運作
    Evidence: .sisyphus/evidence/task-16-en.png

  Scenario: Contact email 正確
    Tool: Playwright
    Steps:
      1. Navigate `/privacy-policy`
      2. `const href = await page.locator('a[href^="mailto"]').getAttribute('href')`
      3. 斷言 `href === "mailto:tigerduckapp@gmail.com"`
    Expected Result: email 連結正確
    Evidence: .sisyphus/evidence/task-16-email.txt
  ```

  **Commit**: YES

- [x] 17. **Delete-account pages（zh + en）**

  **What to do**:
  - 建立 `web/app/[locale]/delete-account/page.tsx`
  - 中文內容沿用 `https://github.com/tigerduck-app/website/blob/main/delete-account/index.html`（「我們使用 NTUST SSO，沒有帳號管理權，請洽學校」）
  - 英文內容翻譯對應
  - 版面同 privacy-policy
  - **重要**：此頁是我們 NTUST 免責聲明的強化點 — 文字必須明確「本應用程式與臺灣科技大學沒有任何關聯」，這與首頁 footer 一致

  **Must NOT do**:
  - 不提供假的「刪除帳號表單」（我們真的沒有帳號管理權）
  - 不與首頁 footer 免責聲明產生文字衝突

  **Recommended Agent Profile**: `quick` | Skills: `[]`

  **Parallelization**: YES (Wave 3) | **Blocks**: T18, T21 | **Blocked By**: T1, T3, T8

  **References**:
  - 既有 delete-account HTML：`https://raw.githubusercontent.com/tigerduck-app/website/main/delete-account/index.html`

  **Acceptance Criteria**:
  - [ ] `/delete-account` 與 `/en/delete-account` 皆可訪問
  - [ ] 雙語版皆含「與臺灣科技大學沒有任何關聯 / not affiliated with NTUST」字樣

  **QA Scenarios**:
  ```
  Scenario: 免責聲明字樣齊全
    Tool: Bash (curl + grep)
    Steps:
      1. `curl -s http://localhost:3000/delete-account | grep -F "沒有任何關聯"` → should match
      2. `curl -s http://localhost:3000/en/delete-account | grep -iF "not affiliated"` → should match
    Expected Result: 兩條 grep 都 match
    Evidence: .sisyphus/evidence/task-17-disclaimers.txt

  Scenario: 雙語頁面都可訪問
    Tool: Bash (curl)
    Steps:
      1. `curl -sI http://localhost:3000/delete-account | head -1` → `HTTP/1.1 200`
      2. `curl -sI http://localhost:3000/en/delete-account | head -1` → `HTTP/1.1 200`
    Expected Result: 兩頁都 200
    Evidence: .sisyphus/evidence/task-17-http.txt
  ```

  **Commit**: YES

- [x] 18. **SEO：OG tags + sitemap + robots + hreflang**

  **What to do**:
  - 在 `web/app/[locale]/layout.tsx` 使用 Next.js Metadata API：
    - `metadata.title` = "TigerDuck — 臺科大校園助手"（zh）/ "TigerDuck — NTUST Campus Helper"（en）
    - `metadata.description` = 從 messages 讀
    - `metadata.openGraph.images` = `/og-image.png`（請使用者提供或暫用 placeholder）
    - `metadata.twitter.card = "summary_large_image"`
    - `metadata.alternates.languages` = `{ "zh-TW": "https://tigerduck.app", "en": "https://tigerduck.app/en" }` → 自動產生 hreflang
  - 建立 `web/app/sitemap.ts`（Next.js 原生支援）→ 列出所有 pages × 2 languages
  - 建立 `web/app/robots.ts` → allow all except `/api/`（若有）
  - 建立 `web/public/og-image.png.placeholder`（使用者會補 1200×630 圖）
  - 在 `web/app/layout.tsx` 嵌入 Cloudflare Web Analytics script：`<script defer src="https://static.cloudflareinsights.com/beacon.min.js" data-cf-beacon='{"token": "{{CF_ANALYTICS_TOKEN}}"}'></script>`（使用 env `NEXT_PUBLIC_CF_ANALYTICS_TOKEN`）

  **Must NOT do**:
  - 不引入 GA4 或 Google Tag Manager
  - 不讓 sitemap 包含 query string 或重複 URL

  **Recommended Agent Profile**: `quick` | Skills: `[seo]`

  **Parallelization**: YES (Wave 3) | **Blocks**: T21 | **Blocked By**: T15, T16, T17

  **References**:
  - Next.js Metadata API: `https://nextjs.org/docs/app/api-reference/functions/generate-metadata`
  - hreflang guide: `https://developers.google.com/search/docs/specialty/international/localized-versions`

  **Acceptance Criteria**:
  - [ ] `curl /sitemap.xml` 回 valid XML 含所有 6 URL
  - [ ] `curl /robots.txt` 回合法 robots.txt
  - [ ] 首頁 HTML 含 `<link rel="alternate" hreflang="zh-TW">` 與 `hreflang="en"`
  - [ ] OG `<meta property="og:title">` 存在

  **QA Scenarios**:
  ```
  Scenario: Sitemap 有效 + 含所有頁面
    Tool: Bash
    Steps:
      1. `curl -s http://localhost:3000/sitemap.xml | xmllint --noout -` → 0
      2. URL 數 >= 6（`/`, `/en`, `/privacy-policy`, `/en/privacy-policy`, `/delete-account`, `/en/delete-account`）
    Expected Result: 有效 XML + 6 URL
    Evidence: .sisyphus/evidence/task-18-sitemap.xml

  Scenario: hreflang 雙向
    Tool: Bash
    Steps:
      1. `curl -s http://localhost:3000/ | grep -c 'hreflang='` → >= 2
    Expected Result: 至少 zh-TW + en alternate
    Evidence: .sisyphus/evidence/task-18-hreflang.txt

  Scenario: OG image placeholder 可訪問
    Tool: Bash
    Steps:
      1. `curl -sI http://localhost:3000/og-image.png.placeholder | head -1`
    Expected Result: 不拋 500（可能 404，但不 crash）
    Evidence: .sisyphus/evidence/task-18-og.txt
  ```

  **Commit**: YES

- [x] 19. **Console ASCII art 彩蛋**

  **What to do**:
  - 建立 `web/components/EasterEgg.tsx`（client component，在 root layout 引用）
  - 使用 `useEffect` 在 mount 時 `console.log` 一個 ASCII art（老虎 + 鴨子 + OAO 表情 + 專案 URL + 招募訊息）
  - 使用 `console.log('%c...', 'font-size: 20px; color: #F05138; font-weight: bold;')` 做 styled console 訊息
  - **Bonus**：加 Konami code 偵測（`↑↑↓↓←→←→BA`），觸發時 briefly 在螢幕 overlay 顯示 3D 鴨子 easter image（或簡單的 console.log 訊息）

  **Must NOT do**:
  - 不在 production logic console.log（僅此處有意為之）
  - 不用 ASCII art 包含 NTUST logo

  **Recommended Agent Profile**: `quick` | Skills: `[]`

  **Parallelization**: YES (Wave 3) | **Blocks**: T21 | **Blocked By**: T1

  **Acceptance Criteria**:
  - [ ] 開啟首頁後 `console.log` 訊息出現（非錯誤）
  - [ ] Konami code 可觸發

  **QA Scenarios**:
  ```
  Scenario: 彩蛋訊息出現在 console
    Tool: Playwright
    Steps:
      1. Capture browser console via `page.on('console', ...)`
      2. Navigate `/`
      3. 斷言 至少一條 console message 含 "TigerDuck" 或 emoji
    Expected Result: 彩蛋訊息已打印
    Evidence: .sisyphus/evidence/task-19-console.txt

  Scenario: Konami code 觸發
    Tool: Playwright
    Steps:
      1. Navigate
      2. 按下 `ArrowUp ArrowUp ArrowDown ArrowDown ArrowLeft ArrowRight ArrowLeft ArrowRight B A`
      3. 斷言 DOM 出現 `[data-testid="konami-reveal"]` 或 console 打印特殊訊息
    Expected Result: konami 生效
    Evidence: .sisyphus/evidence/task-19-konami.txt
  ```

  **Commit**: YES

- [x] 20. **/web/README.md 開發 + 部署指南**

  **What to do**:
  - 建立 `web/README.md` 包含：
    - 專案簡介（連結到主 repo）
    - 本地開發：`npm install`, `npm run dev`
    - Wrangler 預覽：`npm run preview`
    - 部署：`npm run deploy`（含說明：需先 `wrangler login` + 綁定 `tigerduck.app` route）
    - Environment variables（`NEXT_PUBLIC_CF_ANALYTICS_TOKEN`）
    - 目錄結構說明
    - 常見問題（3D 沒顯示？→ check WebGL；dark mode 閃屏？→ theme inline script）
    - 貢獻指南（同根 `CONTRIBUTORS.md`）

  **Must NOT do**:
  - 不在 README 放任何 secrets
  - 不把 wrangler login 流程寫死

  **Recommended Agent Profile**: `writing` | Skills: `[]`

  **Parallelization**: YES (Wave 3) | **Blocks**: F1 | **Blocked By**: T1, T7

  **Acceptance Criteria**:
  - [ ] `web/README.md` 存在
  - [ ] 含本地開發、部署、env vars、目錄結構、FAQ 五個 section

  **QA Scenarios**:
  ```
  Scenario: README 完整性
    Tool: Bash (grep)
    Steps:
      1. `for keyword in "npm run dev" "wrangler" "NEXT_PUBLIC_CF_ANALYTICS_TOKEN" "## "; do grep -q "$keyword" web/README.md || echo "MISSING: $keyword"; done`
    Expected Result: 無 MISSING 訊息
    Evidence: .sisyphus/evidence/task-20-readme.txt

  Scenario: README 無 secrets
    Tool: Bash
    Steps:
      1. `grep -E "(AKIA|sk_live|ghp_|[A-Za-z0-9]{40,})" web/README.md && echo FAIL || echo OK`
    Expected Result: OK
    Evidence: .sisyphus/evidence/task-20-secrets-scan.txt
  ```

  **Commit**: YES

- [x] 21. **Playwright E2E smoke tests（5 scenarios）**

  **What to do**:
  - `cd web && npm init playwright@latest -- --quiet`（選 TypeScript、安裝 Chromium）
  - 建立 `web/e2e/` 目錄，加入 5 個 test file：
    1. `smoke-home.spec.ts`：首頁載入、8 個 section id 皆存在、3D canvas 或 fallback 出現
    2. `smoke-lang.spec.ts`：切換 zh ↔ en，URL 正確、scroll 位置保留
    3. `smoke-theme.spec.ts`：dark mode toggle 三態輪替 + 持久化
    4. `smoke-ctas.spec.ts`：iOS CTA → TestFlight URL、Android CTA → Discord URL
    5. `smoke-policy.spec.ts`：/privacy-policy + /delete-account 雙語 4 頁 HTTP 200 + 必要文字存在
  - 建立 `web/playwright.config.ts`：
    - `testDir: './e2e'`
    - `use: { baseURL: 'http://localhost:3000' }`
    - `webServer: { command: 'npm run dev', port: 3000, reuseExistingServer: true }`
    - `retries: 1, workers: 4`
  - 在 `package.json` 加 `"test:e2e": "playwright test"`

  **Must NOT do**:
  - 不對第三方 URL（TestFlight、Discord）做 full navigation（只檢查 href 值）
  - 不在測試中使用 `waitForTimeout`（改用 `waitForSelector` / `toHaveText`）

  **Recommended Agent Profile**: `unspecified-high` | Skills: `[e2e-testing]`

  **Parallelization**: NO (Wave 4 - after 3) | **Blocks**: F1-F4 | **Blocked By**: T7, T15, T16, T17, T18, T19

  **Acceptance Criteria**:
  - [ ] 5 個 spec file 存在
  - [ ] `npx playwright test` 5/5 pass
  - [ ] Test 執行時間 < 60 秒

  **QA Scenarios**:
  ```
  Scenario: 所有 E2E 測試通過
    Tool: Bash
    Preconditions: T1-T20 完成
    Steps:
      1. `cd web && npx playwright test --reporter=list 2>&1 | tee /tmp/pw.log`
      2. 斷言輸出含 "5 passed"（或對應數字）
    Expected Result: 全綠
    Evidence: .sisyphus/evidence/task-21-playwright.log

  Scenario: 測試含 retry 機制
    Tool: Bash (grep)
    Steps:
      1. `grep "retries:" web/playwright.config.ts`
    Expected Result: 有 retries 配置
    Evidence: .sisyphus/evidence/task-21-retries.txt
  ```

  **Commit**: YES

- [x] 22. **Lighthouse + a11y + bundle budget check**

  **What to do**:
  - 建立 `web/scripts/check-budgets.sh`：
    - 跑 `npx opennextjs-cloudflare build`
    - 讀 `.open-next/server-functions/default/handler.mjs.map` 或 Next.js build output
    - 斷言：First Load JS ≤ 180kb gzipped（不含 3D chunk）、3D chunk ≤ 300kb
  - 建立 `web/scripts/lighthouse-check.sh`：
    - `npm run dev &`（或 Wrangler preview）
    - `npx lighthouse http://localhost:3000/ --only-categories=performance,accessibility,seo --output=json --output-path=/tmp/lh.json --chrome-flags="--headless"`
    - 解析 JSON 斷言：Performance ≥ 85、A11y ≥ 95、SEO = 100
  - 建立 `web/scripts/axe-check.ts`：用 `@axe-core/playwright` 掃首頁 + policy 頁，斷言 zero serious/critical violations
  - `package.json` 新增 scripts：`"budgets": "bash scripts/check-budgets.sh"`, `"lighthouse": "bash scripts/lighthouse-check.sh"`, `"a11y": "npx tsx scripts/axe-check.ts"`

  **Must NOT do**:
  - 不把 Lighthouse 門檻設太高而 block 開發（Perf 85 是合理值，非 95）
  - 不跑 deep audit 阻塞（只跑 categories 限定）

  **Recommended Agent Profile**: `unspecified-high` | Skills: `[]`

  **Parallelization**: YES (Wave 4) | **Blocks**: F1-F4 | **Blocked By**: T21

  **Acceptance Criteria**:
  - [ ] `npm run budgets` pass
  - [ ] `npm run lighthouse` Perf ≥ 85, A11y ≥ 95, SEO = 100
  - [ ] `npm run a11y` zero serious/critical axe violations

  **QA Scenarios**:
  ```
  Scenario: Lighthouse 達標
    Tool: Bash
    Preconditions: T1-T21 完成
    Steps:
      1. `cd web && npm run lighthouse`
      2. `jq '.categories.performance.score' /tmp/lh.json` >= 0.85
      3. `jq '.categories.accessibility.score' /tmp/lh.json` >= 0.95
      4. `jq '.categories.seo.score' /tmp/lh.json` == 1.0
    Expected Result: 三指標達標
    Evidence: .sisyphus/evidence/task-22-lighthouse.json

  Scenario: Bundle budget
    Tool: Bash
    Steps:
      1. `cd web && npm run budgets 2>&1 | tee /tmp/budget.log`
    Expected Result: exit 0，log 顯示 First Load JS < 180kb
    Evidence: .sisyphus/evidence/task-22-budget.log

  Scenario: 零嚴重 a11y 違規
    Tool: Bash
    Steps:
      1. `cd web && npm run a11y 2>&1 | tee /tmp/axe.log`
      2. grep -q "0 violations" 或 exit 0
    Expected Result: 無 serious/critical 違規
    Evidence: .sisyphus/evidence/task-22-axe.log
  ```

  **Commit**: YES

---

## Final Verification Wave

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user; wait for explicit "okay" before completing.

- [x] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists (read file, curl endpoint, run command). For each "Must NOT Have": search `/web` for forbidden patterns — reject with file:line if found. Specifically grep for `@cloudflare/next-on-pages`, `from 'pages/'`, `hotlink github-user-attachments in JSX src=`, `NTUST` used as logo/brand token, `Lorem ipsum`, `output: 'export'`, `styled-components`, `emotion`. Check evidence files exist in `.sisyphus/evidence/`. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [x] F2. **Code Quality Review** — `unspecified-high`
  Run `cd web && npm run build`, `npm run lint`, `npm run typecheck`, `npx playwright test`. Review all `/web/**/*.{ts,tsx}` for: `any`/`@ts-ignore`, empty catches, `console.log` in prod code (excluding intentional console art easter egg), commented-out code, unused imports, missing `"use client"` on client components, missing `export const runtime`. Check AI slop: excessive JSDoc, over-abstraction, generic names (data/result/item/temp), Lorem ipsum remnants. Verify Tailwind v4 consistency (no raw CSS outside `globals.css`).
  Output: `Build [PASS/FAIL] | Lint [PASS/FAIL] | Types [PASS/FAIL] | Tests [N/N] | Files [N clean/N issues] | VERDICT`

- [x] F3. **Real Manual QA** — `unspecified-high` + `playwright` skill
  Start from clean state (`cd web && rm -rf .next .open-next node_modules && npm install && npm run dev`). Execute EVERY QA scenario from EVERY task — follow exact steps, capture Playwright screenshots. Test: language switching (zh↔en preserves scroll position), dark mode toggle (persists across refresh), 3D hero loads + fallback when WebGL disabled, TestFlight CTA opens correct URL, Discord CTA redirects correctly, APK link lands on GitHub Releases v1.1.5, all 6 feature sections visible, glassmorphism section on mobile Safari looks correct, Material 3 section renders. Test edge cases: slow network (throttle 3G), rapid language switch, prefers-reduced-motion. Save evidence to `.sisyphus/evidence/final-qa/`.
  Output: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [x] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff (`git log /web --oneline`, `git diff main..HEAD -- /web`). Verify 1:1 — everything in spec was built (no missing), nothing beyond spec (no creep). Specifically check: `/swift`, `/backend`, existing `tigerduck-app/website` repo were NOT modified. Check "Must NOT do" compliance. Detect cross-task contamination: e.g., T9 (3D) touching T16 (policy) files. Flag unaccounted changes. Verify hidden production CTAs use `{/* */}` comments (not `display:none` or `if(false)`).
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

每個任務結束後 commit，分組策略如下：

- **T1**: `feat(web): scaffold Next.js 15 App Router project with OpenNext Cloudflare adapter`
- **T2**: `feat(web): add Tailwind v4 config and design tokens for dark mode`
- **T3**: `feat(web): set up next-intl i18n with zh-TW and en messages`
- **T4**: `feat(web): define domain types and data schemas`
- **T5**: `chore(web): download product screenshots and set up asset pipeline`
- **T6**: `feat(web): configure next/font with Noto Sans TC`
- **T7**: `feat(web): add wrangler.jsonc and OpenNext build config`
- **T8**: `feat(web): build shared header/footer with i18n and theme toggles`
- **T9**: `feat(web): add 3D hero canvas with React Three Fiber`
- **T10**: `feat(web): implement glassmorphism component library for iOS section`
- **T11**: `feat(web): implement Material 3 component library for Android section`
- **T12**: `feat(web): add GitHub API data source for contributors and stars`
- **T13**: `feat(web): build feature showcase components for core 6 features`
- **T14**: `feat(web): build FAQ, roadmap, and team components`
- **T15**: `feat(web): compose home page with long-scroll layout (zh + en)`
- **T16**: `feat(web): add privacy policy pages (zh + en)`
- **T17**: `feat(web): add delete-account pages (zh + en)`
- **T18**: `feat(web): add SEO metadata, sitemap, robots, hreflang`
- **T19**: `feat(web): add console ASCII art easter egg`
- **T20**: `docs(web): add README with local dev and deployment guide`
- **T21**: `test(web): add Playwright E2E smoke tests`
- **T22**: `test(web): add Lighthouse and bundle-size budget CI check`

Pre-commit hook for每個 commit：`cd web && npm run lint && npm run typecheck`

---

## Success Criteria

### Verification Commands
```bash
# 1. Build passes
cd web && npm install && npm run build
# Expected: Next.js build completes, no TS errors, no ESLint errors

# 2. OpenNext build passes
cd web && npx opennextjs-cloudflare build
# Expected: .open-next/worker.js produced

# 3. Playwright smoke test
cd web && npx playwright test
# Expected: 5/5 pass

# 4. Local Worker preview
cd web && npx opennextjs-cloudflare preview &
curl -s http://localhost:8787/ | grep -q "TigerDuck"
# Expected: HTTP 200, HTML contains "TigerDuck"

# 5. Policy pages reachable
curl -s http://localhost:8787/privacy-policy | grep -q "隱私權"
curl -s http://localhost:8787/en/privacy-policy | grep -q "Privacy"
# Expected: both return relevant content

# 6. Sitemap exists
curl -s http://localhost:8787/sitemap.xml | grep -q "<urlset"
# Expected: valid sitemap XML
```

### Final Checklist
- [ ] All 6 "Must Have" verified
- [ ] All 12 "Must NOT Have" absent (F1 grep pass)
- [ ] All 22 task QA scenarios pass
- [ ] Lighthouse mobile Performance ≥ 85, A11y ≥ 95, SEO = 100
- [ ] F1-F4 review wave all APPROVE
- [ ] User explicit okay received
