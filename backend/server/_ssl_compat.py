"""Relax Python 3.13 / OpenSSL 3 strict X.509 parsing.

Debian bookworm's OpenSSL 3 (and subsequently the Python built on top)
enables ``VERIFY_X509_STRICT`` on every context returned by
``ssl.create_default_context``. That flag enforces RFC 5280 extensions
that older certs often omit — including the "Subject Key Identifier" in
one of the intermediates of ``bulletin.ntust.edu.tw``'s chain.
macOS/curl tolerate the same chain without issue.

We don't want to drop CA verification — we still want a signed chain
that terminates in a trusted root. We only want to skip the structural
extension checks. That's exactly what clearing ``VERIFY_X509_STRICT``
from the default context does.

Importing this module anywhere at process start (before any httpx /
aiohttp / requests client is constructed) patches the factory globally.
Idempotent — calling ``apply`` twice leaves a single layer of patching.
"""

from __future__ import annotations

import ssl

_ORIGINAL_FACTORY = ssl.create_default_context
_PATCHED_FLAG = "__tigerduck_strict_relaxed__"


def _relaxed_default_context(*args: object, **kwargs: object) -> ssl.SSLContext:
    ctx = _ORIGINAL_FACTORY(*args, **kwargs)  # type: ignore[arg-type]
    ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT
    return ctx


def apply() -> None:
    """Install the patched factory if it isn't already installed."""
    if getattr(ssl.create_default_context, _PATCHED_FLAG, False):
        return
    setattr(_relaxed_default_context, _PATCHED_FLAG, True)
    ssl.create_default_context = _relaxed_default_context  # type: ignore[assignment]


apply()
