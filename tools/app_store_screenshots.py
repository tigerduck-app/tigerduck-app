#!/usr/bin/env python3
"""Take the App Store screenshots: the demo account in simulators, dark, with a 9:41 status bar.

AppStoreScreenshotTests (swift/TigerDuckUITests/) signs in as the demo account of
swift/TigerDuck/Account/Demo/demo.json and captures each screen; WatchScreenshotTests
(swift/TigerDuckWatch Watch AppUITests/) captures the Watch app, which the paired iPhone 18 Pro
feeds. Each device gets a simulator named "Screenshots <device>", created the first time and
reused after, and both languages run on it in turn:

    python3 tools/app_store_screenshots.py
    python3 tools/app_store_screenshots.py --device iphone-18-pro --language en

The shots land in screenshots/<device>/<language>/<NN-name>.png. The app's clock stands at 09:41
on Tuesday of the current Taipei week, and the status bar at 09:41. Needs Xcode 27 (from
`xcode-select -p` or DEVELOPER_DIR) with the iOS and watchOS simulators. Exits nonzero when a test
fails or a PNG is not its device's portrait size in DEVICES; the tests that failed leave
<test>-failed.txt with the screen's accessibility tree beside the shots.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "swift" / "TigerDuck.xcodeproj"
OUTPUT = ROOT / "screenshots"
DERIVED_DATA = Path.home() / "Library/Developer/Xcode/DerivedData/TigerDuck-AppStoreScreenshots"
APP = "org.ntust.app.TigerDuck"
WATCH_APP = "org.ntust.app.TigerDuck.watchkitapp"
TAIPEI = timezone(timedelta(hours=8))
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


@dataclass(frozen=True)
class Device:
    slug: str
    name: str
    platform: str
    sizes: frozenset[tuple[int, int]]
    # AppStoreScreenshotTests' tests whose screens the device leaves out.
    skipped: tuple[str, ...] = ()
    shows_date_in_status_bar: bool = False


LIVE_ACTIVITY = ("test10LiveActivityLockScreen", "test11LiveActivityDynamicIsland")
# The portrait sizes each simulator gives, among those App Store Connect takes for its slot:
# https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications
DEVICES = (
    Device("iphone-18-pro", "iPhone 18 Pro", "iOS", frozenset({(1206, 2622)})),
    # The simulator shows only its cover screen, where the running Live Activity appears neither on
    # the Lock Screen nor beside the status bar. Xcode has no control that unfolds it, and with the
    # cover display powered off (`simctl io screenConfig`) SpringBoard crashes at every launch.
    Device("iphone-duo", "iPhone Duo", "iOS", frozenset({(1398, 2034), (2007, 2853)}), LIVE_ACTIVITY),
    Device("ipad-pro-13", "iPad Pro 13-inch (M5)", "iOS", frozenset({(2064, 2752)}), (
        "test08Calendar", "test09LibraryQR", *LIVE_ACTIVITY, "test12EmptyClassrooms", "test13Clubs",
    ), shows_date_in_status_bar=True),
    Device("watch-46mm", "Apple Watch Series 12 (46mm)", "watchOS", frozenset({(416, 496)})),
)
# The phone the Watch pairs with and takes its data from.
WATCH_PHONE = DEVICES[0]
LANGUAGES = {"zh-Hant": "zh_TW", "en": "en_US"}
STATUS_BAR = [
    "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
    "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100",
]


def pinned_clock(today: date) -> datetime:
    """09:41 on Tuesday of `today`'s week, the demo week's busiest day."""
    tuesday = today - timedelta(days=today.weekday()) + timedelta(days=1)
    return datetime.combine(tuesday, time(9, 41), TAIPEI)


def status_bar_time(device: Device, language: str, instant: datetime) -> str:
    """`simctl status_bar --time`: the pinned date and time, or the time alone where a date shows wrong.

    simctl takes an ISO date only with milliseconds. Given one, an iPad's status bar shows the date in
    English whatever the device's language, so an iPad in another language gets the time alone and
    shows the real date in its language. On the Lock Screen a date's year becomes 2000 ("Fri Nov 24"
    for Tuesday, 24 November 2026), and in zh-Hant any override shows Saturday, 1 January.
    """
    if device.shows_date_in_status_bar and language != "en":
        return f"{instant.hour}:{instant.minute:02d}"
    return instant.isoformat(timespec="milliseconds")


def clock_argument(instant: datetime) -> str:
    """The debug build's frozen clock: `ClockOverride` (swift/TigerDuck/Support/Clock/ClockOverride.swift)
    as JSON, in the old-style property list data form a launch argument takes."""
    seconds = (instant - APPLE_EPOCH).total_seconds()
    override = {"instant": seconds, "frozen": True, "savedAtReal": seconds}
    return "<" + json.dumps(override, separators=(",", ":")).encode().hex() + ">"


def png_size(path: Path) -> tuple[int, int] | None:
    with path.open("rb") as file:
        header = file.read(24)
    if len(header) < 24 or header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", header[16:24])


def size_problems(folder: Path, device: Device) -> list[str]:
    shots = sorted(folder.glob("*.png"))
    if not shots:
        return [f"{folder}: no screenshots"]
    problems = []
    for shot in shots:
        size = png_size(shot)
        if size not in device.sizes:
            taken = ", ".join(f"{w}x{h}" for w, h in sorted(device.sizes))
            shown = "not a PNG" if size is None else f"{size[0]}x{size[1]}"
            problems.append(f"{shot}: {shown}, not the {device.name}'s {taken}")
    return problems


def run(command: list[str], env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(command, env=env, check=check, text=True, capture_output=True)


def simctl(*args: str, check: bool = True) -> str:
    return run(["xcrun", "simctl", *args], check=check).stdout


def simctl_json(*args: str) -> dict:
    return json.loads(simctl("list", "-j", *args))


def simulator(device: Device) -> str:
    """The udid of the device's "Screenshots" simulator, created on the newest runtime that has it."""
    name = f"Screenshots {device.name}"
    for devices in simctl_json("devices", "available")["devices"].values():
        for found in devices:
            if found["name"] == name:
                return found["udid"]
    runtimes = [
        runtime for runtime in simctl_json("runtimes")["runtimes"]
        if runtime["isAvailable"] and runtime["platform"] == device.platform
        and any(kind["name"] == device.name for kind in runtime["supportedDeviceTypes"])
    ]
    if not runtimes:
        sys.exit(f"error: no {device.platform} simulator runtime has the {device.name}")
    runtime = max(runtimes, key=lambda r: [int(part) for part in r["version"].split(".")])
    kind = next(k for k in runtime["supportedDeviceTypes"] if k["name"] == device.name)
    print(f"creating {name} on {runtime['name']}")
    return simctl("create", name, kind["identifier"], runtime["identifier"]).strip()


def pair(watch: str, phone: str) -> None:
    for pair_id, found in simctl_json("pairs")["pairs"].items():
        if found["watch"]["udid"] == watch:
            if found["phone"]["udid"] == phone:
                if not found["state"].startswith("(active"):
                    simctl("pair_activate", pair_id)
                return
            simctl("unpair", pair_id)
    simctl("pair", watch, phone)


def boot(udid: str) -> None:
    simctl("bootstatus", udid, "-b")


def set_language(udid: str, language: str, locale: str) -> None:
    """Sets the device's language and region, restarting it when they change."""
    boot(udid)
    current = simctl("spawn", udid, "defaults", "read", "-g", "AppleLanguages", check=False)
    first = current.strip("()\n ").split(",")[0].strip().strip('"')
    if first == language:
        return
    simctl("spawn", udid, "defaults", "write", "-g", "AppleLanguages", "-array", language)
    simctl("spawn", udid, "defaults", "write", "-g", "AppleLocale", locale)
    simctl("shutdown", udid)
    boot(udid)


def prepare(udid: str, device: Device, language: str, instant: datetime) -> None:
    set_language(udid, language, LANGUAGES[language])
    if device.platform == "iOS":
        simctl("ui", udid, "appearance", "dark")
        simctl("status_bar", udid, "clear")
        simctl("status_bar", udid, "override", "--time", status_bar_time(device, language, instant), *STATUS_BAR)


def xcodebuild(arguments: list[str], log: Path, env: dict[str, str] | None = None) -> bool:
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as file:
        result = subprocess.run(["xcodebuild", *arguments], env=env, stdout=file, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        lines = log.read_text(errors="replace").splitlines()
        failures = [line for line in lines if " error: " in line or line.startswith("error:")]
        print("\n".join(failures[-20:] or lines[-30:]))
        print(f"xcodebuild failed; the log is {log}")
    return result.returncode == 0


def build(scheme: str, udid: str, derived_data: Path, logs: Path) -> Path:
    """Builds `scheme` for testing on `udid` and returns its .xctestrun."""
    arguments = [
        "build-for-testing", "-project", str(PROJECT), "-scheme", scheme, "-destination", f"id={udid}",
        "-derivedDataPath", str(derived_data), "COMPILER_INDEX_STORE_ENABLE=NO",
    ]
    print(f"building {scheme}")
    if not xcodebuild(arguments, logs / f"build-{scheme}.log"):
        sys.exit(1)
    runs = sorted((derived_data / "Build/Products").glob(f"{scheme}_*.xctestrun"), key=lambda p: p.stat().st_mtime)
    return runs[-1]


def run_tests(
    xctestrun: Path, udid: str, test: str, skipped: tuple[str, ...], folder: Path, clock: str, log: Path,
) -> bool:
    env = {**os.environ, "TEST_RUNNER_SCREENSHOTS_DIR": str(folder), "TEST_RUNNER_SCREENSHOTS_CLOCK": clock}
    arguments = [
        "test-without-building", "-xctestrun", str(xctestrun), "-destination", f"id={udid}",
        f"-only-testing:{test}", *(f"-skip-testing:{test}/{name}" for name in skipped),
        "-parallel-testing-enabled", "NO",
    ]
    return xcodebuild(arguments, log, env)


def launch_phone_app(udid: str, clock: str) -> None:
    """Opens the app on the Watch's phone, which then sends the Watch its classes and library card."""
    env = {**os.environ, "SIMCTL_CHILD_TZ": "Asia/Taipei"}
    run([
        "xcrun", "simctl", "launch", "--terminate-running-process", udid, APP,
        "-debug.clock.override", clock, "-debug.disableScreenCaptureProtection", "YES",
    ], env=env)


def main() -> int:
    # Each line as it comes, also when a CI log or a file takes the output.
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--device", action="append", choices=[d.slug for d in DEVICES], help="default: every device")
    parser.add_argument("--language", action="append", choices=list(LANGUAGES), help="default: both")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--derived-data", type=Path, default=DERIVED_DATA)
    args = parser.parse_args()

    slugs = set(args.device or [d.slug for d in DEVICES])
    if "watch-46mm" in slugs and WATCH_PHONE.slug not in slugs:
        print(f"the Watch takes its data from the {WATCH_PHONE.name}, so it runs too")
        slugs.add(WATCH_PHONE.slug)
    devices = [d for d in DEVICES if d.slug in slugs]
    languages = args.language or list(LANGUAGES)
    pinned = pinned_clock(datetime.now(TAIPEI).date())
    clock = clock_argument(pinned)
    logs = args.output / "logs"

    udids = {device.slug: simulator(device) for device in devices}
    watch = next((d for d in devices if d.platform == "watchOS"), None)
    if watch:
        pair(udids[watch.slug], udids[WATCH_PHONE.slug])
    phone_run = build("TigerDuck Screenshots", udids[devices[0].slug], args.derived_data, logs)
    watch_run = build("TigerDuckWatch Screenshots", udids[watch.slug], args.derived_data, logs) if watch else None

    problems: list[str] = []
    for language in languages:
        for device in devices:
        # A Watch restarted after its phone shows the phone as disconnected until the phone restarts.
        if watch:
            set_language(udids[watch.slug], language, LANGUAGES[language])
            udid = udids[device.slug]
            print(f"{device.name}, {language}")
            prepare(udid, device, language, pinned)
            folder = args.output / device.slug / language
            shutil.rmtree(folder, ignore_errors=True)
            folder.mkdir(parents=True)
            log = logs / f"{device.slug}-{language}.log"
            if device.platform == "watchOS":
                simctl("uninstall", udid, WATCH_APP, check=False)
                launch_phone_app(udids[WATCH_PHONE.slug], clock)
                passed = run_tests(
                    watch_run, udid, "TigerDuckWatch Watch AppUITests/WatchScreenshotTests", (), folder, clock, log,
                )
            else:
                simctl("uninstall", udid, APP, check=False)
                simctl("keychain", udid, "reset")
                passed = run_tests(
                    phone_run, udid, "TigerDuckUITests/AppStoreScreenshotTests", device.skipped, folder, clock, log,
                )
            if not passed:
                problems.append(f"{device.name}, {language}: a test failed; see {log}")
            problems += size_problems(folder, device)

    for problem in problems:
        print(f"error: {problem}")
    print(f"screenshots in {args.output}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
