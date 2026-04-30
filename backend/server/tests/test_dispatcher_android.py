"""End-to-end check that the bulletin dispatcher fans out to android
devices via the FCM channel rather than the APNs one.

Uses the recording stubs on both sides so no network I/O happens; the
assertion pins (a) the dispatch row reaching `sent`, (b) the FCM
recording sender seeing the device's `pts_token_hex` (Android stores
the FCM registration token there), and (c) the APNs recording sender
staying empty so we never accidentally cross channels.
"""

from __future__ import annotations

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker

from server.bulletins import jobs as bulletin_jobs
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
from server.models import DevicePlatform, DeviceRegistration
from server.push.apns_client import RecordingSender
from server.push.fcm_client import RecordingFcmSender
from server.push.router import PushRouter

_async = pytest.mark.asyncio(loop_scope="session")


@_async
async def test_android_device_receives_fcm_push(
    prepared_engine: AsyncEngine, test_settings: Settings
) -> None:
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)

    async with factory() as session:
        session.add(
            DeviceRegistration(
                device_id="dev-android-1",
                user_id="u-android",
                platform=DevicePlatform.android.value,
                # Android stores the FCM registration token in the same
                # `pts_token_hex` column the iOS PTS token lives in — the
                # column is platform-overloaded by design.
                pts_token_hex="fcm-token-android",
                device_token_hex=None,
                bundle_id="org.ntust.app.tigerduck",
                # Empty strings are how the device-register route persists
                # the apple-only fields for android rows.
                attrs_type="",
                apns_env="",
            )
        )
        await session.flush()
        session.add(
            BulletinSubscription(
                device_id="dev-android-1",
                name="library-watch",
                orgs=[CanonicalOrg.library.value],
                tags=[],
                mode=SubscriptionMode.AND.value,
            )
        )
        bulletin = Bulletin(
            source="ntust_general",
            external_id="900100",
            source_url="https://x/900100",
            title="圖書館公告",
            title_clean="圖書館公告",
            body_md="body",
            body_clean="body",
            canonical_org=CanonicalOrg.library.value,
            content_tags=[],
            summary="圖書館今日延後開放",
            importance=Importance.normal.value,
            processing_state=BulletinProcessingState.processed.value,
        )
        session.add(bulletin)
        await session.commit()
        bulletin_id = bulletin.id

    apple = RecordingSender()
    android = RecordingFcmSender()
    router = PushRouter(apple=apple, android=android)

    await bulletin_jobs.dispatch_job(factory, router, test_settings)

    # FCM channel saw exactly our android device's token.
    our_fcm = [r for r in android.requests if r.data.get("bulletin_id") == str(bulletin_id)]
    assert len(our_fcm) == 1
    sent = our_fcm[0]
    assert sent.token == "fcm-token-android"
    assert sent.title == "圖書館公告"
    assert sent.data["canonical_org"] == CanonicalOrg.library.value
    assert sent.data["source_url"] == "https://x/900100"

    # APNs channel must not have been called for the android device.
    assert all(
        r.message.get("bulletin_id") != bulletin_id for r in apple.requests
    )

    async with factory() as session:
        dispatch = (
            await session.execute(
                select(BulletinDispatch).where(
                    BulletinDispatch.bulletin_id == bulletin_id,
                    BulletinDispatch.device_id == "dev-android-1",
                )
            )
        ).scalar_one()
        assert dispatch.status == BulletinDispatchStatus.sent.value
        assert dispatch.last_error is None


@_async
async def test_android_device_without_token_is_cancelled(
    prepared_engine: AsyncEngine, test_settings: Settings
) -> None:
    """An android row that somehow lost its FCM token cancels the dispatch
    rather than retrying forever."""
    factory = async_sessionmaker(prepared_engine, expire_on_commit=False)

    async with factory() as session:
        session.add(
            DeviceRegistration(
                device_id="dev-android-empty",
                user_id="u-empty",
                platform=DevicePlatform.android.value,
                # Empty token must not be allowed by the schema constraint
                # (min_length=1 at the API layer), but the model column
                # tolerates "" — exercise that defensive path.
                pts_token_hex="",
                device_token_hex=None,
                bundle_id="org.ntust.app.tigerduck",
                attrs_type="",
                apns_env="",
            )
        )
        await session.flush()
        session.add(
            BulletinSubscription(
                device_id="dev-android-empty",
                name="any-scholarship",
                orgs=[],
                tags=[ContentTag.scholarship.value],
                mode=SubscriptionMode.AND.value,
            )
        )
        bulletin = Bulletin(
            source="ntust_general",
            external_id="900200",
            source_url="https://x/900200",
            title="獎學金通知",
            title_clean="獎學金通知",
            body_md="body",
            body_clean="body",
            canonical_org=CanonicalOrg.student_affairs.value,
            content_tags=[ContentTag.scholarship.value],
            summary="新獎學金",
            importance=Importance.normal.value,
            processing_state=BulletinProcessingState.processed.value,
        )
        session.add(bulletin)
        await session.commit()
        bulletin_id = bulletin.id

    android = RecordingFcmSender()
    router = PushRouter(apple=RecordingSender(), android=android)

    await bulletin_jobs.dispatch_job(factory, router, test_settings)

    assert android.requests == []

    async with factory() as session:
        dispatch = (
            await session.execute(
                select(BulletinDispatch).where(
                    BulletinDispatch.bulletin_id == bulletin_id,
                    BulletinDispatch.device_id == "dev-android-empty",
                )
            )
        ).scalar_one()
        assert dispatch.status == BulletinDispatchStatus.cancelled.value
        assert "android" in (dispatch.last_error or "").lower()
