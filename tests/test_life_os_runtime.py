import importlib.util
import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest import mock


RUNTIME_ROOT = Path(__file__).resolve().parents[1] / "plugins" / "personal" / "runtime"
import sys

sys.path.insert(0, str(RUNTIME_ROOT))

from lifeos.runtime import LifeOS  # noqa: E402


class LifeOSRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / "state"
        self.vault = self.root / "vault"
        (self.vault / ".obsidian").mkdir(parents=True)
        self.runtime = LifeOS(home=self.home)
        self.runtime.initialize()
        config = self.runtime.config
        config["vault"]["path"] = str(self.vault)
        self.runtime.config_path.write_text(json.dumps(config), encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def test_initialize_creates_private_state_and_schema(self):
        result = self.runtime.initialize()
        self.assertEqual(result["status"], "ready")
        self.assertTrue(self.runtime.db_path.is_file())
        self.assertEqual(self.home.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.runtime.db_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.runtime.policy_path.stat().st_mode & 0o777, 0o600)
        connection = sqlite3.connect(self.runtime.db_path)
        try:
            tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        finally:
            connection.close()
        self.assertTrue({"events", "commitments", "actions", "drafts", "decisions", "review_runs"}.issubset(tables))

    def test_events_are_idempotent_and_do_not_store_raw_content(self):
        first = self.runtime.store.record_event(
            {
                "source": "imessage",
                "source_id": "message-1",
                "event_type": "message.received",
                "content": "private raw message",
                "payload": {"chat_id": "7"},
            }
        )
        second = self.runtime.store.record_event(
            {
                "source": "imessage",
                "source_id": "message-1",
                "event_type": "message.received",
                "content": "private raw message",
                "payload": {"chat_id": "7"},
            }
        )
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(len(self.runtime.store.list_events()), 1)
        database_bytes = self.runtime.db_path.read_bytes()
        self.assertNotIn(b"private raw message", database_bytes)
        self.assertIsNotNone(first["content_hash"])

    def test_commitment_confidence_and_idempotency(self):
        candidate = self.runtime.store.upsert_commitment(
            {
                "direction": "by_me",
                "source": "gmail",
                "source_id": "thread-1",
                "obligation": "Send the document",
                "confidence": 0.70,
            }
        )
        self.assertEqual(candidate["status"], "candidate")
        opened = self.runtime.store.upsert_commitment(
            {
                "direction": "by_me",
                "source": "gmail",
                "source_id": "thread-1",
                "obligation": "Send the document",
                "confidence": 0.93,
            }
        )
        self.assertEqual(opened["id"], candidate["id"])
        self.assertEqual(opened["status"], "open")

    def test_policy_enforces_confirmation_and_prohibitions(self):
        self.assertEqual(self.runtime.policy_decision("imessage.send")["decision"], "confirm")
        self.assertEqual(self.runtime.policy_decision("ticktick.create_task")["decision"], "confirm")
        self.assertEqual(self.runtime.policy_decision("financial.transaction")["decision"], "never")
        self.assertEqual(
            self.runtime.policy_decision("ticktick.create_followup", confidence=0.90)["decision"],
            "automatic",
        )
        self.assertEqual(
            self.runtime.policy_decision("ticktick.create_followup", confidence=0.70)["decision"],
            "confirm",
        )

    def test_initialize_adds_new_policy_rules_without_replacing_custom_values(self):
        policy = self.runtime.policy
        policy["actions"]["confirm"].remove("ticktick.create_task")
        policy["thresholds"]["automatic_followup_confidence"] = 0.91
        self.runtime.policy_path.write_text(json.dumps(policy), encoding="utf-8")

        self.runtime.initialize()

        migrated = json.loads(self.runtime.policy_path.read_text(encoding="utf-8"))
        self.assertIn("ticktick.create_task", migrated["actions"]["confirm"])
        self.assertEqual(migrated["thresholds"]["automatic_followup_confidence"], 0.91)

    def test_action_log_is_idempotent_and_denied_actions_cannot_be_confirmed(self):
        request = {"to": "+15555550123", "text": "hello"}
        first = self.runtime.request_action(
            "imessage.send",
            target=request["to"],
            request=request,
            idempotency_key="same-message",
        )
        second = self.runtime.request_action(
            "imessage.send",
            target=request["to"],
            request=request,
            idempotency_key="same-message",
        )
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(first["status"], "proposed")
        confirmed = self.runtime.store.confirm_action(first["id"])
        self.assertEqual(confirmed["status"], "confirmed")

        denied = self.runtime.request_action(
            "financial.transaction",
            target="bank",
            request={"amount": 1},
            idempotency_key="denied-action",
        )
        self.assertEqual(denied["status"], "denied")
        with self.assertRaises(PermissionError):
            self.runtime.store.confirm_action(denied["id"])

        with self.assertRaises(PermissionError):
            self.runtime.store.finish_action(first["id"], status="undone")

    def test_action_state_cannot_be_downgraded_after_execution(self):
        action = self.runtime.request_action(
            "ticktick.create_followup",
            target="AI Follow-ups",
            request={"title": "One task"},
            confidence=0.95,
            idempotency_key="executed-action",
        )
        executed = self.runtime.store.finish_action(action["id"], status="executed")
        self.assertEqual(executed["status"], "executed")
        with self.assertRaises(PermissionError):
            self.runtime.store.confirm_action(action["id"])

    def test_imessage_send_forces_imessage_without_sms_fallback(self):
        action = self.runtime.request_action(
            "imessage.send",
            target="+15555550123",
            request={"to": "+15555550123", "text": "hello"},
            idempotency_key="imessage-channel-boundary",
        )
        response = {"command": "imsg", "returncode": 0, "stdout": "{}", "stderr": ""}
        with mock.patch.object(self.runtime, "_run", return_value=response) as run:
            result = self.runtime.execute_imessage_send(action["id"], confirmed=True)
        command = run.call_args.args[0]
        self.assertEqual(result["status"], "executed")
        self.assertIn("--service", command)
        self.assertEqual(command[command.index("--service") + 1], "imessage")
        self.assertIn("--no-sms-fallback", command)

    def test_confirmed_ticktick_task_executes_once_with_audited_result(self):
        action = self.runtime.request_action(
            "ticktick.create_task",
            target="project-1",
            request={
                "title": "Prepare tomorrow",
                "project": "project-1",
                "due_date": "2026-08-12T17:00:00-07:00",
                "priority": 5,
                "time_zone": "America/Los_Angeles",
            },
            idempotency_key="ticktick-task-canary",
        )
        response = {
            "command": "ticktick",
            "returncode": 0,
            "stdout": json.dumps({"id": "task-1", "projectId": "project-1"}),
            "stderr": "",
        }
        with mock.patch("lifeos.runtime.shutil.which", return_value="/usr/local/bin/ticktick"), mock.patch.object(
            self.runtime, "_run", return_value=response
        ) as run:
            result = self.runtime.execute_ticktick_create(action["id"], confirmed=True)
            replay = self.runtime.execute_ticktick_create(action["id"], confirmed=True)
        command = run.call_args.args[0]
        self.assertEqual(result["status"], "executed")
        self.assertEqual(replay["id"], result["id"])
        self.assertEqual(run.call_count, 1)
        self.assertIn("--due-date", command)
        self.assertIn("--priority", command)
        self.assertEqual(result["undo"]["task_id"], "task-1")

    def test_keychain_secret_is_passed_on_stdin_not_process_arguments(self):
        response = {"command": "security", "returncode": 0, "stdout": "", "stderr": ""}
        with mock.patch("lifeos.runtime.shutil.which", return_value="/usr/bin/security"), mock.patch.object(
            self.runtime, "_run", return_value=response
        ) as run:
            self.runtime._keychain_set("test", "private-value")
        command = run.call_args.args[0]
        self.assertNotIn("private-value", command)
        self.assertEqual(run.call_args.kwargs["input_text"], "private-value\nprivate-value\n")

    def test_obsidian_write_is_limited_to_designated_roots(self):
        result = self.runtime.write_obsidian_note(
            "Personal/Reviews/Weekly/2026-W33.md", "# Review\n"
        )
        self.assertEqual(result["status"], "created")
        self.assertTrue(Path(result["path"]).is_file())
        unchanged = self.runtime.write_obsidian_note(
            "Personal/Reviews/Weekly/2026-W33.md", "# Review\n"
        )
        self.assertEqual(unchanged["status"], "unchanged")
        with self.assertRaises(PermissionError):
            self.runtime.write_obsidian_note(
                "Personal/Reviews/Weekly/2026-W33.md", "# Changed\n", overwrite=True
            )
        updated = self.runtime.write_obsidian_note(
            "Personal/Reviews/Weekly/2026-W33.md",
            "# Changed\n",
            overwrite=True,
            confirmed=True,
        )
        self.assertEqual(updated["status"], "updated")
        self.assertEqual(updated["action"]["status"], "executed")
        with self.assertRaises(PermissionError):
            self.runtime.write_obsidian_note("PUMPD/Plans/Nope.md", "no")
        with self.assertRaises(Exception):
            self.runtime.write_obsidian_note("../outside.md", "no")
        with self.assertRaises(Exception):
            self.runtime.write_obsidian_note(str(self.vault / "Personal/Reviews/absolute.md"), "no")
        with self.assertRaises(Exception):
            self.runtime.write_obsidian_note("Personal/Reviews/not-markdown.txt", "no")

    def test_health_ingest_normalizes_records(self):
        export = self.root / "health.json"
        export.write_text(
            json.dumps(
                {
                    "metrics": {
                        "steps": [
                            {"date": "2026-08-10T12:00:00Z", "value": 8123, "unit": "count"}
                        ],
                        "heart_rate_variability": [
                            {"date": "2026-08-10T08:00:00Z", "value": 42, "unit": "ms"}
                        ],
                    }
                }
            ),
            encoding="utf-8",
        )
        result = self.runtime.ingest_health_file(export)
        self.assertEqual(result["records_written"], 2)
        events = self.runtime.store.list_events(source="apple_health")
        self.assertEqual({event["event_type"] for event in events}, {"step_count", "heart_rate_variability_sdnn"})
        self.assertTrue(all(event["sensitivity"] == "health" for event in events))

    def test_health_auto_export_v2_is_allowlisted_and_idempotent(self):
        export = self.root / "health-v2.json"
        export.write_text(
            json.dumps(
                {
                    "data": {
                        "metrics": [
                            {
                                "name": "step_count",
                                "units": "count",
                                "data": [{"date": "2026-08-10 00:00:00 -0700", "qty": 8123}],
                            },
                            {
                                "name": "blood_glucose",
                                "units": "mg/dL",
                                "data": [{"date": "2026-08-10 08:00:00 -0700", "qty": 95}],
                            },
                        ],
                        "workouts": [
                            {
                                "id": "workout-1",
                                "name": "Strength Training",
                                "start": "2026-08-10 09:00:00 -0700",
                                "end": "2026-08-10 10:00:00 -0700",
                                "duration": 3600,
                            }
                        ],
                    }
                }
            ),
            encoding="utf-8",
        )
        result = self.runtime.ingest_health_file(export)
        self.assertEqual(result["records_seen"], 3)
        self.assertEqual(result["records_written"], 2)
        self.assertEqual(result["records_filtered"], 1)
        self.assertEqual(result["metrics"], ["step_count", "workout"])

        export.write_text(
            json.dumps(
                {
                    "data": {
                        "metrics": [
                            {
                                "name": "step_count",
                                "units": "count",
                                "data": [{"date": "2026-08-10 00:00:00 -0700", "qty": 9000}],
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        self.runtime.ingest_health_file(export)
        events = self.runtime.store.list_events(source="apple_health")
        self.assertEqual(len(events), 2)
        steps = next(event for event in events if event["event_type"] == "step_count")
        self.assertEqual(steps["payload"]["qty"], 9000)
        self.assertNotIn("blood_glucose", {event["event_type"] for event in events})

    def test_health_scan_reads_configured_inbox_without_duplicates(self):
        inbox = self.root / "icloud" / "AutoExport" / "Life OS Health"
        inbox.mkdir(parents=True)
        export = inbox / "2026-08-10.json"
        export.write_text(
            json.dumps(
                {
                    "data": {
                        "metrics": [
                            {
                                "name": "resting_heart_rate",
                                "units": "bpm",
                                "data": [{"date": "2026-08-10 08:00:00 -0700", "qty": 52}],
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        first = self.runtime.scan_health_inboxes(paths=[inbox])
        second = self.runtime.scan_health_inboxes(paths=[inbox])
        self.assertEqual(first["status"], "ready")
        self.assertEqual(first["files_ingested"], 1)
        self.assertEqual(second["files_ingested"], 1)
        self.assertEqual(len(self.runtime.store.list_events(source="apple_health")), 1)

    def test_decisions_and_drafts_are_idempotent(self):
        first = self.runtime.store.record_decision(
            {
                "title": "Use Codex",
                "decision": "Use Codex as the front door",
                "decided_at": "2026-08-11T10:00:00-07:00",
                "source_ref": "obsidian:life-os",
                "expected_outcome": "Fewer duplicated services",
            }
        )
        second = self.runtime.store.record_decision(
            {
                "title": "Use Codex",
                "decision": "Use Codex as the front door",
                "decided_at": "2026-08-11T10:00:00-07:00",
                "source_ref": "obsidian:life-os",
                "expected_outcome": "Fewer duplicated services",
            }
        )
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(len(self.runtime.store.list_decisions()), 1)

        draft = {
            "channel": "imessage",
            "source_thread_id": "thread-1",
            "recipient": "+15555550123",
            "body": "Sounds good.",
            "voice_mode": "imessage",
        }
        first_draft = self.runtime.store.save_draft(draft)
        second_draft = self.runtime.store.save_draft(draft)
        self.assertEqual(first_draft["id"], second_draft["id"])
        self.assertEqual(len(self.runtime.store.list_drafts()), 1)

    def test_reviews_are_idempotent_and_queryable(self):
        review = {
            "review_type": "weekly",
            "period_start": "2026-08-03",
            "period_end": "2026-08-09",
            "note_ref": "Personal/Reviews/Weekly/2026-W32.md",
            "summary": "A bounded review",
        }
        first = self.runtime.store.record_review(review)
        second = self.runtime.store.record_review(review)
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(len(self.runtime.store.list_reviews(review_type="weekly")), 1)

    def test_imessage_reader_stores_metadata_not_bodies(self):
        responses = [
            {
                "command": "imsg",
                "returncode": 0,
                "stdout": json.dumps({"id": 7, "display_name": "Person"}),
                "stderr": "",
            },
            {
                "command": "imsg",
                "returncode": 0,
                "stdout": json.dumps(
                    {
                        "id": 9,
                        "guid": "abc",
                        "date": "2026-08-10T10:00:00Z",
                        "text": "Can you send that tomorrow?",
                        "is_from_me": False,
                        "sender": "+15555550123",
                    }
                ),
                "stderr": "",
            },
        ]
        with mock.patch("lifeos.runtime.shutil.which", return_value="/opt/homebrew/bin/imsg"), mock.patch.object(
            self.runtime, "_run", side_effect=responses
        ):
            result = self.runtime.imessage_recent(chat_limit=1, message_limit=1)
        self.assertEqual(len(result["chats"]), 1)
        self.assertEqual(len(self.runtime.store.list_events(source="imessage")), 1)
        self.assertNotIn(b"Can you send that tomorrow?", self.runtime.db_path.read_bytes())

    def test_oura_auth_url_persists_nonce_not_secret(self):
        result = self.runtime.oura_auth_url(client_id="client-id")
        self.assertIn("https://cloud.ouraring.com/oauth/authorize?", result["authorization_url"])
        state = json.loads((self.home / "oura-oauth-state.json").read_text(encoding="utf-8"))
        self.assertEqual(state["client_id"], "client-id")
        self.assertNotIn("secret", state)

    def test_oura_sync_reads_configured_daily_endpoints_and_checkpoints(self):
        config = self.runtime.config
        config["oura"]["client_id"] = "client-id"
        config["oura"]["endpoints"] = ["daily_sleep", "daily_readiness"]
        self.runtime.config_path.write_text(json.dumps(config), encoding="utf-8")

        def response(payload):
            context = mock.MagicMock()
            context.__enter__.return_value.read.return_value = json.dumps(payload).encode("utf-8")
            return context

        responses = [
            response({"data": [{"id": "sleep-1", "day": "2026-08-10", "score": 82}]}),
            response({"data": [{"id": "ready-1", "day": "2026-08-10", "score": 76}]}),
        ]
        with mock.patch.object(self.runtime, "_keychain_get", return_value="access-token"), mock.patch(
            "lifeos.runtime.urllib.request.urlopen", side_effect=responses
        ) as urlopen:
            result = self.runtime.oura_sync(start_date="2026-08-10", end_date="2026-08-10")

        self.assertEqual(result["records_written"], 2)
        self.assertEqual(urlopen.call_count, 2)
        events = self.runtime.store.list_events(source="oura")
        self.assertEqual({event["event_type"] for event in events}, {"daily_sleep", "daily_readiness"})
        self.assertTrue(all(event["sensitivity"] == "health" for event in events))
        checkpoint = self.runtime.store.get_checkpoint("oura")
        self.assertEqual(checkpoint["cursor"], "2026-08-10")

    def test_oura_interactive_authorization_rejects_non_loopback_redirect(self):
        config = self.runtime.config
        config["oura"]["redirect_uri"] = "https://example.com/callback"
        self.runtime.config_path.write_text(json.dumps(config), encoding="utf-8")
        with self.assertRaises(Exception):
            self.runtime.oura_authorize(
                client_id="client-id",
                client_secret="secret",
                timeout_seconds=1,
            )


if __name__ == "__main__":
    unittest.main()
