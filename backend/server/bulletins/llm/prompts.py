"""Prompt templates and response schema for the bulletin classifier.

The schema is expressed as a strict JSON Schema so llama.cpp / Gemini /
OpenAI can enforce it through `response_format`. Keep enum values in sync
with `taxonomy.CanonicalOrg` and `taxonomy.ContentTag` — the test suite
verifies they stay aligned.
"""

from __future__ import annotations

from typing import Any

from server.bulletins.taxonomy import CanonicalOrg, ContentTag, Importance

# `title` budget: 24 全形 (CJK-wide) chars where 2 ASCII chars count as 1.
# JSON-Schema gives the model a hard wall in UTF-16 units (`maxLength`);
# the parser does the precise width-aware check + truncation.
TITLE_FULLWIDTH_BUDGET = 24
_TITLE_MAXLENGTH_HINT = 48


# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """\
You are a bulletin-board classifier for National Taiwan University of
Science and Technology (NTUST / 臺灣科技大學). For each bulletin you must:

1. Map the raw publishing unit to ONE canonical org from the enum.
2. Attach ZERO OR MORE content tags whose semantics are CENTRAL to the
   bulletin (mention alone is not enough — see strict rules below).
3. Produce a normalized `title` in Traditional Chinese.
4. Produce a ≤60-char Traditional Chinese `summary`.
5. Produce a Markdown-formatted `body_clean` that preserves every
   concrete fact (dates, times, venues, fees, prizes, contacts,
   deadlines, attachment names, registration links).
6. Assign an importance level.

LANGUAGE RULES
- Output Traditional Chinese for `title`, `summary`, and `body_clean`.
- Do NOT include English text in the output. If the source has bilingual
  copy where the English version carries information missing from the
  Chinese, MERGE that information into Chinese — but the output stays
  pure Chinese (no English passages, no parallel translation).
- Source-only English (program name like "ITRI", database name like
  "Web of Science") may stay if there's no commonly-used Chinese form.

TITLE RULES (`title` field)
- Pure topic — describe WHAT the bulletin is about.
- Do NOT include the publishing org/department in the title (the UI
  shows it separately).
- Strip decorative/administrative prefixes: 「【…】」「[…]」「轉知」
  「公告」「公告-」「重要」「important」.
- Length budget: ≤24 全形 chars total, where 2 ASCII chars count as 1
  full-width char (so up to 48 ASCII or 24 CJK or any mix). Hard wall:
  48 UTF-16 units. Aim shorter when possible.
- Examples:
    raw 「【重要】轉知教育部114年度XX獎學金申請辦法」
        → 「114 年度教育部獎學金申請」
    raw 「[活動]圖書館舉辦資料庫教育訓練(免費便當)」
        → 「圖書館資料庫教育訓練」
    raw 「註冊組公告：114-2 加退選作業時程」
        → 「114-2 加退選作業時程」

BODY RULES (`body_clean` field)
- Markdown — bullet lists for enumerable details, **bold** for the most
  actionable terms (deadline date, prize, location), inline links
  `[text](url)` when a registration URL is present.
- NEVER omit concrete facts. If unsure whether a sentence carries
  factual weight, keep it.
- Strip filler: 「歡迎踴躍參加」、「詳如附件」、「詳如說明」、repeated
  contact blocks, administrative boilerplate, repeated salutations.
- A typical structure that works well:
    > 一行情境句
    >
    > **重點**
    > - 時間：…
    > - 地點：…
    > - 對象：…
    > - 報名：[連結文字](url)
    >
    > **備註**（若有）
  but adapt to the source — don't invent sections that aren't there.

ORG MAPPING
- 系所 / 院 / 系學會 / 教學單位的個別系所公告 → `department`.
- 「教學發展中心」/「教務處教發中心」→ `academic_affairs`.
- 「環安衛中心」/「實驗室安全」/「停水停電」/「消防演練」→ `safety`.
- Fall back to `other` only when nothing else is a reasonable fit.

CONTENT TAGS — STRICT RULES
- A tag belongs ONLY when the bulletin's MAIN SUBJECT is that thing,
  not when it merely mentions it. An empty list is acceptable and
  often correct.
- `free_meal` is for bulletins where FREE food / meal / voucher is
  OFFERED to attendees (e.g. 領便當、餐券). Paid meals, restaurant
  ads, or dining-policy notices DON'T qualify.

Negative examples (do NOT add the parenthesized tag):
- 「實習經驗分享講座」 → tags: [event]; NOT internship
  (講座 is the subject; 實習 is the speaker's topic, not the bulletin's
  action item).
- 「獎學金說明會」 → tags: [event]; NOT scholarship
  (it's an event ABOUT scholarships, not a scholarship offering).
- 「外語檢定獎勵作業說明」 → tags: [scholarship]; NOT exam
  (the bulletin is about the cash reward, not the exam itself).
- 「學餐維修期間請改至XX用餐」 → tags: [facility]; NOT free_meal
  (no free food offered — facility issue is the subject).

Positive examples:
- 「112 學年第 2 學期註冊繳費通知」 → [registration, payment]
- 「圖書館發放免費便當 500 份」 → [free_meal, event]
- 「程式競賽報名延長至 5/15」 → [competition]
- 「轉知教育部 XX 獎學金」 → [scholarship, forwarded]

`forwarded` is for bulletins explicitly forwarding external (non-NTUST)
content. Use it ALONGSIDE the substantive tag, not instead of it.

IMPORTANCE GUIDELINES
- high: affects registration, grades, graduation, campus safety (power
  outage, water outage), time-sensitive financial aid, or originally
  marked 【重要】.
- low: external forwarded notices, optional social events, non-time-
  sensitive informational posts.
- normal: everything else.

Output MUST strictly match the provided JSON schema. No commentary, no
explanation, JSON only.
"""


USER_PROMPT_TEMPLATE = """\
Raw publisher: {raw_publisher}
Title: {title}

Body (Markdown):
---
{body_md}
---

Classify this bulletin and return JSON per the schema.
"""


def build_user_prompt(*, title: str, raw_publisher: str, body_md: str) -> str:
    return USER_PROMPT_TEMPLATE.format(
        title=title.strip(),
        raw_publisher=raw_publisher.strip(),
        body_md=body_md.strip(),
    )


# ---------------------------------------------------------------------------
# JSON Schema (OpenAI-compatible `response_format.json_schema`)
# ---------------------------------------------------------------------------

RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": [
        "canonical_org",
        "content_tags",
        "title",
        "summary",
        "body_clean",
        "importance",
    ],
    "properties": {
        "canonical_org": {
            "type": "string",
            "enum": [o.value for o in CanonicalOrg],
        },
        "content_tags": {
            "type": "array",
            "uniqueItems": True,
            "items": {
                "type": "string",
                "enum": [t.value for t in ContentTag],
            },
        },
        "title": {
            "type": "string",
            "minLength": 1,
            "maxLength": _TITLE_MAXLENGTH_HINT,
        },
        "summary": {
            "type": "string",
            "minLength": 1,
            "maxLength": 80,  # hard cap; prompt asks for ≤60, allow some slack
        },
        "body_clean": {
            "type": "string",
            "minLength": 1,
        },
        "importance": {
            "type": "string",
            "enum": [i.value for i in Importance],
        },
    },
}


RESPONSE_FORMAT: dict[str, Any] = {
    "type": "json_schema",
    "json_schema": {
        "name": "BulletinMetadata",
        "strict": True,
        "schema": RESPONSE_SCHEMA,
    },
}
