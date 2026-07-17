#!/usr/bin/env python3
"""BUD-02 and BUD-11 contracts for generated TTS uploads."""

from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_blossom import BlossomUploadError, upload_mp3


class FakeResponse:
    def __init__(self, value: dict[str, object]) -> None:
        self.payload = json.dumps(value).encode("utf-8")

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args) -> None:
        return None

    def read(self) -> bytes:
        return self.payload


class BlossomUploadTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-blossom-")
        self.path = Path(self.temporary.name) / "speech.mp3"
        self.path.write_bytes(b"test-mp3-audio")
        self.sha256 = hashlib.sha256(self.path.read_bytes()).hexdigest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def descriptor(self, **changes: object) -> dict[str, object]:
        value: dict[str, object] = {
            "url": f"https://cdn.primal.net/{self.sha256}.mp3",
            "sha256": self.sha256,
            "size": self.path.stat().st_size,
            "type": "audio/mpeg",
            "uploaded": 1784260000,
        }
        value.update(changes)
        return value

    def test_upload_is_hash_scoped_and_returns_no_local_path(self) -> None:
        captured = None

        def open_request(request, timeout):
            nonlocal captured
            captured = request
            self.assertEqual(timeout, 60.0)
            return FakeResponse(self.descriptor())

        with (
            patch.dict(os.environ, {"TTS_REMOTE_TRANSPORT": "file"}, clear=False),
            patch("tts_blossom.urlopen", side_effect=open_request),
        ):
            result = upload_mp3(self.path, nsec="nsec-test", server="https://blossom.primal.net")

        self.assertEqual(result["status"], "uploaded")
        self.assertEqual(result["url"], self.descriptor()["url"])
        self.assertNotIn("path", result)
        self.assertEqual(captured.full_url, "https://blossom.primal.net/upload")
        self.assertEqual(captured.method, "PUT")
        self.assertEqual(captured.data, self.path.read_bytes())
        self.assertEqual(captured.get_header("X-sha-256"), self.sha256)
        authorization = captured.get_header("Authorization")
        self.assertTrue(authorization.startswith("Nostr "))
        encoded = authorization.removeprefix("Nostr ")
        encoded += "=" * (-len(encoded) % 4)
        event = json.loads(base64.urlsafe_b64decode(encoded))
        self.assertEqual(event["kind"], 24242)
        self.assertIn(["t", "upload"], event["tags"])
        self.assertIn(["server", "blossom.primal.net"], event["tags"])
        self.assertIn(["x", self.sha256], event["tags"])
        self.assertTrue(any(tag[0] == "expiration" for tag in event["tags"]))

    def test_mismatched_descriptor_is_rejected(self) -> None:
        with (
            patch.dict(os.environ, {"TTS_REMOTE_TRANSPORT": "file"}, clear=False),
            patch(
                "tts_blossom.urlopen",
                return_value=FakeResponse(self.descriptor(sha256="0" * 64)),
            ),
        ):
            with self.assertRaisesRegex(BlossomUploadError, "hash does not match"):
                upload_mp3(self.path, nsec="nsec-test")


if __name__ == "__main__":
    unittest.main()
