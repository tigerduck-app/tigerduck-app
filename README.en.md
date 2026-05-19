<div align="center">
<a href="https://tigerduck.app/">
  <img width="2000" src="https://github.com/user-attachments/assets/cf6a1d18-a348-4b83-adfd-81c6dc82855f" alt="TigerDuck Banner"/>
</a>
<!-- ![TigerDuck Banner](.github/assets/banner.png) -->
<br>

[![License](https://img.shields.io/github/license/tigerduck-app/tigerduck-app?style=for-the-badge)](LICENSE)
[![Version](https://img.shields.io/badge/Version-v1.7.0-00BB00?style=for-the-badge)](https://github.com/tigerduck-app/tigerduck-app/releases/tag/v1.7.0)
[![iOS](https://img.shields.io/badge/iOS-18%2B-black?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/ios)

[![TestFlight](https://img.shields.io/badge/TestFlight-Join-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/eVt9Gjkw)

[繁體中文](README.md) | **English**
</div>

## Overview

<img align="right" width="330" alt="IMG_9202-portrait" src="https://github.com/user-attachments/assets/cf13806f-3419-4b50-8b9f-13fd77f979ef" />

TigerDuck is a campus companion app built by a group of students at **NTUST**.  
It was created to solve common pain points: scattered resources, delayed notifications, and unintuitive interfaces.  
Ever used [TAT](https://github.com/morris13579/tat_ntust)? We're working hard make you OAO!  

### 📚 **Assignments**
- See how many **assignments are still due** at a glance
- **Fully automatic** sync of assignments and deadlines from Moodle — no more surprise due dates!
- **Dynamic Island** and push notifications — don't wait until the last hour for Moodle alerts

### 📋 **Class Table**
- Synced directly from the course enrollment system — no more **Moodle delay**
- Dynamic Island and Live Activity show you where your next class is!

### 📣 **Bulletins**
- Server-side **LLM classification and de-duplication** — no more spam from every department
- Subscribe to categories, filter unread, and receive **push notifications** for what matters

### 📊 **GPA & Rankings**
- Per-semester / cumulative GPA, rankings, and per-course grades in one place
- Interactive charts to track grade trends over time

### 🏛️ **Library** (Experimental)
- Instant library entry QR code with zero delay

### 🌏 **Multilingual**
- Built-in support for **67+ locales** — follows the system language or set per-app
- Course / classroom names are **automatically abbreviated**

### 🎨 **Customization**
- Add what you want, remove what you don't
- Drag-and-drop section ordering, editable tabs, and accent color theming

<br clear="right"/>

## Screenshots

<details>
<summary><strong>Expand to view app screenshots</strong></summary>

<br>

<div align="center">

| Assignments | Class Table | Library |
|:---:|:---:|:---:|
| <img width="300" src="https://github.com/user-attachments/assets/2c7e2e82-a1cf-4db7-9c51-08e2636d02e2" /> | <img width="300" src="https://github.com/user-attachments/assets/7f30603f-e0b7-4cdf-94c6-5d72c05efb3c" /> | <img width="300" src="https://github.com/user-attachments/assets/f9fb2b1a-3532-4037-ab04-566f015ef3bc" /> |

| Customization Settings | Custom Tabs | Custom Home |
|:---:|:---:|:---:|
| <img width="300" src="https://github.com/user-attachments/assets/9dfa88e2-b0ef-4f06-9349-da97537dc4bb" /> | <img width="300" src="https://github.com/user-attachments/assets/b95f48d9-a18b-4ccc-bb21-610258fe25d0" /> | <img width="300" src="https://github.com/user-attachments/assets/6832b886-3e52-4bde-8b7d-8089bf13d4c7" /> |

</div>

</details>

<br/>

## Get the App
[![TestFlight](https://img.shields.io/badge/TestFlight-Join-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/eVt9Gjkw)

<br/>

## Release History
> Full notes on [GitHub Releases](https://github.com/tigerduck-app/tigerduck-app/releases).

| Version | Date | Highlights |
|:---:|:---:|---|
| **`v1.7.0`** | 2026-05-18 | 🔔 **Apple Watch app launch** — Library QR as the leftmost tab, WatchConnectivity credential push, fullscreen QR + idle-fade page dots, localized QR-page strings; macOS dashboard and class-table unified through `CanonicalCourseProvider`, longer next-class time range; Home / class-table card rows lock to the tallest seen, conflicting (衝堂) classes laid out side-by-side at their own offsets; max screen brightness while Library QR is shown; onboarding keyboard anchoring + post-grant push enablement fixes; backend split into a dedicated `tigerduck-backend` repo; bumped to Xcode 26.4 with Swift 6 strict concurrency clean |
| **`v1.6.1`** | 2026-05-01 | 🤖 **Android FCM push delivery** (groundwork for the Android client; batched fan-out, bad-token classification), API base path bumped from `/v1` to `/v2` (`/v1` kept as deprecated alias), iOS device registration now reports `platform=apple` |
| **`v1.6.0`** | 2026-05-01 | 🌏 **i18n (67+ locales)**, in-app language switcher, RTL layout fixes, course/classroom **abbreviation** submodule, locale-scoped course cache |
| **`v1.5.2`** | 2026-04-24 | Live Activity push-token retry/cleanup, scheduler token pruning, mismatched-snapshot guard |
| **`v1.5.1`** | 2026-04-24 | Class-table "today's courses" pinning + assignment list cleanup fixes |
| **`v1.5.0`** | 2026-04-24 | 📣 **Bulletins overhaul** — server-driven, LLM-classified & de-duped, subscribable categories, NULL-safe pagination |
| **`v1.4.0`** | 2026-04-22 | 🚀 **Push backend launched** — FastAPI + APNs Push-to-Start, schedule sync, shared-secret auth |
| **`v1.3.6`** | 2026-04-22 | 📊 **GPA & Rankings** wired into the main tab + interactive charts |
| **`v1.3.3`** | 2026-04-21 | Assignment-status semantic color badges, submission timemodified plumbing |
| **`v1.3.2`** | 2026-04-21 | Moodle OIDC migration, `30ms` server probe replacing `1h` TTL, 24h course cache |
| **`v1.3.0`** | 2026-04-17 | Dynamic Island (Live Activity) redesign, Settings polish |

<br/>

## Roadmap

### 🎓 Academics & Learning
- [x] **Assignments** — Fully automatic Moodle assignment sync `v1.0`
- [x] **Assignments+** — Notifications and Dynamic Island `v1.3.0`
- [x] **Assignment status tracking** — submission / cutoff plumbing, semantic color badges `v1.3.3`
- [ ] **Assignments++** — Change app icon based on remaining time, tribute to Duolingo
- [x] **Class Table** — Fetched from the course enrollment system `v1.0`
- [x] **Class Table+** — Editable course names, deletable courses `v1.0`
- [x] **Class Table++** — Dynamic Island course status `v1.3.0`
- [x] **Calendar** — Aggregated events from school announcements, Moodle, etc. `v1.0`
- [ ] **Calendar+** — Track study room bookings, lectures, and club events
- [x] **Historical GPA & Rankings** — Per-semester / cumulative / per-course grades + interactive charts `v1.3.6`
- [ ] **Graduation Credit Calculator** — Check completion status for general education categories, college credits, department credits, PE, Chinese, English, and other requirements

### 📝 Course Enrollment
- [ ] **Course Search** — Display GPA alongside results for better enrollment decisions
- [ ] **Lottery Probability & Preference Suggestions** — Estimate admission odds based on capacity and current enrollment; auto-reorder preferences

### 📚 Library Services
- [x] **Library Entry QR Code** — Quick access to the library entry QR code `v1.0`
- [ ] **Study Room Booking** — Reserve and check availability of library study rooms
- [ ] **NTUST Library Events** — Event registration and lookup (campus network required)

### 📣 Campus Information
- [x] **Department & Office Announcements** — Aggregated announcements `v1.0`
- [x] **LLM-classified bulletins + subscriptions** — Server-side classification & de-duplication, subscribable categories, unread filter `v1.5.0`
- [ ] **Scholarships** — Filterable by eligibility (low-income, indigenous, etc.)
- [ ] **Daily Club Activities** — Curated daily club event listings
- [ ] **Empty Classroom Finder** — Quickly find currently available classrooms

### 🍱 Campus Life
- [ ] **Free Lunch Notifications** — Anyone can register (real-name); aggregates info from NTUST and NTU with push notifications

### 🌏 Localization & Accessibility
- [x] **Multilingual (67+ locales)** — Follows system language or per-app override `v1.6.0`
- [x] **Course / Classroom name abbreviations** — One-tap toggle, fully reversible `v1.6.0`
- [x] **RTL layout fixes** — Arabic / Hebrew and other right-to-left scripts `v1.6.0`

## System Requirements
| Item | Requirement |
|------|-------------|
| OS | iOS 18 or later |
| SSO Account | Student account (required for some features) |
| Library | Library account (required for some features) |


<br/><br/>

---

<br/><br/>

## Development Setup
[![Swift](https://img.shields.io/badge/Swift-5-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![Python](https://img.shields.io/badge/Python-3.13-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://python.org)

### Prerequisites
- **macOS**
- Xcode 26+
- Swift 5
- [uv](https://github.com/astral-sh/uv) package manager (backend / POC scripts)
- Docker Desktop (only required for the full push backend stack)

### iOS App
```bash
# Clone the repository (with submodules: localization, name-abbr)
git clone --recurse-submodules https://github.com/tigerduck-app/tigerduck-app.git
cd tigerduck-app

# Already cloned without --recurse-submodules? Pull them in:
git submodule update --init --recursive

# Open in Xcode
open swift/TigerDuck.xcodeproj

# Select a simulator or device from the top center, then press ⌘R to run
```

> 💡 Name abbreviations (`name-abbr/`) and localization strings (`localization/generated/apple/`) are wired into the Xcode synchronized group via symlinks. **Always** initialize submodules before opening Xcode, otherwise the build will fail to locate resource files.

### Push Backend
The production FastAPI push service (APNs Push-to-Start, schedule sync, bulletin scraping, and LLM classification) lives in its own repository: [tigerduck-backend](https://github.com/tigerduck-app/tigerduck-backend). The iOS app talks to it over the `https://api.tigerduck.app/v2/*` HTTP contract, so you do **not** need to run it locally to develop the iOS client.

### Network Request Verification (`api-poc/`)

POC scripts that validate NTUST / Moodle / Calendar endpoints **before** the Swift client implements them. These are throwaway scripts, not a long-running service.

```bash
cd api-poc

# Install uv
brew install uv

# Install dependencies
uv sync

# Copy the environment variable template
cp api/.env.template api/.env

# Fill in your NTUST student ID and password in .env
```

## Project Structure

```
tigerduck-app/
├── swift/                              # iOS App (Xcode 26+ / iOS 18+)
│   └── TigerDuck/
│       ├── App/                        # Global state (AppState), language manager, push delegate
│       ├── Bridge/                     # Service orchestration (KMP / native fetch bridge)
│       ├── Features/                   # Screen-level feature modules
│       │   ├── Home/                   # Home (Time Slider, assignments, widgets)
│       │   ├── ClassTable/             # Class table
│       │   ├── Calendar/               # Academic calendar
│       │   ├── Bulletins/              # Server-driven, LLM-classified announcements
│       │   ├── Score/                  # Historical GPA & rankings
│       │   ├── Library/                # Library
│       │   ├── More/                   # "More" hub + feature pinning
│       │   ├── Settings/               # Settings (language, abbreviations, theme, source)
│       │   └── Onboarding/             # First-run onboarding flow
│       ├── LiveActivity/               # Live Activity / Dynamic Island
│       │   ├── Models/  Preferences/  Providers/
│       │   ├── Resolvers/  Runtime/  Scheduling/
│       ├── Models/
│       │   ├── Domain/                 # Business logic models
│       │   └── SwiftData/              # Local persistence models
│       ├── Services/
│       │   ├── Auth/                   # NTUST SSO authentication
│       │   ├── Network/                # Networking layer
│       │   ├── Push/                   # APNs / push registration
│       │   ├── Logging/                # Structured logging
│       │   └── Migrations/             # One-shot migrations
│       ├── SharedUI/                   # Reusable cross-feature views
│       └── Theme/                      # Tokens, palette, visual presets
├── api-poc/                            # Third-party API validation scripts (NTUST / Moodle / Calendar)
│   └── api/                            # ntust_sso / course_lookup / moodle / calendar
├── docs/                               # Planning docs, migration notes (iOS side)
├── localization/                       # ⤴ git submodule: 67+ locale translations
└── name-abbr/                          # ⤴ git submodule: course / classroom abbreviation dictionaries

> The push / bulletin backend (FastAPI + Postgres + APNs + LLM) has been split out into [tigerduck-backend](https://github.com/tigerduck-app/tigerduck-backend).
```

## Contributing
Pull requests and issues are welcome!

Before submitting, please make sure to:
1. Follow the existing SwiftUI code style and architectural conventions
2. Verify the build runs correctly on an iOS 18 & iOS 26 simulator or device
3. Name your branch using `feature/your-feature` or `fix/your-fix`
4. Target the `dev` branch when opening a PR, and enable Copilot review
5. For translation strings, open a separate PR against the `localization/` submodule — do **not** edit the symlinked `*.lproj` files inside `swift/`

## License
This project is licensed under the [GNU Affero General Public License v3.0](LICENSE).
