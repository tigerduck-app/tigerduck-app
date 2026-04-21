"""TigerDuck push notification server.

Runs on the Mac mini behind nginx-proxy-manager + Cloudflare, serves the iOS app
at https://api.tigerduck.app/v1/. Separate from backend/api/ which is POC-only.
"""

from server import config

__all__ = ["config"]
