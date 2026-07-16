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
    relay: str
    laptop_pubkey: str
    pairing_id: str
    expires_at: int
    secret: str

    @property
    def relay_url(self) -> str:
        return self.relay

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), sort_keys=True, separators=(",", ":"))

    def to_dict(self) -> dict[str, object]:
        return asdict(self)

    @classmethod
    def from_json(cls, value: str) -> "PairingCode":
        payload = json.loads(value)
        relay = payload.get("relay", payload.get("relay_url"))
        if relay is None:
            raise KeyError("relay")
        return cls(
            version=int(payload["version"]),
            product=str(payload["product"]),
            relay=str(relay),
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
