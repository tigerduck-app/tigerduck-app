"""Canonical taxonomy for NTUST bulletins.

Two orthogonal dimensions:
* `CanonicalOrg` (Dim 1, single-valued) — normalized publisher after merging
  synonyms like `教務處教發中心` / `教務處教學發展中心` / `教學發展中心`.
* `ContentTag` (Dim 2, multi-valued) — semantic labels such as `scholarship`,
  `event`, `free_meal`. A single bulletin can carry several.

A subscription rule is `(orgs: set[CanonicalOrg], tags: set[ContentTag], mode)`
where empty set means wildcard on that dimension. See `matcher.rule_hits`.
"""

from __future__ import annotations

from enum import StrEnum


class CanonicalOrg(StrEnum):
    academic_affairs = "academic_affairs"
    research = "research"
    computer_center = "computer_center"
    industry_academia = "industry_academia"
    international = "international"
    general_education = "general_education"
    pe = "pe"
    student_affairs = "student_affairs"
    library = "library"
    language_center = "language_center"
    hr = "hr"
    bilingual_office = "bilingual_office"
    secretariat = "secretariat"
    general_affairs = "general_affairs"
    safety = "safety"
    continuing_education = "continuing_education"
    college_eecs = "college_eecs"
    college_other = "college_other"
    department = "department"
    other = "other"


class ContentTag(StrEnum):
    scholarship = "scholarship"
    event = "event"
    competition = "competition"
    career = "career"
    course = "course"
    exam = "exam"
    registration = "registration"
    payment = "payment"
    housing = "housing"
    health = "health"
    facility = "facility"
    international_exchange = "international_exchange"
    library_resource = "library_resource"
    forwarded = "forwarded"
    important = "important"
    free_meal = "free_meal"


class Importance(StrEnum):
    low = "low"
    normal = "normal"
    high = "high"


# Human-readable labels exposed to the iOS subscription UI via
# `GET /v1/bulletins/taxonomy`. Keeping the mapping here keeps the server as
# the single source of truth so the client never needs to hardcode strings.
ORG_LABELS: dict[CanonicalOrg, str] = {
    CanonicalOrg.academic_affairs: "教務處",
    CanonicalOrg.research: "研發處",
    CanonicalOrg.computer_center: "電算中心",
    CanonicalOrg.industry_academia: "產學處",
    CanonicalOrg.international: "國際處",
    CanonicalOrg.general_education: "通識中心",
    CanonicalOrg.pe: "體育室",
    CanonicalOrg.student_affairs: "學務處",
    CanonicalOrg.library: "圖書館",
    CanonicalOrg.language_center: "語言中心",
    CanonicalOrg.hr: "人事室",
    CanonicalOrg.bilingual_office: "雙語辦",
    CanonicalOrg.secretariat: "秘書室",
    CanonicalOrg.general_affairs: "總務處",
    CanonicalOrg.safety: "環安/防疫",
    CanonicalOrg.continuing_education: "推廣教育",
    CanonicalOrg.college_eecs: "電資學院",
    CanonicalOrg.college_other: "其他學院",
    CanonicalOrg.department: "系所",
    CanonicalOrg.other: "其他",
}


TAG_LABELS: dict[ContentTag, str] = {
    ContentTag.scholarship: "獎學金/助學金",
    ContentTag.event: "活動/講座",
    ContentTag.competition: "競賽",
    ContentTag.career: "徵才/實習",
    ContentTag.course: "選課/教學",
    ContentTag.exam: "考試/檢定",
    ContentTag.registration: "註冊/學籍",
    ContentTag.payment: "繳費",
    ContentTag.housing: "住宿",
    ContentTag.health: "衛保/防疫",
    ContentTag.facility: "停電水/維修",
    ContentTag.international_exchange: "國際交流",
    ContentTag.library_resource: "圖書資源",
    ContentTag.forwarded: "轉知",
    ContentTag.important: "重要",
    ContentTag.free_meal: "免費便當/餐食",
}


# Defaults shipped to a freshly-installed iOS client until the user edits
# them. Low-noise, high-value tags only; orgs wide-open so nothing important
# is silently missed.
DEFAULT_TAGS_FOR_NEW_USER: frozenset[ContentTag] = frozenset(
    {
        ContentTag.important,
        ContentTag.scholarship,
        ContentTag.payment,
        ContentTag.exam,
        ContentTag.facility,
        ContentTag.free_meal,
    }
)


class SubscriptionMode(StrEnum):
    AND = "AND"
    OR = "OR"
