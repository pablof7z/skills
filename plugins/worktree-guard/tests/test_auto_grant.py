"""Tests that base access is granted only by an explicit request, never by a write."""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.cli import main  # noqa: E402
from worktreeguard.hooks import run_harness_hook  # noqa: E402
from worktreeguard.storage import (  # noqa: E402
    ApprovalOutcome, active_grants, load_state, read_requests, write_config,
)


class BaseAccessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-auto-grant-")
        root = Path(self.temporary.name).resolve()
        self.base = root / "repo"
        self.state = root / "state.json"
        self.notifications = root / "notifications.jsonl"
        self.denials = root / "denials.jsonl"
        self.requests = root / "requests.jsonl"
        run(["git", "init", "-q", "-b", "main", str(self.base)])
        run(["git", "config", "user.email", "probe@example.com"], cwd=self.base)
        run(["git", "config", "user.name", "Probe"], cwd=self.base)
        (self.base / "tracked.txt").write_text("test\n", encoding="utf-8")
        run(["git", "add", "tracked.txt"], cwd=self.base)
        run(["git", "commit", "-q", "-m", "initial"], cwd=self.base)
        self.environment = patch.dict(os.environ, {
            "WTG_STATE_FILE": str(self.state),
            "WTG_NOTIFICATION_LOG_FILE": str(self.notifications),
            "WTG_DENY_LOG_FILE": str(self.denials),
            "WTG_REQUEST_LOG_FILE": str(self.requests),
            "WTG_SESSION_ID": "session-one",
        })
        self.environment.start()

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    def test_prior_state_version_is_not_migrated(self) -> None:
        self.state.write_text(
            json.dumps({"version": 8, "grants": [
                {
                    "id": "session", "scope": "writes", "session_id": "s",
                },
                {
                    "id": "legacy", "scope": "session", "session_id": "s",
                },
                {"id": "unbound", "scope": "writes"},
            ]}),
            encoding="utf-8",
        )
        state = load_state()
        self.assertEqual(state, {"version": 9, "grants": []})

    def test_unrequested_base_edit_is_denied_when_writes_block(self) -> None:
        output = json.loads(hook_output("pre-tool-use", native_payload(self.base, "session-one")))
        self.assertEqual(set(output), {"hookSpecificOutput"})
        self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(len(read_jsonl(self.denials)), 1)
        self.assertEqual(active_grants(), [])
        self.assertFalse(self.notifications.exists())

    def test_writes_custom_message_is_the_complete_codex_denial_reason(self) -> None:
        write_config(self.base, {"writes": {"message": "Edit only in the linked worktree."}})
        output = json.loads(hook_output("pre-tool-use", native_payload(self.base, "session-one")))
        self.assertEqual(
            output["hookSpecificOutput"]["permissionDecisionReason"],
            "Edit only in the linked worktree.",
        )

    def test_harness_permission_events_are_not_wtg_business(self) -> None:
        self.assertEqual(hook_output("permission-request", native_payload(self.base, "s")), "")
        self.assertEqual(read_jsonl(self.denials), [])

    def test_grok_denial_does_not_mix_in_codex_fields(self) -> None:
        output = json.loads(hook_output(
            "pre-tool-use", native_payload(self.base, "session-one"), harness="grok"
        ))
        self.assertEqual(set(output), {"decision", "reason"})
        self.assertEqual(output["decision"], "deny")


    def test_warn_disposition_codex_emits_empty_stdout(self) -> None:
        # Regression: Codex rejects permissionDecision:"allow" with
        # "unsupported permissionDecision:allow". When disposition=warn the hook
        # must produce no stdout for Codex (empty = allow-through); warning on stderr.
        write_config(self.base, {"writes": {"disposition": "warn", "bypass": "auto"}})
        stderr_buf = io.StringIO()
        with redirect_stderr(stderr_buf):
            output = hook_output("pre-tool-use", native_payload(self.base, "session-one"))
        self.assertEqual(output, "")  # no JSON — Codex reads empty as allow
        self.assertIn("base directory", stderr_buf.getvalue())  # warning still surfaced

    def test_warn_disposition_claude_emits_allow_json(self) -> None:
        # Claude Code accepts permissionDecision:"allow" to surface the nudge in-context.
        write_config(self.base, {"writes": {"disposition": "warn", "bypass": "auto"}})
        output = json.loads(hook_output(
            "pre-tool-use", native_payload(self.base, "session-one"), harness="claude",
        ))
        self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "allow")

    def test_request_auto_grants_and_notifies_then_edits_pass(self) -> None:
        self.assertEqual(request_access(self.base, "user asked for a base edit", scope="writes"), 0)
        notices = read_jsonl(self.notifications)
        self.assertEqual(len(notices), 1)
        self.assertEqual(notices[0]["base_path"], str(self.base))
        self.assertIn("requested and was auto-granted", notices[0]["message"])
        self.assertEqual(len(active_grants()), 1)
        self.assertEqual(active_grants()[0]["scope"], "writes")
        self.assertEqual(active_grants()[0]["session_id"], "session-one")
        self.assertNotIn("expires_at", active_grants()[0])
        self.assertEqual(hook_output("pre-tool-use", native_payload(self.base, "session-one")), "")
        self.assertEqual(hook_output("pre-tool-use", native_payload(self.base, "session-one")), "")
        logged = read_requests()
        self.assertEqual(len(logged), 1)
        self.assertEqual(logged[0]["reason"], "user asked for a base edit")
        self.assertEqual(logged[0]["base_path"], str(self.base))
        self.assertEqual(logged[0]["session_id"], "session-one")
        self.assertEqual(logged[0]["outcome"], "approved")
        self.assertEqual(logged[0]["scope"], "writes")

    def test_an_auto_bypass_grant_covers_any_other_auto_bypass_group(self) -> None:
        # Both writes and discard default to bypass=auto: once a session has been
        # rubber-stamped for one, a second auto surface doesn't need its own ask —
        # the same "approved once per session" convenience the tool has always had
        # for its lenient tier. Precision lives in "manual"/"none", not here.
        self.assertEqual(request_access(self.base, "editing files", scope="writes"), 0)
        self.assertEqual(hook_output("pre-tool-use", git_payload(self.base, "session-one")), "")

    def test_a_manual_bypass_group_is_never_covered_by_a_differently_tagged_grant(self) -> None:
        write_config(self.base, {"discard": {"bypass": "manual"}})
        self.assertEqual(request_access(self.base, "editing files", scope="writes"), 0)
        output = json.loads(hook_output("pre-tool-use", git_payload(self.base, "session-one")))
        self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_a_discard_grant_unblocks_the_matching_git_command(self) -> None:
        self.assertEqual(request_access(self.base, "rebasing on purpose", scope="discard"), 0)
        self.assertEqual(hook_output("pre-tool-use", git_payload(self.base, "session-one")), "")

    def test_request_with_bypass_manual_prompts_and_can_be_denied(self) -> None:
        write_config(self.base, {"writes": {"bypass": "manual"}})
        with patch.dict(os.environ, {"WTG_APPROVAL_RESPONSE": "deny"}):
            self.assertEqual(request_access(self.base, "should be refused", scope="writes"), 1)
        self.assertEqual(active_grants(), [])
        self.assertFalse(self.notifications.exists())
        output = json.loads(hook_output("pre-tool-use", native_payload(self.base, "session-one")))
        self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "deny")
        logged = read_requests()
        self.assertEqual(len(logged), 1)
        self.assertEqual(logged[0]["reason"], "should be refused")
        self.assertEqual(logged[0]["outcome"], "rejected")

    @patch("worktreeguard.cli.request_human_approval", return_value=ApprovalOutcome.TIMED_OUT)
    def test_manual_timeout_reports_no_user_answer_after_default_300_seconds(self, approval) -> None:
        write_config(self.base, {"writes": {"bypass": "manual"}})
        stderr = io.StringIO()
        with redirect_stderr(stderr), redirect_stdout(io.StringIO()):
            code = main([
                "request-base-access", "--repo", str(self.base), "--scope", "writes",
                "--reason", "needs confirmation",
            ])
        self.assertEqual(code, 1)
        self.assertIn("No answer from the user within 300 seconds", stderr.getvalue())
        self.assertEqual(approval.call_args.kwargs["timeout"], 300)
        self.assertEqual(read_requests()[0]["outcome"], "timed_out")

    def test_timeout_must_be_positive(self) -> None:
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            main([
                "request-base-access", "--repo", str(self.base), "--scope", "writes",
                "--reason", "no indefinite waits", "--timeout", "0",
            ])

    def test_one_time_approval_response_is_rejected(self) -> None:
        write_config(self.base, {"writes": {"bypass": "manual"}})
        with patch.dict(os.environ, {"WTG_APPROVAL_RESPONSE": "once"}):
            self.assertEqual(request_access(self.base, "one command only", scope="writes"), 1)
        self.assertEqual(active_grants(), [])

    def test_removed_ttl_option_is_not_accepted(self) -> None:
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            main([
                "request-base-access", "--repo", str(self.base), "--scope", "writes",
                "--reason", "one command only", "--ttl-seconds", "1",
            ])

    def test_codex_thread_id_binds_request_when_override_is_absent(self) -> None:
        with patch.dict(os.environ, {
            "WTG_SESSION_ID": "", "CLAUDE_CODE_SESSION_ID": "", "CODEX_THREAD_ID": "codex-session",
        }):
            self.assertEqual(request_access(self.base, "codex base edit", scope="writes"), 0)
        self.assertEqual(active_grants()[0]["session_id"], "codex-session")

    def test_claude_code_session_id_binds_request_when_override_is_absent(self) -> None:
        with patch.dict(os.environ, {
            "WTG_SESSION_ID": "", "CLAUDE_CODE_SESSION_ID": "claude-session",
            "CODEX_THREAD_ID": "",
        }):
            self.assertEqual(request_access(self.base, "claude base edit", scope="writes"), 0)
        self.assertEqual(active_grants()[0]["session_id"], "claude-session")

    def test_request_without_harness_session_is_refused(self) -> None:
        with patch.dict(os.environ, {
            "WTG_SESSION_ID": "", "CLAUDE_CODE_SESSION_ID": "", "CODEX_THREAD_ID": "",
        }), redirect_stderr(io.StringIO()):
            self.assertEqual(request_access(self.base, "unbound edit", scope="writes"), 1)
        self.assertEqual(active_grants(), [])

    def test_requests_command_reports_logged_reasons(self) -> None:
        self.assertEqual(request_access(self.base, "auditable reason", scope="writes"), 0)
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(main(["requests", "--repo", str(self.base), "--json"]), 0)
        payload = json.loads(output.getvalue())
        self.assertEqual(payload["total"], 1)
        self.assertEqual(payload["tail"][0]["reason"], "auditable reason")

    def test_grant_does_not_leak_to_another_session(self) -> None:
        self.assertEqual(request_access(self.base, "scoped to session-one", scope="writes"), 0)
        output = json.loads(hook_output("pre-tool-use", native_payload(self.base, "session-two")))
        self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "deny")


def native_payload(base: Path, session_id: str) -> dict[str, object]:
    return {
        "cwd": str(base),
        "session_id": session_id,
        "tool_name": "Edit",
        "tool_input": {"file_path": str(base / "tracked.txt")},
    }


def git_payload(base: Path, session_id: str) -> dict[str, object]:
    return {
        "cwd": str(base),
        "session_id": session_id,
        "tool_name": "Bash",
        "tool_input": {"command": "git reset --hard"},
    }


def request_access(base: Path, reason: str, *, scope: str) -> int:
    with redirect_stdout(io.StringIO()):
        return main([
            "request-base-access", "--repo", str(base), "--scope", scope, "--reason", reason,
        ])


def hook_output(
    event: str, payload: dict[str, object], *, harness: str = "codex"
) -> str:
    output = io.StringIO()
    with redirect_stdout(output):
        run_harness_hook(event, payload, harness=harness)
    return output.getvalue().strip()


def read_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
