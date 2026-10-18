"""Apple Push Notification service client (token-based auth, HTTP/2)."""

import logging
import os
import time
from dataclasses import dataclass

import httpx
import jwt

log = logging.getLogger(__name__)

HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}
TOKEN_TTL = 45 * 60  # Apple rejects tokens older than an hour and throttles refreshes under 20 min
# Device tokens that will never work again and should be forgotten.
DEAD_TOKEN_REASONS = {"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"}


@dataclass
class SendResult:
    ok: bool
    reason: str | None = None

    @property
    def token_dead(self) -> bool:
        return self.reason in DEAD_TOKEN_REASONS


class Apns:
    def __init__(self, key_id: str, team_id: str, private_key: str, topic: str):
        self.key_id, self.team_id, self.private_key, self.topic = key_id, team_id, private_key, topic
        self._token: tuple[str, float] | None = None
        self._http = httpx.Client(http2=True, timeout=15)

    @classmethod
    def from_env(cls) -> "Apns | None":
        """Configured from APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY (the .p8 contents) and APNS_TOPIC."""
        key_id, team_id, key = os.environ.get("APNS_KEY_ID"), os.environ.get("APNS_TEAM_ID"), os.environ.get("APNS_KEY")
        if not (key_id and team_id and key):
            return None
        return cls(key_id, team_id, key.replace("\\n", "\n"), os.environ.get("APNS_TOPIC", "ca.akinyemi.bumpcast"))

    def _bearer(self) -> str:
        if self._token is None or time.time() - self._token[1] > TOKEN_TTL:
            issued = time.time()
            token = jwt.encode(
                {"iss": self.team_id, "iat": int(issued)},
                self.private_key,
                algorithm="ES256",
                headers={"kid": self.key_id},
            )
            self._token = (token, issued)
        return self._token[0]

    def send(self, device_token: str, environment: str, payload: dict, collapse_id: str | None = None) -> SendResult:
        headers = {
            "authorization": f"bearer {self._bearer()}",
            "apns-topic": self.topic,
            "apns-push-type": "alert",
            "apns-priority": "10",
        }
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id[:64]
        try:
            r = self._http.post(f"{HOSTS[environment]}/3/device/{device_token}", json=payload, headers=headers)
        except httpx.HTTPError as e:
            return SendResult(False, f"network: {e}")
        if r.status_code == 200:
            return SendResult(True)
        try:
            reason = r.json().get("reason", str(r.status_code))
        except ValueError:
            reason = str(r.status_code)
        log.warning("apns %s for %s…: %s", r.status_code, device_token[:8], reason)
        return SendResult(False, reason)
