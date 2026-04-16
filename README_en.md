<div align="center">
<img width="2000" src="https://github.com/user-attachments/assets/cf6a1d18-a348-4b83-adfd-81c6dc82855f" />
<!-- ![TigerDuck Banner](.github/assets/banner.png) -->
<br>

[![License](https://img.shields.io/github/license/tigerduck-app/tigerduck-app?style=for-the-badge)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![iOS](https://img.shields.io/badge/iOS-18%2B-black?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/ios)

[![TestFlight](https://img.shields.io/badge/TestFlight-Join-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/eVt9Gjkw)

[繁體中文](README.md) | **English**
</div>

## Overview

<img align="right" width="330" alt="IMG_9202-portrait" src="https://github.com/user-attachments/assets/cf13806f-3419-4b50-8b9f-13fd77f979ef" />

TigerDuck is a campus companion app built by a group of students at **National Taiwan University of Science and Technology (NTUST)**.
It was created to solve common pain points: scattered resources, delayed notifications, and unintuitive interfaces.
Ever used [TAT](https://github.com/morris13579/tat_ntust)? We're working hard to take things even further with TigerDuck!

### 📚 **Assignments**
- See how many **assignments are still due** at a glance
- **Fully automatic** sync of assignments and deadlines from Moodle — no more surprise due dates!
- **Dynamic Island** and push notifications — don't wait until the last hour for Moodle alerts

### 📋 **Class Table**
- Synced directly from the course enrollment system — no more **Moodle delay**
- Dynamic Island and Live Activity show you where your next class is!

### 🏛️ **Library** (Experimental)
- Instant library entry QR code with zero delay

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

## Roadmap
> The features below are planned items. Development order and scope may change based on demand.

### 🎓 Academics & Learning
- [x] **Assignments** — Fully automatic Moodle assignment sync
- [x] **Assignments+** — Notifications and Dynamic Island
- [ ] **Assignments++** — Change app icon based on remaining time, tribute to Duolingo
- [x] **Class Table** — Fetched from the course enrollment system
- [x] **Class Table+** — Editable course names, deletable courses
- [x] **Class Table++** — Dynamic Island course status
- [x] **Calendar** — Aggregated events from school announcements, Moodle, etc.
- [ ] **Calendar+** — Track study room bookings, lectures, and club events
- [ ] **Historical GPA & Rankings** — Quick lookup of past academic performance and rankings
- [ ] **Graduation Credit Calculator** — Check completion status for general education categories, college credits, department credits, PE, Chinese, English, and other requirements

### 📝 Course Enrollment
- [ ] **Course Search** — Display GPA alongside results for better enrollment decisions
- [ ] **Lottery Probability & Preference Suggestions** — Estimate admission odds based on capacity and current enrollment; auto-reorder preferences

### 📚 Library Services
- [x] **Library Entry QR Code** — Quick access to the library entry QR code
- [ ] **Study Room Booking** — Reserve and check availability of library study rooms
- [ ] **NTUST Library Events** — Event registration and lookup (campus network required)

### 📣 Campus Information
- [ ] **Department & Office Announcements** — Aggregated announcements with filter support
- [ ] **Scholarships** — Filterable by eligibility (low-income, indigenous, etc.)
- [ ] **Daily Club Activities** — Curated daily club event listings
- [ ] **Empty Classroom Finder** — Quickly find currently available classrooms

### 🍱 Campus Life
- [ ] **Free Lunch Notifications** — Anyone can register (real-name); aggregates info from NTUST and NTU with push notifications

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

### Prerequisites
- **macOS**
- Xcode 26+
- Swift 5
- [uv](https://github.com/astral-sh/uv) package manager (for network request verification)

### iOS App
```bash
# Clone the repository
git clone https://github.com/tigerduck-app/tigerduck-app.git
cd tigerduck-app

# Open in Xcode
open swift/TigerDuck.xcodeproj

# Select a simulator or device from the top center, then press ⌘R to run
```


### Network Request Verification (Python)

Data fetching and scraping for NTUST courses, Moodle assignments, and the academic calendar.

```bash
cd backend

# Install uv
brew install uv

# Install dependencies
uv sync

# Copy the environment variable template
cp .env.example .env

# Fill in your NTUST student ID and password in .env
```

## Project Structure

```
tigerduck-app/
├── swift/
│   └── TigerDuck/
│       ├── Features/           # Screen-level feature modules
│       │   ├── Home/           # Home (Time Slider, assignments, widgets)
│       │   ├── ClassTable/     # Class table
│       │   ├── Calendar/       # Academic calendar
│       │   ├── Library/        # Library
│       │   ├── Announcements/  # Announcements
│       │   ├── Settings/       # Settings
│       │   └── Onboarding/     # First-run onboarding flow
│       ├── LiveActivity/       # Live Activity / Dynamic Island
│       │   ├── Models/         # Feature models
│       │   ├── Preferences/    # User preferences
│       │   ├── Providers/      # Data providers
│       │   ├── Resolvers/      # Resolvers
│       │   ├── Runtime/        # Core runtime
│       │   └── Scheduling/     # Schedulers
│       ├── Models/
│       │   ├── Domain/         # Business logic models
│       │   └── SwiftData/      # Local persistence models
│       ├── Services/
│       │   ├── Auth/           # NTUST SSO authentication
│       │   └── Network/        # Networking layer
│       ├── SharedUI/           # Reusable UI components
│       └── Theme/              # Global theme definitions
└── backend/
    └── api/                    # Python data-fetching scripts
        ├── ntust_sso.py        # NTUST SSO login
        ├── course_lookup.py    # Course lookup
        ├── get_moodle_homework.py  # Moodle assignments
        └── get_calender.py     # Academic calendar
```

## Contributing
Pull requests and issues are welcome!

Before submitting, please make sure to:
1. Follow the existing SwiftUI code style and architectural conventions
2. Verify the build runs correctly on an iOS 18 & iOS 26 simulator or device
3. Name your branch using `feature/your-feature` or `fix/your-fix`
4. Target the `dev` branch when opening a PR, and enable Copilot review

## License
This project is licensed under the [GNU Affero General Public License v3.0](LICENSE).
