#!/usr/bin/env python3
"""Shared HTTP fixtures for TTS command integration tests."""

from __future__ import annotations

import base64
from http.server import BaseHTTPRequestHandler
import json
import threading


class KokoroHandler(BaseHTTPRequestHandler):
    received_inputs: list[str] = []
    received_voices: list[str] = []
    received_inputs_lock = threading.Lock()

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        with self.received_inputs_lock:
            self.received_inputs.append(request["input"])
            self.received_voices.append(request["voice"])
        payload = json.dumps(
            {
                "audio": base64.b64encode(b"test-mp3-audio").decode("ascii"),
                "timestamps": [{"word": "Test", "start_time": 0.0, "end_time": 0.2}],
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:
        pass


class BlockingKokoroHandler(KokoroHandler):
    request_started = threading.Event()
    release_response = threading.Event()

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self.request_started.set()
        self.release_response.wait(timeout=5)
        super().do_POST()


class BlockingAttachmentKokoroHandler(KokoroHandler):
    request_count = 0
    request_count_lock = threading.Lock()
    attachment_request_started = threading.Event()
    release_attachment_response = threading.Event()

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        with self.request_count_lock:
            type(self).request_count += 1
            request_number = type(self).request_count
        if request_number == 2:
            self.attachment_request_started.set()
            self.release_attachment_response.wait(timeout=5)
        super().do_POST()


class FailingKokoroHandler(KokoroHandler):
    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self.send_response(500)
        self.send_header("Content-Length", "0")
        self.end_headers()
