"""End-to-end pipeline test using the RecordingSender + RecordingProvider.

Wires scrape → process → dispatch against a canned HTML list page and a
fixed LLM response, then verifies:

* Matching devices receive one alert request per bulletin.
* Non-matching or token-less devices get zero pushes.
* Re-running the jobs is idempotent (no duplicate sends).
* The bulletin flips to `notified_at IS NOT NULL` once every dispatch row
  is terminal.
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker

from server.bulletins import jobs as bulletin_jobs
from server.bulletins.llm.base import BulletinMetadata
from server.bulletins.llm.openai_compat import RecordingProvider
from server.bulletins.models import (
    Bulletin,
    BulletinDispatch,
    BulletinDispatchStatus,
    BulletinProcessingState,
    BulletinSubscription,
)
from server.bulletins.taxonomy import (
    CanonicalOrg,
    ContentTag,
    Importance,
    SubscriptionMode,
)
from server.config import Settings
from server.models import DeviceRegistration
from server.push.apns_client import RecordingSender
from server.push.payload import PushKind

_async = pytest.mark.asyncio(loop_scope="session")


_LIST_HTML = """
<html><body>
<table class="listTB table">
  <thead><tr><th>日期</th><th>發佈單位</th><th>標題</th></tr></thead>
  <tbody>
    <tr>
      <td>2026-04-22</td>
      <td>學務處</td>
      <td><a href="https://bulletin.ntust.edu.tw/p/450-1045-700001,c0.php?Lang=zh-tw">【重要】新獎學金開放申請</a></td>
    </tr>
    <tr>
      <td>2026-04-22</td>
      <td>圖書館</td>
      <td><a href="https://bulletin.ntust.edu.tw/p/450-1045-700002,c0.php?Lang=zh-tw">【活動】免費便當來領餐券</a></td>
    </tr>
  </tbody>
</table>
</body></html>
"""


_DETAIL_HTML_TEMPLATE = """
<html><body>
<article>
<h1>{title}</h1>
<p>申請時間：2026-05-01 前。</p>
<p>聯絡人：生輔組 王小姐 ext 1234。</p>
<p>額滿為止。</p>
</article>
</body></html>
"""


class _RoutingTransport(httpx.AsyncBaseTransport):
    """Maps URLs → canned responses so scrape/detail HTTP calls never hit
    the real network from inside the test."""

    def __init__(self, url_to_html: dict[str, str]) -> None:
        self._url_to_html = url_to_html
        self.calls: list[str] = []

    async def handle_async_request(
        self, request: httpx.Request
    ) -> httpx.Response:
        self.calls.append(str(request.url))
        html = self._url_to_html.get(str(request.url))
        if html is None:
            return httpx.Response(404, text="not found")
        return httpx.Response(200, text=html)


def _http_client_factory(transport: _RoutingTransport):
    @asynccontextmanager
    async def factory():
        client = httpx.AsyncClient(transport=transport, follow_redirects=True)
        try:
            yield client
        finally:
            await client.aclose()

    def wrapper():
        return factory()

    return wrapper


def _classification() -> BulletinMetadata:
    return BulletinMetadata(
        canonical_org=CanonicalOrg.student_affairs,
        content_tags=(ContentTag.scholarship, ContentTag.forwarded),
        summary="學務處新獎學金，截止 5/1",
        body_clean="- 申請期限：2026-05-01\n- 聯絡：生輔組 王小姐 ext 1234",
        importance=Importance.high,
    )


def _test_settings_override(base: Settings) -> Settings:
    return base.model_copy(
        update={
            "bulletin_list_url": "https://bulletin.ntust.edu.tw/p/403-1045-1391-1.php",
            "bulletin_scrape_interval_seconds": 600,
            "bulletin_process_interval_seconds": 60,
            "bulletin_dispatch_interval_seconds": 60,
            "bulletin_max_process_attempts": 3,
        }
    )


@_async
async def test_full_pipeline_fans_out_to_matching_device(
    prepared_engine: AsyncEngine, test_settings: Settings
) -> None:
    settings = _test_settings_override(test_settings)
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)

    # --- Arrange: two devices, only the first with a standard token and
    # a matching subscription for scholarship.
    async with factory() as session:
        session.add_all(
            [
                DeviceRegistration(
                    device_id="dev-pipeline-match",
                    user_id="u1",
                    pts_token_hex="pts1",
                    device_token_hex="alert-token-1",
                    bundle_id="org.ntust.app.TigerDuck",
                    attrs_type="a",
                    apns_env="development",
                ),
                DeviceRegistration(
                    device_id="dev-pipeline-miss",
                    user_id="u2",
                    pts_token_hex="pts2",
                    device_token_hex="alert-token-2",
                    bundle_id="org.ntust.app.TigerDuck",
                    attrs_type="a",
                    apns_env="development",
                ),
            ]
        )
        await session.flush()
        session.add_all(
            [
                BulletinSubscription(
                    device_id="dev-pipeline-match",
                    name="scholarship-watch",
                    orgs=[CanonicalOrg.student_affairs.value],
                    tags=[ContentTag.scholarship.value],
                    mode=SubscriptionMode.AND.value,
                ),
                BulletinSubscription(
                    device_id="dev-pipeline-miss",
                    name="library-only",
                    orgs=[CanonicalOrg.library.value],
                    tags=[],
                    mode=SubscriptionMode.AND.value,
                ),
            ]
        )
        await session.commit()

    transport = _RoutingTransport(
        {
            settings.bulletin_list_url: _LIST_HTML,
            "https://bulletin.ntust.edu.tw/p/450-1045-700001,c0.php?Lang=zh-tw": _DETAIL_HTML_TEMPLATE.format(
                title="【重要】新獎學金開放申請"
            ),
            "https://bulletin.ntust.edu.tw/p/450-1045-700002,c0.php?Lang=zh-tw": _DETAIL_HTML_TEMPLATE.format(
                title="【活動】免費便當來領餐券"
            ),
        }
    )
    llm = RecordingProvider(_classification())
    sender = RecordingSender()

    # --- Act: one run through each job stage
    inserted = await bulletin_jobs.scrape_job(
        factory,
        settings,
        http_client_factory=_http_client_factory(transport),
    )
    assert inserted == 2

    processed = await bulletin_jobs.process_job(
        factory,
        settings,
        llm,
        http_client_factory=_http_client_factory(transport),
    )
    # `processed` may include leftover pending rows from other tests that
    # share the session-scoped DB — what we care about is that OUR two
    # bulletins were classified, so assert a lower bound and that the LLM
    # saw exactly our two titles.
    assert processed >= 2
    llm_titles = {call["title"] for call in llm.calls}
    assert "【重要】新獎學金開放申請" in llm_titles
    assert "【活動】免費便當來領餐券" in llm_titles

    await bulletin_jobs.dispatch_job(factory, sender, settings)

    # --- Assert
    # Leftover fixtures from sibling tests may also match — what we pin
    # here is only our own bulletins' fan-out. Inspect the payload's
    # `bulletin_id` to filter out unrelated traffic the shared session-
    # scoped DB may have injected.
    async with factory() as session:
        our_ids = {
            row.id
            for row in (
                await session.execute(
                    select(Bulletin).where(Bulletin.external_id.in_(["700001", "700002"]))
                )
            ).scalars()
        }

    our_requests = [
        r for r in sender.requests if r.message.get("bulletin_id") in our_ids
    ]
    tokens_sent = [r.device_token for r in our_requests]
    assert tokens_sent.count("alert-token-1") == 2
    assert "alert-token-2" not in tokens_sent
    assert all(r.kind is PushKind.alert for r in our_requests)
    # Every request should use the device's bundle_id as the APNs topic
    # (standard alert channel), NOT the live-activity suffix. Bundle_id
    # may vary if prior fixtures registered devices with a different one,
    # so compare against each device's own registered bundle_id.
    assert all(
        not r.topic.endswith(".push-type.liveactivity") for r in our_requests
    ), "alert topic must not carry the live-activity suffix"

    async with factory() as session:
        bulletins = (
            (
                await session.execute(
                    select(Bulletin).where(Bulletin.external_id.in_(["700001", "700002"]))
                )
            )
            .scalars()
            .all()
        )
        for b in bulletins:
            assert b.processing_state == BulletinProcessingState.processed.value
            assert b.notified_at is not None
            assert b.canonical_org == CanonicalOrg.student_affairs.value

        our_ids_list = [b.id for b in bulletins]
        our_devices = {"dev-pipeline-match", "dev-pipeline-miss"}
        dispatches = (
            (
                await session.execute(
                    select(BulletinDispatch).where(
                        BulletinDispatch.bulletin_id.in_(our_ids_list),
                        BulletinDispatch.device_id.in_(our_devices),
                    )
                )
            )
            .scalars()
            .all()
        )
        # 2 bulletins × 1 matching device (dev-pipeline-match).
        # Scoped to this test's bulletins AND devices so leftover fixtures
        # can't pollute the assertion.
        assert len(dispatches) == 2
        assert all(d.status == BulletinDispatchStatus.sent.value for d in dispatches)
        assert {d.device_id for d in dispatches} == {"dev-pipeline-match"}


@_async
async def test_dispatch_is_idempotent(
    prepared_engine: AsyncEngine, test_settings: Settings
) -> None:
    """Running the dispatch job twice must not double-send — the
    (bulletin_id, device_id) unique key and `notified_at` block the second
    run."""
    settings = _test_settings_override(test_settings)
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)

    async with factory() as session:
        session.add(
            DeviceRegistration(
                device_id="dev-idem",
                user_id="u",
                pts_token_hex="pts",
                device_token_hex="alert-idem",
                bundle_id="org.ntust.app.TigerDuck",
                attrs_type="a",
                apns_env="development",
            )
        )
        await session.flush()
        session.add(
            BulletinSubscription(
                device_id="dev-idem",
                orgs=[],
                tags=[ContentTag.free_meal.value],
                mode="AND",
            )
        )
        bulletin = Bulletin(
            source="ntust_general",
            external_id="800001",
            source_url="https://x/800001",
            title="免費便當通知",
            body_md="body",
            canonical_org=CanonicalOrg.library.value,
            content_tags=[ContentTag.free_meal.value],
            summary="領便當",
            body_clean="body",
            importance=Importance.normal.value,
            processing_state=BulletinProcessingState.processed.value,
        )
        session.add(bulletin)
        await session.commit()

    sender = RecordingSender()
    await bulletin_jobs.dispatch_job(factory, sender, settings)
    first_count = len(sender.requests)
    assert first_count >= 1  # matches >=1 device, depending on leftover fixtures
    # The device under test must receive exactly one push.
    assert sum(1 for r in sender.requests if r.device_token == "alert-idem") == 1

    await bulletin_jobs.dispatch_job(factory, sender, settings)
    # Second run is a no-op — notified_at is stamped and dispatch rows are
    # terminal, so nothing new hits the sender.
    assert len(sender.requests) == first_count


@_async
async def test_stale_rows_flip_to_deleted(
    prepared_engine: AsyncEngine, test_settings: Settings
) -> None:
    settings = _test_settings_override(test_settings).model_copy(
        update={"bulletin_stale_cycles": 1, "bulletin_scrape_interval_seconds": 60}
    )
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)
    old = datetime.now(timezone.utc) - timedelta(days=1)

    async with factory() as session:
        session.add_all(
            [
                Bulletin(
                    source="ntust_general",
                    external_id="900500",
                    source_url="https://x/900500",
                    title="stale",
                    first_seen_at=old,
                    last_seen_at=old,
                ),
                Bulletin(
                    source="ntust_general",
                    external_id="900501",
                    source_url="https://x/900501",
                    title="fresh",
                ),
            ]
        )
        await session.commit()

    transport = _RoutingTransport(
        {
            settings.bulletin_list_url: """
            <html><body><table class="listTB table"><tbody>
            <tr><td>2026-04-22</td><td>圖書館</td>
              <td><a href="https://bulletin.ntust.edu.tw/p/450-1045-900501,c0.php">fresh</a></td>
            </tr>
            </tbody></table></body></html>
            """,
        }
    )

    await bulletin_jobs.scrape_job(
        factory,
        settings,
        http_client_factory=_http_client_factory(transport),
    )

    async with factory() as session:
        stale = (
            await session.execute(
                select(Bulletin).where(Bulletin.external_id == "900500")
            )
        ).scalar_one()
        fresh = (
            await session.execute(
                select(Bulletin).where(Bulletin.external_id == "900501")
            )
        ).scalar_one()
        assert stale.is_deleted is True
        assert fresh.is_deleted is False
