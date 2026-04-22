"""Bulletin ingestion, classification, and notification pipeline.

Pipeline overview
-----------------
1. `scraper` — fetch the NTUST bulletin list page every N minutes, parse the
   HTML table into `ListRow` records.
2. `detail` — for each new `external_id`, fetch the detail page and extract
   Markdown via trafilatura.
3. `dedup` — drop entries whose content hash already exists (catches reposts
   with new IDs).
4. `llm` — send title + body to an OpenAI-compatible LLM with a JSON schema
   constraining the output: canonical_org, content_tags, summary, body_clean,
   importance.
5. `matcher` — expand each processed bulletin into (device, bulletin) pairs
   by matching `BulletinSubscription` rules per device.
6. `dispatcher` — send standard APNs alert push per pair, idempotent via
   the `(bulletin_id, device_id)` unique key in `bulletin_dispatches`.
"""
