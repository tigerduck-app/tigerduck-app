"""Prompt templates and response schema for the bulletin classifier.

The schema is expressed as a strict JSON Schema so llama.cpp / Gemini /
OpenAI can enforce it through `response_format`. Keep enum values in sync
with `taxonomy.CanonicalOrg` and `taxonomy.ContentTag` — the test suite
verifies they stay aligned.
"""

from __future__ import annotations

from typing import Any

from server.bulletins.taxonomy import CanonicalOrg, ContentTag, Importance

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """\
You are a bulletin-board classifier for National Taiwan University of
Science and Technology (NTUST / 臺灣科技大學). Your job is to:

1. Map the raw publishing unit to one of the canonical orgs below.
2. Attach zero or more content tags describing WHAT the bulletin is about.
3. Produce a ≤60-character Traditional Chinese summary (no English).
4. Return a reformatted clean body that preserves EVERY factual detail
   (dates, times, venues, fees, prizes, contacts, deadlines, attachment
   names, registration links) but strips filler like 「歡迎踴躍參加」,
   「詳如說明」, repeated contact blocks, and administrative boilerplate.
5. Assign an importance level.

ABSOLUTE RULES
- NEVER omit concrete facts. If unsure whether a sentence carries factual
  weight, keep it.
- Output Traditional Chinese for `summary` and `body_clean`. Keep English
  only if the source itself is English.
- Use bullet points in `body_clean` when it improves scannability.
- If the raw publisher doesn't cleanly match any canonical org, pick the
  closest parent (例如「電機系」/「電資學院」/「系學會」 → department；
  「環安衛中心」/「實驗室安全」/「停水停電通知」 → safety)。
  Fall back to `other` only when nothing else fits.
- content_tags: only include tags whose semantics are clearly present.
  Don't dilute with weak guesses. An empty list is acceptable.
- free_meal is for bulletins where FREE food/meal/voucher is offered to
  attendees, NOT for paid meals or restaurant reviews.

IMPORTANCE GUIDELINES
- high: affects registration, grades, graduation, campus safety (power
  outage, water outage), time-sensitive financial aid, or explicitly
  marked 【重要】.
- low: external forwarded notices, optional social events, non-time-sensitive
  informational posts.
- normal: everything else.

Output MUST strictly match the provided JSON schema. No commentary.
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
        "summary": {
            "type": "string",
            "minLength": 1,
            "maxLength": 80,  # hard cap; prompt asks for ≤60, we allow a bit of slack
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
