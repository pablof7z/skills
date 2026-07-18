#!/usr/bin/env python3
"""Black-box tests for the standalone TTS29 skill adapter."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class AdapterCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts29-skill-")
        self.root = Path(self.temporary.name)
        self.capture = self.root / "capture.json"
        self.cli = self.root / "tts29"
        self.cli.write_text(
            """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

request = json.load(sys.stdin)
Path(os.environ["FAKE_CAPTURE"]).write_text(json.dumps({
    "arguments": sys.argv[1:],
    "request": request,
    "agent_nsec": os.environ.get("AGENT_NSEC"),
}))
if os.environ.get("FAKE_FAIL"):
    print("daemon request failed: connection refused", file=sys.stderr)
    raise SystemExit(1)
print(json.dumps({
    "status": "published",
    "version": 1,
    "request_id": request["request_id"],
    "receipt_id": 7,
    "event_id": "e" * 64,
    "answer_wait": {"status": "not_requested"},
}))
""",
            encoding="utf-8",
        )
        self.cli.chmod(0o755)
        repository = Path(__file__).resolve().parents[2]
        self.command = repository / "tts" / "scripts" / "tts"
        self.environment = os.environ | {
            "TTS29_CLI": str(self.cli),
            "TTS29_SOCKET": str(self.root / "daemon.sock"),
            "TTS29_GROUP_ID": "tts",
            "FAKE_CAPTURE": str(self.capture),
            "AGENT_NSEC": "test-agent-secret",
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def invoke(
        self,
        *extra: str,
        environment: dict[str, str] | None = None,
        message: str = "The build passed its checks.",
    ):
        return subprocess.run(
            [
                str(self.command),
                "--agent-name",
                "codex",
                "--subject",
                "Build Ready",
                "--summary",
                "The verified build is ready.",
                "--message",
                message,
                *extra,
            ],
            env=environment or self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def captured(self) -> dict:
        return json.loads(self.capture.read_text(encoding="utf-8"))

    def test_ordinary_update_is_one_stable_tts29_request(self) -> None:
        first = self.invoke()
        first_capture = self.captured()
        second = self.invoke()
        second_capture = self.captured()

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(json.loads(first.stdout)["status"], "published")
        self.assertEqual(first_capture["request"], second_capture["request"])
        self.assertEqual(first_capture["request"]["group_id"], "tts")
        self.assertEqual(first_capture["request"]["agent_name"], "codex")
        self.assertEqual(first_capture["request"]["attachments"], [])
        self.assertEqual(first_capture["request"]["questions"], [])
        self.assertRegex(first_capture["request"]["request_id"], r"^skill-[0-9a-f]{32}$")
        self.assertEqual(first_capture["agent_nsec"], "test-agent-secret")
        self.assertEqual(first_capture["arguments"][:2], ["--socket", str(self.root / "daemon.sock")])
        self.assertEqual(second.returncode, 0, second.stderr)

    def test_content_and_caller_owned_ids_have_deliberate_retry_semantics(self) -> None:
        self.invoke()
        first = self.captured()["request"]["request_id"]
        changed = self.invoke(message="The build passed a different set of checks.")
        changed_id = self.captured()["request"]["request_id"]
        explicit = self.invoke("--request-id", "caller-owned")

        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertNotEqual(first, changed_id)
        self.assertEqual(explicit.returncode, 0, explicit.stderr)
        self.assertEqual(self.captured()["request"]["request_id"], "caller-owned")

    def test_structured_questions_map_to_contract_and_bounded_wait(self) -> None:
        bundle = json.dumps(
            {
                "questions_preamble": "Two choices remain.",
                "questions": [
                    {
                        "short_title": "Rollout",
                        "title": "Which rollout should I use?",
                        "suggestions": [{"title": "Progressive", "description": "Start small."}],
                    },
                    {
                        "short_title": "Notes",
                        "title": "Anything else?",
                        "type": "freeform",
                    },
                ],
            }
        )
        result = self.invoke("--ask", bundle, "--wait", "5m")
        capture = self.captured()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(capture["arguments"][-2:], ["--wait-seconds", "300"])
        self.assertTrue(capture["request"]["body"].endswith("Two choices remain."))
        questions = capture["request"]["questions"]
        self.assertEqual([question["id"] for question in questions], ["q1", "q2"])
        self.assertEqual(questions[0]["options"][0]["id"], "q1-o1")
        self.assertEqual(questions[1]["kind"], "freeform")

    def test_bare_ask_without_suggestions_is_freeform(self) -> None:
        result = self.invoke("--ask", "--wait", "30s")

        self.assertEqual(result.returncode, 0, result.stderr)
        question = self.captured()["request"]["questions"][0]
        self.assertEqual(question["kind"], "freeform")
        self.assertEqual(question["options"], [])

    def test_complete_durable_artifact_is_forwarded(self) -> None:
        artifact = json.dumps(
            {
                "url": "https://cdn.example/design.pdf",
                "sha256": "a" * 64,
                "media_type": "application/pdf",
                "byte_count": 42,
                "label": "Design",
            }
        )
        result = self.invoke("--artifact", artifact)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.captured()["request"]["attachments"][0]["label"], "Design")

    def test_legacy_product_surfaces_fail_before_invoking_tts29(self) -> None:
        for arguments, phrase in [
            (("--no-play",), "generation-only playback control is retired"),
            (("--attach", "Design", "design.pdf"), "local attachment paths are retired"),
        ]:
            with self.subTest(arguments=arguments):
                self.capture.unlink(missing_ok=True)
                result = self.invoke(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertIn(phrase, result.stderr)
                self.assertFalse(self.capture.exists())

        paired = subprocess.run(
            [str(self.command), "pair", "status"],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(paired.returncode, 2)
        self.assertIn("legacy pair administration is retired", paired.stderr)

    def test_missing_configuration_and_daemon_failure_are_clear(self) -> None:
        missing = self.environment.copy()
        missing.pop("TTS29_GROUP_ID")
        result = self.invoke(environment=missing)
        self.assertEqual(result.returncode, 2)
        self.assertIn("TTS29_GROUP_ID is required", result.stderr)

        failing = self.environment | {"FAKE_FAIL": "1"}
        result = self.invoke(environment=failing)
        self.assertEqual(result.returncode, 1)
        self.assertIn("connection refused", result.stderr)

    def test_wait_beyond_daemon_bound_is_rejected_before_invocation(self) -> None:
        result = self.invoke("--ask", "--wait", "6m")

        self.assertEqual(result.returncode, 2)
        self.assertIn("between 1 second and 5 minutes", result.stderr)


if __name__ == "__main__":
    unittest.main()
