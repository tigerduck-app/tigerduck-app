"""Canonical taxonomy for NTUST bulletins.

Two orthogonal dimensions:
* `CanonicalOrg` (Dim 1, single-valued) — normalized publisher after merging
  synonyms like `教務處教發中心` / `教務處教學發展中心` / `教學發展中心`.
* `ContentTag` (Dim 2, multi-valued) — semantic labels such as `scholarship`,
  `event`, `free_meal`. A single bulletin can carry several.

A subscription rule is `(orgs: set[CanonicalOrg], tags: set[ContentTag], mode)`
where empty set means wildcard on that dimension. See `matcher.rule_hits`.

Enum-definition order is significant: `GET /v2/bulletins/taxonomy` iterates
the enum, so the iOS subscription editor renders the picker in this exact
sequence.
"""

from __future__ import annotations

from enum import StrEnum


class CanonicalOrg(StrEnum):
    department = "department"
    academic_affairs = "academic_affairs"
    student_affairs = "student_affairs"
    computer_center = "computer_center"
    language_center = "language_center"
    bilingual_office = "bilingual_office"
    general_education = "general_education"
    general_affairs = "general_affairs"
    hr = "hr"
    library = "library"
    pe = "pe"
    research = "research"
    industry_academia = "industry_academia"
    international = "international"
    safety = "safety"
    other = "other"


class ContentTag(StrEnum):
    free_meal = "free_meal"
    event = "event"
    scholarship = "scholarship"
    competition = "competition"
    course = "course"
    registration = "registration"
    housing = "housing"
    exam = "exam"
    facility = "facility"
    payment = "payment"
    internship = "internship"
    international_exchange = "international_exchange"
    forwarded = "forwarded"


class Importance(StrEnum):
    low = "low"
    normal = "normal"
    high = "high"


# Human-readable labels exposed to the iOS subscription UI via
# `GET /v2/bulletins/taxonomy`. Labels intentionally contain no slashes
# or other separators — the user-facing picker renders single-token names.
ORG_LABELS: dict[CanonicalOrg, str] = {
    CanonicalOrg.department: "系院所",
    CanonicalOrg.academic_affairs: "教務處",
    CanonicalOrg.student_affairs: "學務處",
    CanonicalOrg.computer_center: "電算中心",
    CanonicalOrg.language_center: "語言中心",
    CanonicalOrg.bilingual_office: "雙語辦公室",
    CanonicalOrg.general_education: "通識中心",
    CanonicalOrg.general_affairs: "總務處",
    CanonicalOrg.hr: "人事室",
    CanonicalOrg.library: "圖書館",
    CanonicalOrg.pe: "體育室",
    CanonicalOrg.research: "研發處",
    CanonicalOrg.industry_academia: "產學處",
    CanonicalOrg.international: "國際處",
    CanonicalOrg.safety: "安全",
    CanonicalOrg.other: "其他",
}


TAG_LABELS: dict[ContentTag, str] = {
    ContentTag.free_meal: "便當",
    ContentTag.event: "講座",
    ContentTag.scholarship: "獎助學金",
    ContentTag.competition: "競賽",
    ContentTag.course: "選課",
    ContentTag.registration: "註冊",
    ContentTag.housing: "宿舍",
    ContentTag.exam: "考試",
    ContentTag.facility: "維修",
    ContentTag.payment: "繳費",
    ContentTag.internship: "實習",
    ContentTag.international_exchange: "國際",
    ContentTag.forwarded: "轉發",
}


# Defaults shipped to a freshly-installed iOS client until the user edits
# them. Low-noise, high-value tags only; orgs wide-open so nothing important
# is silently missed. `important` is no longer a tag — `Importance` is its
# own field on the bulletin and the client filters on it directly.
DEFAULT_TAGS_FOR_NEW_USER: frozenset[ContentTag] = frozenset(
    {
        ContentTag.free_meal,
        ContentTag.scholarship,
        ContentTag.payment,
        ContentTag.exam,
        ContentTag.facility,
    }
)


class SubscriptionMode(StrEnum):
    AND = "AND"
    OR = "OR"
