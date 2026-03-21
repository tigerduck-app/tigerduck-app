### 這個檔案裡面是 API 的請求概念驗證
### 確認實作的可行性

import httpx
import logging

from bs4 import BeautifulSoup
from httpx import Timeout

SSO_ROOT = "https://ssoam2.ntust.edu.tw/"

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)
logging.getLogger("httpx").setLevel(logging.WARNING)


class NtustSso:
    __student_id: str
    __password: str

    _client: httpx.Client

    def __init__(self, student_id: str, password: str):
        self.__student_id = student_id.upper()
        self.__password = password
        self._client = httpx.Client(
            http2=True, follow_redirects=True, timeout=Timeout(10.0)
        )

    def login(self) -> bool:
        # cache_key = self._log_user
        # if cache_key in self._cookie_cache:
        #     cached_data = self._cookie_cache[cache_key]
        #     if isinstance(cached_data, str):
        #         logger.warning("Found old cache format, clearing it.")
        #         del self._cookie_cache[cache_key]
        #     elif isinstance(cached_data, dict):
        #         for name, value in cached_data.items():
        #             self.client.cookies.set(name, value)
        #         return True

        self._client.cookies.clear()
        try:
            r_init = self._client.get(SSO_ROOT)
            if "/Home/Index" in str(r_init.url):
                # self._update_cache(cache_key)
                return True

            soup_login = BeautifulSoup(r_init.text, "html.parser")
            form = soup_login.find("form", id="loginForm")
            if not form:
                return False

            payload = {}
            for input_tag in form.find_all("input"):
                name = input_tag.get("name")
                value = input_tag.get("value", "")
                if name:
                    payload[name] = value

            payload["Username"] = self.__student_id
            payload["Password"] = self.__password
            if "captcha" not in payload:
                payload["captcha"] = ""

            r_login = self._client.post(SSO_ROOT, data=payload)

            soup_oidc = BeautifulSoup(r_login.text, "html.parser")
            if not (oidc_form := soup_oidc.find("form")):
                return False

            if not (oidc_action := oidc_form.get("action")):
                return False

            oidc_data = {}
            for input_tag in oidc_form.find_all("input"):
                name = input_tag.get("name")
                value = input_tag.get("value", "")
                if name:
                    oidc_data[name] = value

            r_oidc_finish = self._client.post(oidc_action, data=oidc_data)
            r_oidc_finish.status_code
            success = "StuScoreQueryServ" in self._client.cookies
            if success:
                self._update_cache(cache_key)
            return success

        except Exception:
            return False
