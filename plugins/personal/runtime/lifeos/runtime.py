from __future__ import annotations

import hashlib
import http.server
import json
import os
import plistlib
import secrets
import shutil
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

from .store import Store, stable_id, utcnow


class LifeOSError(RuntimeError):
    pass


class LifeOS:
    def __init__(self, home: Path | None = None):
        configured = os.environ.get("LIFE_OS_HOME")
        self.home = Path(configured).expanduser() if configured else (home or Path.home() / "Library" / "Application Support" / "LifeOS")
        self.home = self.home.expanduser().resolve()
        self.defaults_dir = Path(__file__).resolve().parent.parent / "defaults"
        self.config_path = self.home / "config.json"
        self.policy_path = self.home / "policy.json"
        self.voice_path = self.home / "voice-profile.md"
        self.soul_path = self.home / "SOUL.md"
        self.db_path = self.home / "life-os.sqlite3"
        self.health_inbox = self.home / "health-inbox"
        self.store = Store(self.db_path)

    def initialize(self) -> dict[str, Any]:
        self.home.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.home, 0o700)
        created: list[str] = []
        for source_name, target in (
            ("config.json", self.config_path),
            ("policy.json", self.policy_path),
            ("voice-profile.md", self.voice_path),
            ("SOUL.md", self.soul_path),
        ):
            if not target.exists():
                shutil.copyfile(self.defaults_dir / source_name, target)
                target.chmod(0o600)
                created.append(str(target))
        self._merge_config_defaults()
        self._merge_policy_defaults()
        self.health_inbox.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.store.initialize()
        return {
            "home": str(self.home),
            "database": str(self.db_path),
            "created": created,
            "status": "ready",
        }

    def _merge_config_defaults(self) -> None:
        defaults = json.loads((self.defaults_dir / "config.json").read_text(encoding="utf-8"))
        current = json.loads(self.config_path.read_text(encoding="utf-8"))

        def merge_missing(target: dict[str, Any], source: dict[str, Any]) -> bool:
            changed = False
            for key, value in source.items():
                if key not in target:
                    target[key] = value
                    changed = True
                elif isinstance(value, dict) and isinstance(target[key], dict):
                    changed = merge_missing(target[key], value) or changed
            return changed

        if merge_missing(current, defaults):
            self.config_path.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            self.config_path.chmod(0o600)

    def _merge_policy_defaults(self) -> None:
        defaults = json.loads((self.defaults_dir / "policy.json").read_text(encoding="utf-8"))
        current = json.loads(self.policy_path.read_text(encoding="utf-8"))
        changed = False

        actions = current.setdefault("actions", {})
        for decision, default_rules in defaults["actions"].items():
            current_rules = actions.setdefault(decision, [])
            for rule in default_rules:
                if rule not in current_rules:
                    current_rules.append(rule)
                    changed = True

        thresholds = current.setdefault("thresholds", {})
        for name, value in defaults.get("thresholds", {}).items():
            if name not in thresholds:
                thresholds[name] = value
                changed = True

        current_untrusted = current.setdefault("untrusted_sources", [])
        for source in defaults.get("untrusted_sources", []):
            if source not in current_untrusted:
                current_untrusted.append(source)
                changed = True

        for key in ("schema_version", "default_decision", "recipient_overrides"):
            if key not in current:
                current[key] = defaults[key]
                changed = True

        if changed:
            self.policy_path.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            self.policy_path.chmod(0o600)

    @property
    def config(self) -> dict[str, Any]:
        self.initialize()
        return json.loads(self.config_path.read_text(encoding="utf-8"))

    @property
    def policy(self) -> dict[str, Any]:
        self.initialize()
        return json.loads(self.policy_path.read_text(encoding="utf-8"))

    def policy_decision(self, action_type: str, *, confidence: float | None = None, recipient: str | None = None) -> dict[str, Any]:
        policy = self.policy
        never = set(policy["actions"]["never"])
        confirm = set(policy["actions"]["confirm"])
        automatic = set(policy["actions"]["automatic"])
        if self._matches(action_type, never):
            decision = "never"
            reason = "action is prohibited by policy"
        elif self._matches(action_type, confirm):
            decision = "confirm"
            reason = "action impersonates the user or changes authoritative data"
        elif self._matches(action_type, automatic):
            decision = "automatic"
            reason = "action is low-risk and explicitly permitted"
        else:
            decision = policy.get("default_decision", "confirm")
            reason = "action is not explicitly classified"

        if action_type == "ticktick.create_followup":
            threshold = float(policy["thresholds"]["automatic_followup_confidence"])
            if confidence is None or confidence < threshold:
                decision = "confirm"
                reason = f"follow-up confidence is below {threshold:.2f}"

        if decision == "automatic" and recipient:
            recipient_rules = policy.get("recipient_overrides", {}).get(recipient, {})
            override = recipient_rules.get(action_type)
            if override in {"automatic", "confirm", "never"}:
                decision = override
                reason = "recipient-specific policy override"
        return {"action_type": action_type, "decision": decision, "reason": reason}

    @staticmethod
    def _matches(action_type: str, rules: set[str]) -> bool:
        for rule in rules:
            if rule.endswith(".*") and action_type.startswith(rule[:-1]):
                return True
            if action_type == rule:
                return True
        return False

    def doctor(self) -> dict[str, Any]:
        self.initialize()
        config = self.config
        checks: list[dict[str, Any]] = []

        def add(name: str, status: str, detail: str, required: bool = True) -> None:
            checks.append({"name": name, "status": status, "detail": detail, "required": required})

        add("runtime", "ready", str(self.home))
        add("database", "ready", str(self.db_path))
        vault = Path(config["vault"]["path"]).expanduser()
        obsidian_checkpoint = self.store.get_checkpoint("obsidian")
        obsidian_verified = bool(
            obsidian_checkpoint
            and obsidian_checkpoint.get("metadata", {}).get("behavior_verified")
        )
        if not (vault / ".obsidian").is_dir():
            add("obsidian", "blocked", str(vault))
        elif obsidian_verified:
            add("obsidian", "ready", "Vault resolved and a bounded read/write behavior canary is recorded")
        else:
            add("obsidian", "needs_canary", f"Vault resolved but no bounded write canary is recorded: {vault}")

        ticktick = shutil.which("ticktick")
        if not ticktick:
            add("ticktick-cli", "missing", "ticktick executable is not on PATH")
        else:
            result = self._run([ticktick, "auth", "status"], allow_failure=True)
            status_text = "\n".join(part for part in (result["stdout"], result["stderr"]) if part)
            signed_in = result["returncode"] == 0 and "not signed in" not in status_text.casefold()
            ticktick_checkpoint = self.store.get_checkpoint("ticktick")
            ticktick_verified = bool(
                ticktick_checkpoint
                and ticktick_checkpoint.get("metadata", {}).get("behavior_verified")
            )
            if not signed_in:
                add("ticktick-cli", "needs_auth", status_text)
            elif ticktick_verified:
                add("ticktick-cli", "ready", "OAuth and a bounded project/task read canary are recorded")
            else:
                add("ticktick-cli", "needs_canary", "OAuth is present; run bounded project/task reads and record the connector canary")

        imsg = shutil.which("imsg")
        if not imsg:
            add("imessage-cli", "missing", "imsg executable is not on PATH")
        else:
            result = self._run([imsg, "chats", "--limit", "1", "--json"], allow_failure=True)
            status_text = "\n".join(part for part in (result["stdout"], result["stderr"]) if part)
            add("imessage-cli", "ready" if result["returncode"] == 0 else "needs_permission", status_text or "Messages database is readable")

        codex = shutil.which("codex")
        if not codex:
            add("gmail-plugin", "unknown", "Codex CLI is unavailable")
        else:
            result = self._run([codex, "plugin", "list", "--json"], allow_failure=True)
            plugin_inventory = self._parse_json(result["stdout"])
            installed = any(
                plugin.get("pluginId") == "gmail@openai-curated"
                and plugin.get("installed") is True
                and plugin.get("enabled") is True
                for plugin in plugin_inventory.get("installed", [])
            ) if isinstance(plugin_inventory, dict) else False
            gmail_checkpoint = self.store.get_checkpoint("gmail")
            gmail_verified = bool(gmail_checkpoint and gmail_checkpoint.get("metadata", {}).get("behavior_verified"))
            if not installed:
                add("gmail-plugin", "missing", "Official Gmail plugin is not installed")
            elif gmail_verified:
                add("gmail-plugin", "ready", "Official Gmail plugin has a recorded bounded behavior canary")
            else:
                add("gmail-plugin", "needs_auth", "Install is present; connect approved accounts through the Codex Gmail connector and run a bounded read-only canary")

        oura_authenticated = bool(config.get("oura", {}).get("client_id")) and self._keychain_exists("oura-refresh-token")
        oura_checkpoint = self.store.get_checkpoint("oura")
        if not oura_authenticated:
            add("oura", "needs_auth", "Register an Oura OAuth application and authorize daily read scope", required=False)
        elif oura_checkpoint:
            add("oura", "ready", f"OAuth and bounded sync recorded through {oura_checkpoint.get('cursor')}", required=False)
        else:
            add("oura", "needs_canary", "OAuth is present; run a bounded read-only sync", required=False)

        health_checkpoint = self.store.get_checkpoint("apple_health")
        health_records = int((health_checkpoint or {}).get("metadata", {}).get("records", 0))
        add(
            "apple-health",
            "ready" if health_records > 0 else "needs_export",
            f"{health_records} deliberately exported record(s) in the most recent ingestion" if health_records > 0 else "No successfully ingested deliberately limited JSON export",
            required=False,
        )

        tailscale = shutil.which("tailscale")
        if tailscale:
            result = self._run([tailscale, "status", "--json"], allow_failure=True)
            add("tailscale", "ready" if result["returncode"] == 0 else "needs_login", result["stderr"] or "Tailnet status available", required=False)
        else:
            add("tailscale", "missing", "Tailscale CLI is unavailable", required=False)

        blocking = [item for item in checks if item["required"] and item["status"] != "ready"]
        return {"status": "ready" if not blocking else "needs_attention", "checks": checks}

    def ticktick_projects(self) -> list[dict[str, Any]]:
        return self._ticktick_json(["project", "list", "--json"])

    def ticktick_tasks(
        self,
        *,
        start_date: str | None = None,
        end_date: str | None = None,
        status: str = "0",
        projects: str | None = None,
    ) -> list[dict[str, Any]]:
        command = ["task", "filter", "--status", status, "--json"]
        if start_date:
            command.extend(["--start-date", start_date])
        if end_date:
            command.extend(["--end-date", end_date])
        if projects:
            command.extend(["--projects", projects])
        return self._ticktick_json(command)

    def ticktick_completed(
        self, *, start_date: str | None = None, end_date: str | None = None
    ) -> list[dict[str, Any]]:
        command = ["task", "completed", "--json"]
        if start_date:
            command.extend(["--start-date", start_date])
        if end_date:
            command.extend(["--end-date", end_date])
        return self._ticktick_json(command)

    def ticktick_habits(self) -> list[dict[str, Any]]:
        return self._ticktick_json(["habit", "list", "--json"])

    def ticktick_tags(self) -> list[dict[str, Any]]:
        return self._ticktick_json(["tag", "list", "--json"])

    def ensure_ticktick_followup_project(self, *, confirmed: bool = False) -> dict[str, Any]:
        project_name = self.config["ticktick"]["followup_project"]
        for project in self.ticktick_projects():
            if str(project.get("name", "")).casefold() == project_name.casefold():
                return {"status": "ready", "project": project, "created": False}
        action = self.request_action(
            "ticktick.create_project",
            target=project_name,
            request={"name": project_name, "view_mode": "list", "kind": "TASK"},
            idempotency_key=stable_id("ticktick.create_project", project_name.casefold()),
        )
        if action["status"] in {"proposed", "failed"} and confirmed:
            action = self.store.confirm_action(action["id"])
        if action["status"] != "confirmed":
            return {"status": "confirmation_required", "action": action, "created": False}
        result = self._run(
            ["ticktick", "project", "create", "--name", project_name, "--view-mode", "list", "--kind", "TASK", "--json"],
            allow_failure=True,
        )
        if result["returncode"] != 0:
            finished = self.store.finish_action(action["id"], status="failed", result=result)
            return {"status": "failed", "action": finished, "created": False}
        project = self._parse_json(result["stdout"])
        finished = self.store.finish_action(action["id"], status="executed", result={"project": project})
        return {"status": "ready", "project": project, "action": finished, "created": True}

    def request_action(
        self,
        action_type: str,
        *,
        target: str | None,
        request: dict[str, Any],
        confidence: float | None = None,
        idempotency_key: str | None = None,
        source_event_id: str | None = None,
    ) -> dict[str, Any]:
        decision = self.policy_decision(action_type, confidence=confidence, recipient=target)
        return self.store.request_action(
            {
                "action_type": action_type,
                "target": target,
                "request": request,
                "confidence": confidence,
                "risk": self._risk(action_type),
                "policy_decision": decision["decision"],
                "idempotency_key": idempotency_key,
                "source_event_id": source_event_id,
            }
        )

    def execute_ticktick_create(self, action_id: str, *, confirmed: bool = False) -> dict[str, Any]:
        action = self.store.get_action(action_id)
        if action["action_type"] not in {"ticktick.create_followup", "ticktick.create_task"}:
            raise LifeOSError("action is not a TickTick task creation")
        if action["status"] == "executed":
            return action
        if action["status"] == "denied":
            raise PermissionError("action is denied by policy")
        if action["status"] in {"proposed", "failed"}:
            if not confirmed:
                raise PermissionError("action requires confirmation")
            action = self.store.confirm_action(action_id)
        ticktick = shutil.which("ticktick")
        if not ticktick:
            raise LifeOSError("ticktick CLI is unavailable")
        request = action["request"]
        if action["action_type"] == "ticktick.create_followup" and not request.get("project"):
            followup = self.ensure_ticktick_followup_project(confirmed=confirmed)
            if followup["status"] != "ready":
                raise PermissionError("the AI Follow-ups TickTick project must be confirmed and created first")
            project = followup["project"]
            request["project"] = project.get("id") or project.get("projectId")
        command = [ticktick, "task", "create", "--title", request["title"], "--json"]
        for key, flag in (
            ("project", "--project"),
            ("content", "--content"),
            ("due_date", "--due-date"),
            ("time_zone", "--time-zone"),
            ("priority", "--priority"),
            ("tags", "--tags"),
        ):
            value = request.get(key)
            if value is not None:
                command.extend([flag, str(value)])
        result = self._run(command, allow_failure=True)
        if result["returncode"] != 0:
            return self.store.finish_action(action_id, status="failed", result=result)
        parsed = self._parse_json(result["stdout"])
        undo = {}
        if isinstance(parsed, dict) and parsed.get("id") and parsed.get("projectId"):
            undo = {"command": "ticktick task delete", "project_id": parsed["projectId"], "task_id": parsed["id"]}
        return self.store.finish_action(action_id, status="executed", result={"task": parsed}, undo=undo)

    def imessage_recent(self, *, lookback_hours: int | None = None, chat_limit: int = 25, message_limit: int = 30) -> dict[str, Any]:
        imsg = shutil.which("imsg")
        if not imsg:
            raise LifeOSError("imsg CLI is unavailable")
        hours = lookback_hours or int(self.config["imessage"]["lookback_hours"])
        start = (datetime.now(UTC) - timedelta(hours=hours)).isoformat(timespec="seconds")
        chats_result = self._run([imsg, "chats", "--limit", str(chat_limit), "--json"], allow_failure=True)
        if chats_result["returncode"] != 0:
            raise LifeOSError(chats_result["stderr"] or "unable to read Messages database")
        chats = self._parse_json_lines(chats_result["stdout"])
        output: list[dict[str, Any]] = []
        for chat in chats:
            chat_id = chat.get("id") or chat.get("chat_id")
            if chat_id is None:
                continue
            result = self._run(
                [imsg, "history", "--chat-id", str(chat_id), "--start", start, "--limit", str(message_limit), "--json"],
                allow_failure=True,
            )
            if result["returncode"] != 0:
                continue
            messages = self._parse_json_lines(result["stdout"])
            if messages:
                output.append({"chat": chat, "messages": messages})
                for message in messages:
                    source_id = str(message.get("guid") or message.get("id") or stable_id(chat_id, message.get("date"), message.get("text")))
                    text = str(message.get("text") or "")
                    self.store.record_event(
                        {
                            "source": "imessage",
                            "source_id": source_id,
                            "event_type": "message.sent" if message.get("is_from_me") else "message.received",
                            "occurred_at": message.get("date") or message.get("timestamp") or utcnow(),
                            "source_ref": f"imessage:chat:{chat_id}",
                            "content": text,
                            "summary": None,
                            "payload": {
                                "chat_id": chat_id,
                                "is_from_me": bool(message.get("is_from_me")),
                                "handle": message.get("sender") or message.get("handle"),
                            },
                        }
                    )
        self.store.set_checkpoint("imessage", utcnow(), {"start": start, "chat_count": len(output)})
        return {"since": start, "chats": output, "privacy": "Raw text is returned transiently and is not stored in the Life OS ledger."}

    def execute_imessage_send(self, action_id: str, *, confirmed: bool = False) -> dict[str, Any]:
        action = self.store.get_action(action_id)
        if action["action_type"] != "imessage.send":
            raise LifeOSError("action is not an iMessage send")
        if action["status"] == "executed":
            return action
        if action["status"] in {"proposed", "failed"} and confirmed:
            action = self.store.confirm_action(action_id)
        if action["status"] != "confirmed":
            raise PermissionError("iMessage send requires explicit per-message confirmation")
        request = action["request"]
        result = self._run(
            [
                "imsg",
                "send",
                "--to",
                request["to"],
                "--text",
                request["text"],
                "--service",
                "imessage",
                "--no-sms-fallback",
                "--json",
            ],
            allow_failure=True,
        )
        status = "executed" if result["returncode"] == 0 else "failed"
        return self.store.finish_action(action_id, status=status, result=result)

    def ingest_health_file(self, path: Path) -> dict[str, Any]:
        path = path.expanduser().resolve()
        if not path.is_file():
            raise LifeOSError(f"health export does not exist: {path}")
        data = json.loads(path.read_text(encoding="utf-8"))
        records = self._extract_health_records(data)
        written = 0
        for index, record in enumerate(records):
            source_id = str(record.get("id") or record.get("uuid") or stable_id(path.name, index, json.dumps(record, sort_keys=True)))
            occurred = record.get("date") or record.get("startDate") or record.get("start_date") or record.get("timestamp") or utcnow()
            metric = record.get("name") or record.get("type") or record.get("metric") or "health.metric"
            safe_payload = {
                key: value
                for key, value in record.items()
                if key not in {"notes", "sourceName", "device", "metadata"} and not isinstance(value, (dict, list))
            }
            self.store.record_event(
                {
                    "source": "apple_health",
                    "source_id": source_id,
                    "event_type": str(metric),
                    "occurred_at": str(occurred),
                    "source_ref": f"health-export:{path.name}",
                    "sensitivity": "health",
                    "payload": safe_payload,
                }
            )
            written += 1
        self.store.set_checkpoint("apple_health", path.name, {"records": written})
        return {"file": str(path), "records_seen": len(records), "records_written": written}

    def oura_sync(self, *, start_date: str | None = None, end_date: str | None = None) -> dict[str, Any]:
        config = self.config.get("oura", {})
        client_id = config.get("client_id")
        if not client_id:
            raise LifeOSError("Oura client_id is not configured")
        access_token = os.environ.get("OURA_ACCESS_TOKEN") or self._keychain_get("oura-access-token")
        if not access_token:
            access_token = self._refresh_oura_token(config)
        end = end_date or date.today().isoformat()
        start = start_date or (date.today() - timedelta(days=7)).isoformat()
        endpoints = config.get("endpoints", ["daily_sleep", "daily_readiness", "daily_activity", "daily_stress"])
        total = 0
        endpoint_results: dict[str, int] = {}
        for endpoint in endpoints:
            url = "https://api.ouraring.com/v2/usercollection/" + urllib.parse.quote(endpoint)
            query = urllib.parse.urlencode({"start_date": start, "end_date": end})
            request = urllib.request.Request(f"{url}?{query}", headers={"Authorization": f"Bearer {access_token}"})
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    payload = json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as exc:
                if exc.code == 401:
                    access_token = self._refresh_oura_token(config)
                    request.headers["Authorization"] = f"Bearer {access_token}"
                    with urllib.request.urlopen(request, timeout=30) as response:
                        payload = json.loads(response.read().decode("utf-8"))
                else:
                    raise LifeOSError(f"Oura {endpoint} failed with HTTP {exc.code}") from exc
            records = payload.get("data", [])
            endpoint_results[endpoint] = len(records)
            for record in records:
                source_id = str(record.get("id") or stable_id(endpoint, record.get("day"), json.dumps(record, sort_keys=True)))
                self.store.record_event(
                    {
                        "source": "oura",
                        "source_id": source_id,
                        "event_type": endpoint,
                        "occurred_at": record.get("day") or record.get("timestamp") or utcnow(),
                        "source_ref": f"oura:{endpoint}:{source_id}",
                        "sensitivity": "health",
                        "payload": record,
                    }
                )
                total += 1
        self.store.set_checkpoint("oura", end, {"start": start, "endpoints": endpoint_results})
        return {"start_date": start, "end_date": end, "records_written": total, "endpoints": endpoint_results}

    def oura_auth_url(
        self, *, client_id: str, redirect_uri: str | None = None
    ) -> dict[str, Any]:
        self.initialize()
        redirect = redirect_uri or self.config["oura"]["redirect_uri"]
        state = secrets.token_urlsafe(32)
        state_path = self.home / "oura-oauth-state.json"
        state_path.write_text(
            json.dumps(
                {
                    "state": state,
                    "client_id": client_id,
                    "redirect_uri": redirect,
                    "created_at": utcnow(),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        state_path.chmod(0o600)
        params = {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": redirect,
            "scope": " ".join(self.config["oura"]["scopes"]),
            "state": state,
        }
        return {
            "authorization_url": "https://cloud.ouraring.com/oauth/authorize?" + urllib.parse.urlencode(params),
            "redirect_uri": redirect,
            "state_file": str(state_path),
        }

    def oura_exchange_code(
        self,
        *,
        code: str,
        client_secret: str,
        returned_state: str,
    ) -> dict[str, Any]:
        state_path = self.home / "oura-oauth-state.json"
        if not state_path.is_file():
            raise LifeOSError("Oura OAuth state is missing; generate a new authorization URL")
        oauth_state = json.loads(state_path.read_text(encoding="utf-8"))
        if not secrets.compare_digest(returned_state, oauth_state["state"]):
            raise PermissionError("Oura OAuth state did not match")
        body = urllib.parse.urlencode(
            {
                "grant_type": "authorization_code",
                "code": code,
                "client_id": oauth_state["client_id"],
                "client_secret": client_secret,
                "redirect_uri": oauth_state["redirect_uri"],
            }
        ).encode("utf-8")
        request = urllib.request.Request("https://api.ouraring.com/oauth/token", data=body, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise LifeOSError(f"Oura token exchange failed with HTTP {exc.code}") from exc
        self._keychain_set("oura-client-secret", client_secret)
        self._keychain_set("oura-access-token", payload["access_token"])
        if payload.get("refresh_token"):
            self._keychain_set("oura-refresh-token", payload["refresh_token"])
        config = self.config
        config["oura"]["client_id"] = oauth_state["client_id"]
        config["oura"]["redirect_uri"] = oauth_state["redirect_uri"]
        self.config_path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        self.config_path.chmod(0o600)
        state_path.unlink()
        return {
            "status": "authorized",
            "scope": payload.get("scope"),
            "expires_in": payload.get("expires_in"),
            "refresh_token_stored": bool(payload.get("refresh_token")),
        }

    def oura_authorize(
        self,
        *,
        client_id: str,
        client_secret: str,
        timeout_seconds: int = 300,
    ) -> dict[str, Any]:
        redirect = urllib.parse.urlparse(self.config["oura"]["redirect_uri"])
        if redirect.scheme != "http" or redirect.hostname not in {"127.0.0.1", "localhost"}:
            raise LifeOSError("Oura interactive authorization requires a loopback HTTP redirect URI")
        if redirect.port is None:
            raise LifeOSError("Oura loopback redirect URI must include an explicit port")

        authorization = self.oura_auth_url(client_id=client_id, redirect_uri=redirect.geturl())
        callback: dict[str, str] = {}
        expected_path = redirect.path or "/"

        class CallbackHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                request = urllib.parse.urlparse(self.path)
                if request.path != expected_path:
                    self.send_error(404)
                    return
                params = urllib.parse.parse_qs(request.query)
                for key in ("code", "state", "error", "error_description"):
                    if params.get(key):
                        callback[key] = params[key][0]
                ok = "code" in callback and "state" in callback and "error" not in callback
                body = (
                    "Oura authorization received. You can close this tab."
                    if ok
                    else "Oura authorization failed. Return to the terminal for details."
                ).encode("utf-8")
                self.send_response(200 if ok else 400)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format: str, *args: Any) -> None:
                return

        server = http.server.HTTPServer((redirect.hostname, redirect.port), CallbackHandler)
        server.timeout = max(1, timeout_seconds)
        try:
            if not webbrowser.open(authorization["authorization_url"]):
                raise LifeOSError(f"Unable to open a browser. Visit: {authorization['authorization_url']}")
            server.handle_request()
        finally:
            server.server_close()

        if callback.get("error"):
            detail = callback.get("error_description") or callback["error"]
            raise LifeOSError(f"Oura authorization was declined or failed: {detail}")
        if not callback.get("code") or not callback.get("state"):
            raise LifeOSError("Timed out waiting for the Oura authorization callback")
        return self.oura_exchange_code(
            code=callback["code"],
            client_secret=client_secret,
            returned_state=callback["state"],
        )

    def context_snapshot(self, *, since: str | None = None) -> dict[str, Any]:
        if since is None:
            since = (datetime.now(UTC) - timedelta(days=7)).isoformat(timespec="seconds")
        events = self.store.list_events(since=since, limit=500)
        return {
            "generated_at": utcnow(),
            "since": since,
            "open_commitments": self.store.list_commitments(status="open", limit=100),
            "candidate_commitments": self.store.list_commitments(status="candidate", limit=100),
            "decisions_due": self.store.list_decisions(review_before=date.today().isoformat(), limit=100),
            "communication_drafts": self.store.list_drafts(status="draft", limit=100),
            "pending_actions": self.store.list_actions(status="proposed", limit=100),
            "recent_reviews": self.store.list_reviews(period_start=since[:10], limit=100),
            "events": events,
            "voice_profile": str(self.voice_path),
            "soul": str(self.soul_path),
        }

    def write_obsidian_note(
        self,
        relative_path: str,
        content: str,
        *,
        overwrite: bool = False,
        confirmed: bool = False,
    ) -> dict[str, Any]:
        config = self.config["vault"]
        vault = Path(config["path"]).expanduser().resolve()
        if Path(relative_path).is_absolute():
            raise LifeOSError("Obsidian note path must be relative to the configured vault")
        target = (vault / relative_path).resolve()
        if target.suffix.casefold() != ".md":
            raise LifeOSError("Obsidian writes must target a Markdown file")
        if vault not in target.parents:
            raise LifeOSError("note path escapes the configured vault")
        allowed_roots = [(vault / root).resolve() for root in config["write_roots"]]
        if not any(root == target.parent or root in target.parents for root in allowed_roots):
            raise PermissionError("note path is outside designated Life OS write roots")
        existing = target.read_text(encoding="utf-8") if target.exists() else None
        if existing == content:
            return {"path": str(target), "bytes": len(content.encode("utf-8")), "status": "unchanged"}
        if existing is not None and not overwrite:
            raise FileExistsError(target)
        if existing is not None and not confirmed:
            raise PermissionError("editing an existing Obsidian note requires explicit confirmation")

        action_type = "obsidian.edit_existing" if existing is not None else "obsidian.create_designated"
        content_hash = hashlib.sha256(content.encode("utf-8")).hexdigest()
        action = self.request_action(
            action_type,
            target=relative_path,
            request={"relative_path": relative_path, "content_hash": content_hash, "bytes": len(content.encode("utf-8"))},
            idempotency_key=stable_id(action_type, relative_path, content_hash),
        )
        if action["status"] == "executed":
            raise LifeOSError("the audited write already executed but the target no longer matches; review manually")
        if action["status"] in {"proposed", "failed"}:
            if not confirmed:
                raise PermissionError("Obsidian write requires confirmation")
            action = self.store.confirm_action(action["id"])
        if action["status"] != "confirmed":
            raise PermissionError("Obsidian write is not authorized")

        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            target.write_text(content, encoding="utf-8")
        except OSError as exc:
            self.store.finish_action(action["id"], status="failed", result={"error": str(exc)})
            raise
        finished = self.store.finish_action(
            action["id"],
            status="executed",
            result={"path": str(target), "content_hash": content_hash},
        )
        return {
            "path": str(target),
            "bytes": len(content.encode("utf-8")),
            "status": "created" if existing is None else "updated",
            "action": finished,
        }

    @staticmethod
    def load_plist(path: Path) -> dict[str, Any]:
        with path.open("rb") as handle:
            return plistlib.load(handle)

    def _refresh_oura_token(self, config: dict[str, Any]) -> str:
        refresh_token = self._keychain_get("oura-refresh-token")
        client_secret = self._keychain_get("oura-client-secret")
        if not refresh_token or not client_secret:
            raise LifeOSError("Oura OAuth refresh credentials are unavailable in Keychain")
        body = urllib.parse.urlencode(
            {
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
                "client_id": config["client_id"],
                "client_secret": client_secret,
            }
        ).encode("utf-8")
        request = urllib.request.Request("https://api.ouraring.com/oauth/token", data=body, method="POST")
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
        access_token = payload["access_token"]
        self._keychain_set("oura-access-token", access_token)
        if payload.get("refresh_token"):
            self._keychain_set("oura-refresh-token", payload["refresh_token"])
        return access_token

    def _ticktick_json(self, arguments: list[str]) -> list[dict[str, Any]]:
        ticktick = shutil.which("ticktick")
        if not ticktick:
            raise LifeOSError("ticktick CLI is unavailable")
        result = self._run([ticktick, *arguments], allow_failure=True)
        if result["returncode"] != 0 or "not signed in" in (result["stdout"] + result["stderr"]).casefold():
            raise LifeOSError(result["stderr"] or result["stdout"] or "TickTick command failed")
        parsed = self._parse_json(result["stdout"])
        if isinstance(parsed, list):
            return [item for item in parsed if isinstance(item, dict)]
        if isinstance(parsed, dict):
            for key in ("data", "tasks", "projects", "habits", "tags"):
                if isinstance(parsed.get(key), list):
                    return [item for item in parsed[key] if isinstance(item, dict)]
            return [parsed]
        return []

    def _keychain_service(self, key: str) -> str:
        return f"com.arend.lifeos.{key}"

    def _keychain_exists(self, key: str) -> bool:
        return self._keychain_get(key) is not None

    def _keychain_get(self, key: str) -> str | None:
        security = shutil.which("security")
        if not security:
            return None
        result = self._run([security, "find-generic-password", "-s", self._keychain_service(key), "-w"], allow_failure=True)
        return result["stdout"].strip() if result["returncode"] == 0 else None

    def _keychain_set(self, key: str, value: str) -> None:
        security = shutil.which("security")
        if not security:
            raise LifeOSError("macOS Keychain command is unavailable")
        result = self._run(
            [
                security,
                "add-generic-password",
                "-U",
                "-s",
                self._keychain_service(key),
                "-a",
                os.environ.get("USER", "lifeos"),
                "-w",
            ],
            allow_failure=True,
            input_text=f"{value}\n{value}\n",
        )
        if result["returncode"] != 0:
            raise LifeOSError(result["stderr"] or "unable to store secret in Keychain")

    @staticmethod
    def _risk(action_type: str) -> str:
        if action_type in {"gmail.send", "imessage.send", "calendar.create", "calendar.update"}:
            return "high"
        if action_type.startswith("read.") or action_type.startswith("draft."):
            return "low"
        return "medium"

    @staticmethod
    def _extract_health_records(data: Any) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        if isinstance(data, list):
            for item in data:
                if isinstance(item, dict):
                    records.append(item)
            return records
        if not isinstance(data, dict):
            return records
        for key in ("data", "metrics", "workouts", "records"):
            value = data.get(key)
            if isinstance(value, list):
                for item in value:
                    if isinstance(item, dict):
                        normalized = dict(item)
                        normalized.setdefault("type", key.removesuffix("s"))
                        records.append(normalized)
            elif isinstance(value, dict):
                for metric_name, items in value.items():
                    if isinstance(items, list):
                        for item in items:
                            if isinstance(item, dict):
                                normalized = dict(item)
                                normalized.setdefault("type", metric_name)
                                records.append(normalized)
        if not records and any(key in data for key in ("date", "startDate", "timestamp", "value")):
            records.append(data)
        return records

    @staticmethod
    def _run(
        command: list[str],
        *,
        allow_failure: bool = False,
        input_text: str | None = None,
    ) -> dict[str, Any]:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            input=input_text,
        )
        result = {
            "command": command[0],
            "returncode": completed.returncode,
            "stdout": completed.stdout.strip(),
            "stderr": completed.stderr.strip(),
        }
        if completed.returncode != 0 and not allow_failure:
            raise LifeOSError(completed.stderr.strip() or f"command failed: {command[0]}")
        return result

    @staticmethod
    def _parse_json(value: str) -> Any:
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value

    @staticmethod
    def _parse_json_lines(value: str) -> list[dict[str, Any]]:
        parsed: list[dict[str, Any]] = []
        for line in value.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, list):
                parsed.extend(entry for entry in item if isinstance(entry, dict))
            elif isinstance(item, dict):
                parsed.append(item)
        return parsed
