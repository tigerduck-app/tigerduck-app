"""Measure the public course query service (querycourse.ntust.edu.tw) for issue #547.

The service needs no sign-in. Every call goes through Probe, which pauses between calls,
stops at a request budget counted over all runs, and appends one JSON line per call to
<out>/requests.jsonl; `analyse` and `--self-check` read only that log and never the network.
"""

from __future__ import annotations

import argparse
import gzip
import json
import statistics
import string
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Lock

import httpx

from api import RUNTIME_DIR

BASE = "https://querycourse.ntust.edu.tw/querycourse/api"
PAUSE_SECONDS = 1.0
DEFAULT_BUDGET = 190
# The server answers an empty filter with HTTP 500 after 120 s, so wait a little longer.
TIMEOUT_SECONDS = 150
KEPT_HEADERS = (
    "cache-control", "etag", "last-modified", "expires", "vary", "content-encoding",
    "content-length", "transfer-encoding", "connection", "keep-alive", "server",
    "x-powered-by", "alt-svc",
)
# 3 holds the alliance courses (3N NTNU, 3T NTU), split so no query nears the 120 s timeout.
SWEEP_PREFIXES = (*string.ascii_uppercase, "0", "1", "2", "3N", "3T", "4", "5", "6", "7", "8", "9")


def course_body(semester: str, language: str = "zh", **fields: object) -> dict:
    """The body CourseSearchRequest sends; OnlyIntensive is the one field only the site adds."""
    body = {
        "Semester": semester, "CourseNo": "", "CourseName": "", "CourseTeacher": "",
        "Dimension": "", "CourseNotes": "", "CampusNotes": "", "ForeignLanguage": 0,
        "OnlyGeneral": 0, "OnleyNTUST": 0, "OnlyMaster": 0, "OnlyUnderGraduate": 0,
        "OnlyNode": 0, "Language": language,
    }
    unknown = fields.keys() - body.keys() - {"OnlyIntensive"}
    if unknown:
        raise ValueError(f"unknown request fields: {sorted(unknown)}")
    return body | fields


def phase_times(events: dict[str, float], start: float) -> dict:
    """Connect, TLS and first-byte times from httpcore trace events, in seconds."""

    def span(name: str) -> float | None:
        began, done = events.get(f"connection.{name}.started"), events.get(f"connection.{name}.complete")
        return None if began is None or done is None else done - began

    headers_done = next(
        (t for name, t in events.items() if name.endswith("receive_response_headers.complete")), None
    )
    return {
        "connect": span("connect_tcp"),
        "tls": span("start_tls"),
        "ttfb": None if headers_done is None else headers_done - start,
        "reused": "connection.connect_tcp.started" not in events,
    }


class Probe:
    def __init__(self, out: Path, budget: int, pause: float = PAUSE_SECONDS) -> None:
        self.out = out
        (out / "bodies").mkdir(parents=True, exist_ok=True)
        self.log = out / "requests.jsonl"
        logged = load_log(out)
        self.used = len(logged)
        # A rerun skips calls that already succeeded, so it spends the budget only on new ones.
        self.done = {(r["step"], r["label"]): r for r in logged if r.get("status") == 200}
        self.budget = budget
        self.pause = pause
        self.lock = Lock()
        self.client = httpx.Client(http2=True, timeout=TIMEOUT_SECONDS)

    def call(
        self, step: str, label: str, path: str, body: dict | None = None,
        headers: dict | None = None, client: httpx.Client | None = None, pause: bool = True,
    ) -> dict:
        if (step, label) in self.done:
            return self.done[(step, label)]
        with self.lock:
            if self.used >= self.budget:
                raise SystemExit(f"request budget of {self.budget} reached")
            self.used += 1
            number = self.used
        events: dict[str, float] = {}

        def trace(name: str, _info: dict) -> None:
            events.setdefault(name, time.perf_counter())

        start = time.perf_counter()
        record: dict = {"n": number, "step": step, "label": label, "path": path, "body": body,
                        "sent_headers": headers, "wall": time.time()}
        try:
            response = (client or self.client).request(
                "POST" if body is not None else "GET", f"{BASE}/{path}",
                json=body, headers=headers, extensions={"trace": trace},
            )
            record |= {"status": response.status_code, "http_version": response.http_version,
                       "headers": {k: v for k, v in response.headers.items() if k in KEPT_HEADERS}}
            try:
                content = response.content
                record["wire_bytes"] = response.num_bytes_downloaded
                record["bytes"] = len(content)
                data = json.loads(content)
                record["rows"] = len(data) if isinstance(data, list) else None
                if response.status_code == 200:
                    (self.out / "bodies" / f"{number:03d}.json").write_bytes(content)
                else:
                    record["error_body"] = content[:200].decode("utf-8", "replace")
            except (httpx.DecodingError, ValueError) as exc:
                record["error"] = repr(exc)
        except httpx.HTTPError as exc:
            record["error"] = repr(exc)
        record["seconds"] = time.perf_counter() - start
        record |= phase_times(events, start)
        with self.lock, self.log.open("a") as log:
            log.write(json.dumps(record, ensure_ascii=False) + "\n")
        print(f"{number:3d} {step:<10} {label:<34} {record.get('status')} "
              f"{record['seconds']:7.2f}s rows={record.get('rows')} bytes={record.get('bytes')}",
              flush=True)
        if pause:
            time.sleep(self.pause)
        return record

    def courses(self, step: str, label: str, semester: str, **fields: object) -> dict:
        return self.call(step, label, "courses", course_body(semester, **fields))

    def body_of(self, record: dict) -> list | dict | None:
        path = self.out / "bodies" / f"{record['n']:03d}.json"
        return json.loads(path.read_text()) if path.exists() else None


def run_options(probe: Probe, semester: str) -> None:
    records = {path: probe.call("options", path, path)
               for path in ("semestersinfo", "dimensions", "Colleges/", "departments")}
    for college in probe.body_of(records["Colleges/"]) or []:
        probe.call("options", f"departments {college['CollegeNo']}",
                   f"departments?collegeNo={college['CollegeNo']}")


def run_sweep(probe: Probe, semester: str, language: str = "zh") -> None:
    """The whole semester as one CourseNo prefix query each, since the empty filter fails."""
    for prefix in SWEEP_PREFIXES:
        probe.courses("sweep", f"{language} CourseNo={prefix}", semester, CourseNo=prefix,
                      Language=language)


def sweep_rows(out: Path, language: str = "zh") -> list[dict]:
    rows: list[dict] = []
    for record in load_log(out):
        if record["step"] == "sweep" and record["label"].startswith(language) and record.get("rows"):
            rows += json.loads((out / "bodies" / f"{record['n']:03d}.json").read_text())
    return rows


def samples(rows: list[dict]) -> dict[str, dict]:
    """One query of each kind the search page sends, taken from the swept semester."""
    course = next(r for r in rows if r["CourseNo"].startswith("CS"))
    return {
        "number": {"CourseNo": course["CourseNo"]},
        "prefix CS": {"CourseNo": "CS"},
        "prefix EC10": {"CourseNo": "EC10"},
        "name": {"CourseName": "微積分"},
        "teacher": {"CourseTeacher": course["CourseTeacher"]},
    }


def run_latency(probe: Probe, semester: str, rounds: int = 5) -> None:
    kinds = samples(sweep_rows(probe.out))
    for round_no in range(rounds):
        for kind, fields in kinds.items():
            probe.courses("latency", f"{kind} #{round_no}", semester, **fields)
        if round_no < 3:
            probe.courses("latency", f"flag-only OnlyGeneral #{round_no}", semester, OnlyGeneral=1)
    probe.courses("latency", "empty #1", semester)


def run_parallel(probe: Probe, semester: str) -> None:
    """The add-course sheet's fan-out: name and teacher, each in zh and en, alone and at once."""

    def fan_out(label: str, fields: list[dict], together: bool, name_key: str | None = None) -> None:
        mode = "parallel" if together else "serial"
        calls = [(f"{label} {mode} {f['Language']} {name_key or next(iter(f))}"
                  + (f"={f[name_key]}" if name_key else ""), f) for f in fields]
        start = time.perf_counter()
        if together:
            with ThreadPoolExecutor(len(calls)) as pool:
                list(pool.map(lambda c: probe.call("parallel", c[0], "courses",
                                                   course_body(semester, **c[1]), pause=False), calls))
        else:
            for name, body_fields in calls:
                probe.call("parallel", name, "courses", course_body(semester, **body_fields),
                           pause=False)
        print(f"    {label} {mode}: wall {time.perf_counter() - start:.2f}s", flush=True)
        time.sleep(probe.pause * 3)

    def name_and_teacher(keyword: str) -> list[dict]:
        return [{key: keyword, "Language": language}
                for language in ("zh", "en") for key in ("CourseName", "CourseTeacher")]

    fan_out("name 微積分", name_and_teacher("微積分"), together=False)
    fan_out("name 微積分", name_and_teacher("微積分"), together=True)
    fan_out("name 管理", name_and_teacher("管理"), together=True)
    fan_out("name 管理", name_and_teacher("管理"), together=False)
    code = [{"CourseNo": "EC10", "Language": language} for language in ("zh", "en")]
    fan_out("code EC10", code, together=True)
    fan_out("code EC10", code, together=False)
    heavy = [{"CourseNo": prefix, "Language": "zh"} for prefix in ("A", "B", "D")]
    fan_out("prefixes A B D", heavy, together=True, name_key="CourseNo")
    fan_out("prefixes A B D", heavy, together=False, name_key="CourseNo")


def behaviour_checks(rows: list[dict]) -> dict[str, dict]:
    """Each check's request fields. Bases: CS has English-taught courses with and without EMI,
    EE has every level digit, and T has the TU-numbered courses."""
    teacher = next(r["CourseTeacher"] for r in rows
                   if r["CourseNo"].startswith("CS") and len(r["CourseTeacher"]) == 3)
    return {
        "CourseNo=cs": {"CourseNo": "cs"},
        "CourseNo=ec10": {"CourseNo": "ec10"},
        "CourseName=程式": {"CourseName": "程式"},
        "en CourseName=calculus": {"CourseName": "calculus", "Language": "en"},
        "en CourseName=CALCULUS": {"CourseName": "CALCULUS", "Language": "en"},
        "zh CourseName=Calculus": {"CourseName": "Calculus"},
        "en CourseName=微積分": {"CourseName": "微積分", "Language": "en"},
        "teacher surname": {"CourseTeacher": teacher[0]},
        "teacher given name": {"CourseTeacher": teacher[1:]},
        "en CourseNo=CS": {"CourseNo": "CS", "Language": "en"},
        "Dimension=A": {"Dimension": "A"},
        "Dimension=A OnlyGeneral": {"Dimension": "A", "OnlyGeneral": 1},
        "OnlyGeneral CourseName=文": {"OnlyGeneral": 1, "CourseName": "文"},
        "OnlyIntensive": {"OnlyIntensive": 1},
        "CS ForeignLanguage": {"CourseNo": "CS", "ForeignLanguage": 1},
        "CS CourseNotes=eng": {"CourseNo": "CS", "CourseNotes": "eng"},
        "CS CourseNotes=EMI": {"CourseNo": "CS", "CourseNotes": "EMI"},
        "CS CourseNotes=eng,EMI": {"CourseNo": "CS", "CourseNotes": "eng,EMI"},
        "EE OnlyMaster": {"CourseNo": "EE", "OnlyMaster": 1},
        "EE OnlyUnderGraduate": {"CourseNo": "EE", "OnlyUnderGraduate": 1},
        "EE OnlyMaster OnlyUnderGraduate": {"CourseNo": "EE", "OnlyMaster": 1, "OnlyUnderGraduate": 1},
        "EE OnlyNode": {"CourseNo": "EE", "OnlyNode": 1},
        "T OnleyNTUST": {"CourseNo": "T", "OnleyNTUST": 1},
        "CS OnlyMaster CourseNotes=eng": {"CourseNo": "CS", "OnlyMaster": 1, "CourseNotes": "eng"},
        "微積分 OnleyNTUST": {"CourseName": "微積分", "OnleyNTUST": 1},
        "ForeignLanguage": {"ForeignLanguage": 1},
        "微積分 ForeignLanguage": {"CourseName": "微積分", "ForeignLanguage": 1},
        "3N5 OnlyMaster": {"CourseNo": "3N5", "OnlyMaster": 1},
        "3TG OnlyUnderGraduate": {"CourseNo": "3TG", "OnlyUnderGraduate": 1},
        "TCG OnlyMaster": {"CourseNo": "TCG", "OnlyMaster": 1},
    }


def run_behaviour(probe: Probe, semester: str) -> None:
    for label, fields in behaviour_checks(sweep_rows(probe.out)).items():
        probe.courses("behaviour", label, semester, **fields)


def run_connection(probe: Probe, semester: str) -> None:
    for i in range(5):
        probe.call("connection", f"kept-alive dimensions #{i}", "dimensions")
    for i in range(5):
        with httpx.Client(http2=True, timeout=TIMEOUT_SECONDS) as fresh:
            probe.call("connection", f"new-connection dimensions #{i}", "dimensions", client=fresh)
    body = course_body(semester, CourseNo="CS")
    for encoding in ("gzip", "br", "identity"):
        probe.call("connection", f"Accept-Encoding {encoding} CS", "courses", body,
                   headers={"Accept-Encoding": encoding})
    probe.call("connection", "If-Modified-Since semestersinfo", "semestersinfo",
               headers={"If-Modified-Since": "Sat, 01 Jan 2050 00:00:00 GMT"})
    probe.call("connection", "If-None-Match semestersinfo", "semestersinfo",
               headers={"If-None-Match": "*"})
    probe.call("connection", "If-Modified-Since CS", "courses", body,
               headers={"If-Modified-Since": "Sat, 01 Jan 2050 00:00:00 GMT"})
    course_no = next(r["CourseNo"] for r in sweep_rows(probe.out) if r["CourseNo"].startswith("CS"))
    probe.call("connection", "coursedetials", f"coursedetials?semester={semester}"
               f"&course_no={course_no}&language=zh")


def load_log(out: Path) -> list[dict]:
    log = out / "requests.jsonl"
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def local_match(row: dict, fields: dict) -> bool | None:
    """The request applied to one zh row on the device; None when the swept data cannot say."""
    if fields.get("OnlyIntensive"):
        return None
    contents, level = row["Contents"] or "", row["CourseNo"][2:3]
    notes = {"eng": "英語授課", "EMI": "EMI課程"}
    return all((
        row["CourseNo"].casefold().startswith(fields.get("CourseNo", "").casefold()),
        fields.get("CourseName", "").casefold() in row["CourseName"].casefold(),
        fields.get("CourseTeacher", "") in row["CourseTeacher"],
        not fields.get("Dimension") or row["Dimension"] == fields["Dimension"],
        not fields.get("OnlyGeneral") or bool(row["Dimension"]),
        # Chinese for foreign students (FE) and second foreign languages (FL38), not English-taught.
        not fields.get("ForeignLanguage") or row["CourseNo"].startswith(("FE", "FL38")),
        all(notes[n] in contents for n in filter(None, fields.get("CourseNotes", "").split(","))),
        not fields.get("OnlyMaster") or level in "56789",
        not fields.get("OnlyUnderGraduate") or level in "1234G",
        not fields.get("OnleyNTUST") or not row["CourseNo"].startswith("3"),
    ))


def compare_local(out: Path) -> None:
    """Each zh query's server answer against local_match over the swept semester."""
    rows = sweep_rows(out)
    for record in load_log(out):
        body = record.get("body") or {}
        repeat = record["step"] == "latency" and not record["label"].endswith("#0")
        if record["path"] != "courses" or record.get("status") != 200 or repeat \
                or record["step"] in ("sweep", "parallel") or body.get("Language") != "zh":
            continue
        fields = _set_fields(body)
        verdicts = [local_match(r, fields) for r in rows]
        if None in verdicts:
            print(f"  {record['label']:<34} server={record['rows']:<4} local=n/a (not in the data)")
            continue
        answer = json.loads((out / "bodies" / f"{record['n']:03d}.json").read_text())
        server = {(r["CourseNo"], r["Node"]) for r in answer}
        local = {(r["CourseNo"], r["Node"]) for r, keep in zip(rows, verdicts) if keep}
        verdict = ("same" if server == local
                   else f"server-only={len(server - local)} local-only={len(local - server)}")
        print(f"  {record['label']:<34} server={len(server):<4} local={len(local):<4} {verdict}")


def summarise(seconds: list[float]) -> str:
    return (f"n={len(seconds)} median={statistics.median(seconds):.2f}s "
            f"worst={max(seconds):.2f}s best={min(seconds):.2f}s")


def kind_of(label: str) -> str:
    return label.split(" #")[0]


def analyse(out: Path) -> None:
    log = load_log(out)
    course_calls = [r for r in log if r["path"] == "courses" and r.get("status") == 200]

    print("== latency by kind (sequential samples)")
    by_kind: dict[str, list[dict]] = {}
    for r in log:
        if r["step"] == "latency":
            by_kind.setdefault(kind_of(r["label"]), []).append(r)
    for kind, records in by_kind.items():
        rows = {r.get("rows") for r in records}
        print(f"  {kind:<22} {summarise([r['seconds'] for r in records])} rows={rows} "
              f"status={Counter(r.get('status') for r in records)}")

    print("== seconds against rows, successful sequential course queries")
    for name, only_no in (("all", False), ("CourseNo only", True)):
        points = [(r["rows"], r["seconds"]) for r in course_calls if r["step"] != "parallel"
                  and (not only_no or set(_set_fields(r["body"])) == {"CourseNo"})]
        slope, intercept = statistics.linear_regression(*zip(*points))
        print(f"  {name}: {len(points)} queries, seconds = {intercept:.2f} + "
              f"{slope * 1000:.1f} ms per row, r={statistics.correlation(*zip(*points)):.3f}")

    print("== parallel against serial (wall = first start to last finish)")
    groups: dict[str, list[dict]] = {}
    for r in log:
        if r["step"] == "parallel":
            group = r["label"].rsplit(" ", 2)[0]
            groups.setdefault(group, []).append(r)
    for group, records in groups.items():
        wall = max(r["wall"] + r["seconds"] for r in records) - min(r["wall"] for r in records)
        print(f"  {group:<26} wall={wall:5.2f}s each={[round(r['seconds'], 2) for r in records]}")

    print("== sweep")
    for language in ("zh", "en"):
        sweep = [r for r in log if r["step"] == "sweep" and r["label"].startswith(language)]
        if not sweep:
            continue
        rows = sweep_rows(out, language)
        print(f"  {language}: {len(sweep)} queries, {len(rows)} rows, "
              f"{len({r['CourseNo'] for r in rows})} course numbers, "
              f"{sum(r.get('bytes') or 0 for r in sweep)} bytes, "
              f"{sum(r['seconds'] for r in sweep):.1f}s in total, slowest "
              f"{max(r['seconds'] for r in sweep):.1f}s; gzip would make it "
              f"{len(gzip.compress(json.dumps(rows, ensure_ascii=False).encode()))} bytes")

    print("== option lists")
    for r in log:
        if r["step"] == "options":
            print(f"  {r['label']:<16} rows={r.get('rows'):<3} bytes={r.get('bytes'):<5} "
                  f"{r['seconds']:.2f}s")

    print("== connection")
    for prefix in ("kept-alive", "new-connection"):
        records = [r for r in log if r["label"].startswith(prefix)]
        if records:
            print(f"  {prefix:<15} {summarise([r['seconds'] for r in records])} "
                  f"connect={[round(r['connect'] or 0, 3) for r in records]} "
                  f"tls={[round(r['tls'] or 0, 3) for r in records]}")
    print(f"  http versions: {Counter(r.get('http_version') for r in log)}")
    print(f"  response headers seen: {sorted({k for r in log for k in r.get('headers', {})})}")
    print(f"  content-encoding: {Counter(r.get('headers', {}).get('content-encoding') for r in log)}")
    for r in log:
        if r["step"] == "connection" and ("Accept-Encoding" in r["label"] or "If-" in r["label"]):
            print(f"  {r['label']:<34} status={r.get('status')} wire={r.get('wire_bytes')} "
                  f"decoded={r.get('bytes')} {r.get('error', '')}")

    print("== server filters against local_match over the sweep")
    compare_local(out)


def _set_fields(body: dict) -> dict:
    return {k: v for k, v in body.items() if k not in ("Semester", "Language") and v not in ("", 0)}


def _self_check() -> None:
    body = course_body("1151", CourseNo="CS", OnlyIntensive=1)
    assert body["CourseNo"] == "CS" and body["OnlyIntensive"] == 1 and body["Language"] == "zh"
    assert "OnlyIntensive" not in course_body("1151")
    try:
        course_body("1151", Typo=1)
    except ValueError:
        pass
    else:
        raise AssertionError("an unknown field must be refused")

    fresh = phase_times({
        "connection.connect_tcp.started": 1.0, "connection.connect_tcp.complete": 1.25,
        "connection.start_tls.started": 1.25, "connection.start_tls.complete": 1.5,
        "http11.receive_response_headers.complete": 3.0,
    }, start=1.0)
    assert fresh == {"connect": 0.25, "tls": 0.25, "ttfb": 2.0, "reused": False}
    assert phase_times({}, start=0.0) == {"connect": None, "tls": None, "ttfb": None, "reused": True}
    assert kind_of("prefix CS #3") == "prefix CS"

    row = {"CourseNo": "CS5101701", "CourseName": "Deep Learning 深度學習", "CourseTeacher": "王小明",
           "Dimension": "", "Contents": "英語授課／EMI課程", "Node": "M2,M3"}
    for fields, expected in (
        ({"CourseNo": "cs51"}, True), ({"CourseNo": "S51"}, False),
        ({"CourseName": "deep"}, True), ({"CourseName": "學習"}, True),
        ({"CourseTeacher": "小明"}, True), ({"OnlyMaster": 1}, True),
        ({"OnlyUnderGraduate": 1}, False), ({"OnlyMaster": 1, "OnlyUnderGraduate": 1}, False),
        ({"CourseNotes": "eng,EMI"}, True), ({"OnlyGeneral": 1}, False),
        ({"OnleyNTUST": 1}, True), ({"OnlyNode": 1}, True), ({"OnlyIntensive": 1}, None),
    ):
        assert local_match(row, fields) is expected, fields
    alliance = row | {"CourseNo": "3TG031701", "Dimension": "A", "Contents": ""}
    assert local_match(alliance, {"OnleyNTUST": 1}) is False
    assert local_match(alliance, {"Dimension": "A", "OnlyGeneral": 1, "OnlyUnderGraduate": 1}) is True
    print("self-check OK")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("step", choices=list(STEPS) + ["analyse"])
    parser.add_argument("--semester", default="1151")
    parser.add_argument("--out", type=Path, default=RUNTIME_DIR / "course_query")
    parser.add_argument("--budget", type=int, default=DEFAULT_BUDGET)
    args = parser.parse_args()
    if args.step == "analyse":
        analyse(args.out)
        return 0
    STEPS[args.step](Probe(args.out, args.budget), args.semester)
    return 0


STEPS = {
    "options": run_options, "sweep": run_sweep, "latency": run_latency,
    "parallel": run_parallel, "behaviour": run_behaviour, "connection": run_connection,
}

if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
        raise SystemExit(0)
    raise SystemExit(main())
