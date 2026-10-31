<div align="center">
<a href="https://tigerduck.app/">
  <img width="2000" src="https://github.com/user-attachments/assets/cf6a1d18-a348-4b83-adfd-81c6dc82855f" alt="TigerDuck Banner"/>
</a>
<!-- ![TigerDuck Banner](.github/assets/banner.png) -->
<br>

[![License](https://img.shields.io/github/license/tigerduck-app/tigerduck-app?style=for-the-badge)](LICENSE)
[![Version](https://img.shields.io/badge/Version-v2.9.1-00BB00?style=for-the-badge)](https://github.com/tigerduck-app/tigerduck-app/releases/tag/v2.9.1)
[![iOS](https://img.shields.io/badge/iOS-18%2B-black?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/ios)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/macos)
[![watchOS](https://img.shields.io/badge/watchOS-11%2B-black?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/watchos)

[![App Store](https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://apps.apple.com/app/id6761084888)
[![TestFlight](https://img.shields.io/badge/TestFlight-Join-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/eVt9Gjkw)

[繁體中文](README.md) | **English**
</div>

## Overview

<img align="right" width="330" alt="IMG_9202-portrait" src="https://github.com/user-attachments/assets/cf13806f-3419-4b50-8b9f-13fd77f979ef" />

TigerDuck is a campus companion app built by a group of students at **NTUST**.  
It was created to solve common pain points: scattered resources, delayed notifications, and unintuitive interfaces.

### 📚 **Assignments & Moodle**
- Assignments and deadlines sync from Moodle automatically, so you see what is still due at a glance, team submissions included
- Read an assignment's description, attachments, submission and feedback in the app, and a course's announcements, materials, forums, members and grades in one place
- Server-sent reminders and a Live Activity before the deadline, silenced once you submit, and whole courses you can ignore

### 📋 **Class Table**
- Synced from the course selection system for the latest term, with custom names, colors, hand-added courses and a TAT grid style
- Share, import and switch class tables by QR code, or export one as an image
- Class reminders, plus the Dynamic Island and Live Activities showing where your next class is

### 🗓️ **Calendar & Bulletins**
- School events, holidays and Moodle deadlines in one calendar, with no class reminders on holidays
- Bulletins classified, cleaned up and de-duplicated by an LLM on the server, with category subscriptions, an unread filter and push for what matters

### 📊 **GPA & Rankings**
- Semester and cumulative GPA, rankings, every course's grade and interactive trend charts, with an estimated GPA before rankings are out

### 🏛️ **Free Classrooms & Library**
- Free classrooms for the next two weeks, with a room to wait in between your classes
- The library entry QR code opens instantly at full brightness, or when you flip the phone face down

### 📬 **School Mail** (iOS)
- Read and send NTUST Mail2000 mail in the app, with search, reply, forward, attachments, move and delete, and new-mail notifications
- The phone talks to the school's mail server directly, never through TigerDuck's servers, and the password stays encrypted on this device

### ☁️ **TigerSync**
- Class tables, assignment marks, course colors and notification settings sync across your iPhone, Mac and other devices in real time, with conflict handling

### ⌚ **Apple Watch** · 🧩 **Widgets** · 💻 **macOS**
- Apple Watch shows Now & Next, today's classes and the library QR code, puts the next class on the watch face, and takes its sign-in from the iPhone
- Widgets for the next class, today's and this week's timetable, the Lock Screen and a library QR shortcut, shared by iOS and macOS
- A native Mac app (not Catalyst) with sidebar navigation and a Mac layout on every page

### 🎨 **Appearance & Accessibility**
- 67 built-in locales, with automatic course and classroom abbreviations
- Drag sections on Home, edit the tabs, and pick an accent color and interface style
- VoiceOver, Dynamic Type and Reduce Motion support, with passwords and QR codes hidden in screenshots and recordings

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
[![App Store](https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://apps.apple.com/app/id6761084888)

[![TestFlight](https://img.shields.io/badge/TestFlight-Join-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/eVt9Gjkw)

What changed in each version is on [Releases](https://github.com/tigerduck-app/tigerduck-app/releases), and what is planned is on [Milestones](https://github.com/tigerduck-app/tigerduck-app/milestones).

<br/>

## System Requirements
| Item | Requirement |
|------|-------------|
| OS | iOS 18 or later |
| macOS (optional) | macOS 14 or later (native Mac app, not Catalyst) |
| Apple Watch (optional) | watchOS 11+, paired iPhone required |
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
- [uv](https://github.com/astral-sh/uv) package manager (only for the `api-poc/` scripts)

### iOS App
```bash
# Clone the repository (with submodules: app-translation, name-abbr)
git clone --recurse-submodules https://github.com/tigerduck-app/tigerduck-app.git
cd tigerduck-app

# Already cloned without --recurse-submodules? Pull them in:
git submodule update --init --recursive

# Open in Xcode
open swift/TigerDuck.xcodeproj

# Select a simulator or device from the top center, then press ⌘R to run
```

> 💡 Name abbreviations (`name-abbr/`) and localization strings (`app-translation/generated/apple/`) are wired into the Xcode synchronized group via symlinks. **Always** initialize submodules before opening Xcode, otherwise the build will fail to locate resource files.

### Push Backend
The production FastAPI service (APNs Push-to-Start, schedule sync, bulletin scraping, LLM classification, and cloud sync) lives in its own repository: [tigerduck-backend](https://github.com/tigerduck-app/tigerduck-backend). The iOS app talks to it over the `https://api.tigerduck.app/v3/*` HTTP contract, so you do **not** need to run it locally to develop the iOS client.

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
├── swift/                              # iOS App + companion targets (Xcode 26+ / iOS 18+ / watchOS 11+)
│   ├── TigerDuck/                      # Main iOS app sources
│   │   ├── App/                        # Entry point, global state (AppState), language manager, push delegate
│   │   ├── Account/                    # NTUST sign-in coordination (AuthService)
│   │   ├── Bridge/                     # Fetch orchestration between services and SwiftData
│   │   ├── School/                     # NTUST, SSO, Moodle, library, calendar and bulletin clients
│   │   ├── Backend/                    # TigerDuck backend: tokens, cloud sync, push, course catalog
│   │   ├── Mail/                       # School Mail IMAP / SMTP
│   │   ├── Persistence/                # Caches, Keychain, SwiftData models
│   │   ├── Devices/                    # Widgets, Watch sync, Live Activity (in-app logic)
│   │   ├── Features/                   # Screen-level feature modules
│   │   │   ├── Home/                   # Home (Time Slider, assignments, widgets)
│   │   │   ├── ClassTable/             # Class table
│   │   │   ├── Calendar/               # Academic calendar
│   │   │   ├── Bulletins/              # Server-driven, LLM-classified announcements
│   │   │   ├── Score/                  # Historical GPA & rankings
│   │   │   ├── Library/                # Library
│   │   │   ├── SchoolMail/             # School Mail (iOS only)
│   │   │   ├── More/                   # "More" hub + feature pinning
│   │   │   ├── Settings/               # Settings (language, abbreviations, theme, source)
│   │   │   ├── Onboarding/             # First-run onboarding flow
│   │   │   └── Updates/                # Update prompt + What's New
│   │   ├── Models/Domain/              # Business logic models
│   │   ├── Platform/Mac/               # macOS-only surfaces (sidebar, Mac page layouts, push delegate)
│   │   ├── Migrations/                 # One-shot migrations
│   │   ├── Support/                    # Clock, concurrency, logging, TLS pin document, extensions
│   │   └── UI/                         # Shared views, theme, palette, view helpers
│   ├── TigerDuckLiveActivity/          # Live Activity / Dynamic Island widget extension
│   ├── TigerDuckWidgets/               # iOS / macOS Home, Lock Screen and accessory widgets
│   ├── TigerDuckWatch Watch App/       # Apple Watch app (Now & Next / Today / detail / Library QR)
│   ├── TigerDuckWatchWidget/           # Apple Watch complication
│   ├── TigerDuckTests/                 # Unit tests (Swift Testing + XCTest, incl. widget / watch logic)
│   ├── Packages/SwiftMail/             # Vendored IMAP / SMTP package used by School Mail
│   ├── ci_scripts/                     # Xcode Cloud post-clone hook (fetches submodules)
│   └── Shared/                         # Cross-target shared code (sensors, Watch comms, theme)
├── api-poc/                            # Third-party API validation scripts (NTUST / Moodle / Calendar)
│   └── api/                            # moodle/ · ntust/ · public/ (calendar, bulletin)
├── tools/                              # Localization, licence and macOS source checks
├── .github/workflows/                  # PR checks: unit tests, version bump, What's New, localization
├── docs/                               # Planning docs, migration notes (iOS side)
├── app-translation/                    # ⤴ git submodule: 67 locale translations
└── name-abbr/                          # ⤴ git submodule: course / classroom abbreviation dictionaries
```

> The push / bulletin backend (FastAPI + Postgres + APNs + LLM) has been split out into [tigerduck-backend](https://github.com/tigerduck-app/tigerduck-backend).

## Contributing
Pull requests and issues are welcome!

Before submitting, please make sure to:
1. Follow the existing SwiftUI code style and architectural conventions
2. Verify the build runs correctly on the following versions of simulator or device
- iOS 18 / 26 (/ 27 if possible)
- watchOS 11 / 26 (/ 27 if possible)
- macOS 15 / 26 (/ 27 if possible)
3. Name your branch using `feature/your-feature` or `fix/your-fix`
4. Target the `dev` branch when opening a PR, and keep fixing the code until Greptile's confidence score reaches 5/5; a review stuck at 3 or 4 for an unexpected reason is handled case by case
5. For translation strings, open a separate PR against the `app-translation/` submodule — do **not** edit the symlinked `*.lproj` files inside `swift/`
6. Write code comments in English and keep them short: say why, not what the code does or how it changed. The full rules are in the Comments section of [AGENTS.md](AGENTS.md); CI checks language, length and citations
7. Plan work that spans sessions, changes the architecture or needs both maintainers to agree as an [OpenSpec](https://github.com/Fission-AI/OpenSpec) change in `openspec/changes/`, committed with the work; see the Planning section of [AGENTS.md](AGENTS.md)

## License
This project is licensed under the [GNU Affero General Public License v3.0](LICENSE).
