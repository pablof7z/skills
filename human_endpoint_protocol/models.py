"""Protocol value objects."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass


PAIRING_VERSION = 1
PAIRING_REQUEST_KIND = 30390
GROUP_MESSAGE_KIND = 9


@dataclass
class PairingCode:
    version: int
    product: str
    relay_url: str
    laptop_pubkey: str
    pairing_id: str
    expires_at: int
    secret: str

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True, separators=(",", ":"))

    @classmethod
    def from_json(cls, value: str) -> "PairingCode":
        payload = json.loads(value)
        return cls(
            version=int(payload["version"]),
            product=str(payload["product"]),
            relay_url=str(payload["relay_url"]),
            laptop_pubkey=str(payload["laptop_pubkey"]),
            pairing_id=str(payload["pairing_id"]),
            expires_at=int(payload["expires_at"]),
            secret=str(payload["secret"]),
        )


def group_for(product: str, pairing_id: str) -> dict[str, str]:
    return {
        "id": f"{product}:{pairing_id}",
        "kind": "nip29",
        "message_kind": str(GROUP_MESSAGE_KIND),
    }
