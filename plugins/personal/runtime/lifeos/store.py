from __future__ import annotations

import hashlib
import json
import sqlite3
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Iterator


def utcnow() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def stable_id(*parts: object) -> str:
    material = "\x1f".join(str(part) for part in parts)
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS schema_meta (
    version INTEGER NOT NULL,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    source_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    source_ref TEXT,
    person_id TEXT,
    project_id TEXT,
    summary TEXT,
    content_hash TEXT,
    sensitivity TEXT NOT NULL DEFAULT 'private',
    confidence REAL NOT NULL DEFAULT 1.0 CHECK(confidence >= 0 AND confidence <= 1),
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(source, source_id, event_type)
);

CREATE TABLE IF NOT EXISTS people (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    canonical_handle TEXT,
    relationship TEXT,
    notes_ref TEXT,
    sensitivity TEXT NOT NULL DEFAULT 'private',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    authority TEXT NOT NULL,
    authority_id TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    notes_ref TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(authority, authority_id)
);

CREATE TABLE IF NOT EXISTS commitments (
    id TEXT PRIMARY KEY,
    direction TEXT NOT NULL CHECK(direction IN ('to_me', 'by_me')),
    status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('candidate', 'open', 'resolved', 'dismissed')),
    source TEXT NOT NULL,
    source_id TEXT NOT NULL,
    source_event_id TEXT REFERENCES events(id),
    person_id TEXT REFERENCES people(id),
    project_id TEXT REFERENCES projects(id),
    obligation TEXT NOT NULL,
    due_at TEXT,
    confidence REAL NOT NULL CHECK(confidence >= 0 AND confidence <= 1),
    reason TEXT,
    suggested_action TEXT,
    task_id TEXT,
    idempotency_key TEXT NOT NULL UNIQUE,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    resolved_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS decisions (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    decision TEXT NOT NULL,
    rationale TEXT,
    decided_at TEXT NOT NULL,
    review_at TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    source_ref TEXT,
    project_id TEXT REFERENCES projects(id),
    expected_outcome TEXT,
    actual_outcome TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS drafts (
    id TEXT PRIMARY KEY,
    channel TEXT NOT NULL CHECK(channel IN ('gmail', 'imessage', 'other')),
    source_thread_id TEXT,
    recipient TEXT,
    body TEXT NOT NULL,
    voice_mode TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'draft' CHECK(status IN ('draft', 'approved', 'sent', 'discarded')),
    content_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS actions (
    id TEXT PRIMARY KEY,
    requested_at TEXT NOT NULL,
    action_type TEXT NOT NULL,
    target TEXT,
    risk TEXT NOT NULL,
    policy_decision TEXT NOT NULL CHECK(policy_decision IN ('automatic', 'confirm', 'never')),
    status TEXT NOT NULL CHECK(status IN ('proposed', 'confirmed', 'executed', 'failed', 'undone', 'denied')),
    confidence REAL,
    source_event_id TEXT REFERENCES events(id),
    idempotency_key TEXT NOT NULL UNIQUE,
    request_json TEXT NOT NULL,
    result_json TEXT,
    undo_json TEXT,
    confirmed_at TEXT,
    executed_at TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS checkpoints (
    connector TEXT PRIMARY KEY,
    cursor TEXT,
    observed_at TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS connector_runs (
    id TEXT PRIMARY KEY,
    connector TEXT NOT NULL,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    status TEXT NOT NULL,
    records_seen INTEGER NOT NULL DEFAULT 0,
    records_written INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS review_runs (
    id TEXT PRIMARY KEY,
    review_type TEXT NOT NULL,
    period_start TEXT NOT NULL,
    period_end TEXT NOT NULL,
    note_ref TEXT,
    summary TEXT,
    created_at TEXT NOT NULL,
    UNIQUE(review_type, period_start, period_end)
);

CREATE INDEX IF NOT EXISTS events_occurred_idx ON events(occurred_at);
CREATE INDEX IF NOT EXISTS commitments_status_due_idx ON commitments(status, due_at);
CREATE INDEX IF NOT EXISTS actions_status_idx ON actions(status, requested_at);
CREATE INDEX IF NOT EXISTS connector_runs_connector_idx ON connector_runs(connector, started_at);
"""


class Store:
    def __init__(self, path: Path):
        self.path = path

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        connection = sqlite3.connect(self.path)
        self.path.chmod(0o600)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        try:
            yield connection
            connection.commit()
        finally:
            connection.close()

    def initialize(self) -> None:
        with self.connect() as connection:
            connection.executescript(SCHEMA)
            existing = connection.execute("SELECT version FROM schema_meta ORDER BY version DESC LIMIT 1").fetchone()
            if existing is None:
                connection.execute(
                    "INSERT INTO schema_meta(version, applied_at) VALUES (?, ?)",
                    (1, utcnow()),
                )

    def record_event(self, event: dict[str, Any]) -> dict[str, Any]:
        now = utcnow()
        event_id = event.get("id") or stable_id(
            event["source"], event["source_id"], event["event_type"]
        )
        payload = event.get("payload", {})
        content_hash = event.get("content_hash")
        if content_hash is None and event.get("content") is not None:
            content_hash = hashlib.sha256(str(event["content"]).encode("utf-8")).hexdigest()
        values = (
            event_id,
            event["source"],
            event["source_id"],
            event["event_type"],
            event.get("occurred_at") or now,
            event.get("observed_at") or now,
            event.get("source_ref"),
            event.get("person_id"),
            event.get("project_id"),
            event.get("summary"),
            content_hash,
            event.get("sensitivity", "private"),
            float(event.get("confidence", 1.0)),
            json.dumps(payload, sort_keys=True),
            now,
            now,
        )
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO events(
                    id, source, source_id, event_type, occurred_at, observed_at,
                    source_ref, person_id, project_id, summary, content_hash,
                    sensitivity, confidence, payload_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, source_id, event_type) DO UPDATE SET
                    occurred_at=excluded.occurred_at,
                    observed_at=excluded.observed_at,
                    source_ref=excluded.source_ref,
                    person_id=excluded.person_id,
                    project_id=excluded.project_id,
                    summary=excluded.summary,
                    content_hash=excluded.content_hash,
                    sensitivity=excluded.sensitivity,
                    confidence=excluded.confidence,
                    payload_json=excluded.payload_json,
                    updated_at=excluded.updated_at
                """,
                values,
            )
            row = connection.execute(
                "SELECT * FROM events WHERE source=? AND source_id=? AND event_type=?",
                (event["source"], event["source_id"], event["event_type"]),
            ).fetchone()
        return self._row(row)

    def upsert_commitment(self, commitment: dict[str, Any]) -> dict[str, Any]:
        now = utcnow()
        key = commitment.get("idempotency_key") or stable_id(
            commitment["source"],
            commitment["source_id"],
            commitment["direction"],
            commitment["obligation"].strip().casefold(),
        )
        commitment_id = commitment.get("id") or key
        confidence = float(commitment["confidence"])
        default_status = "open" if confidence >= 0.85 else "candidate"
        values = (
            commitment_id,
            commitment["direction"],
            commitment.get("status", default_status),
            commitment["source"],
            commitment["source_id"],
            commitment.get("source_event_id"),
            commitment.get("person_id"),
            commitment.get("project_id"),
            commitment["obligation"],
            commitment.get("due_at"),
            confidence,
            commitment.get("reason"),
            commitment.get("suggested_action"),
            commitment.get("task_id"),
            key,
            now,
            now,
            now,
            now,
        )
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO commitments(
                    id, direction, status, source, source_id, source_event_id,
                    person_id, project_id, obligation, due_at, confidence, reason,
                    suggested_action, task_id, idempotency_key, first_seen_at,
                    last_seen_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(idempotency_key) DO UPDATE SET
                    status=CASE
                        WHEN commitments.status IN ('resolved', 'dismissed') THEN commitments.status
                        ELSE excluded.status
                    END,
                    due_at=COALESCE(excluded.due_at, commitments.due_at),
                    confidence=excluded.confidence,
                    reason=excluded.reason,
                    suggested_action=excluded.suggested_action,
                    task_id=COALESCE(excluded.task_id, commitments.task_id),
                    last_seen_at=excluded.last_seen_at,
                    updated_at=excluded.updated_at
                """,
                values,
            )
            row = connection.execute(
                "SELECT * FROM commitments WHERE idempotency_key = ?", (key,)
            ).fetchone()
        return self._row(row)

    def resolve_commitment(self, commitment_id: str, status: str = "resolved") -> dict[str, Any]:
        if status not in {"resolved", "dismissed"}:
            raise ValueError("commitment status must be resolved or dismissed")
        now = utcnow()
        with self.connect() as connection:
            connection.execute(
                "UPDATE commitments SET status=?, resolved_at=?, updated_at=? WHERE id=?",
                (status, now, now, commitment_id),
            )
            row = connection.execute("SELECT * FROM commitments WHERE id=?", (commitment_id,)).fetchone()
        if row is None:
            raise KeyError(commitment_id)
        return self._row(row)

    def list_commitments(self, status: str | None = "open", limit: int = 100) -> list[dict[str, Any]]:
        query = "SELECT * FROM commitments"
        params: list[Any] = []
        if status:
            query += " WHERE status = ?"
            params.append(status)
        query += " ORDER BY COALESCE(due_at, '9999-12-31'), updated_at DESC LIMIT ?"
        params.append(limit)
        with self.connect() as connection:
            rows = connection.execute(query, params).fetchall()
        return [self._row(row) for row in rows]

    def list_events(self, source: str | None = None, since: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if source:
            clauses.append("source = ?")
            params.append(source)
        if since:
            clauses.append("occurred_at >= ?")
            params.append(since)
        query = "SELECT * FROM events"
        if clauses:
            query += " WHERE " + " AND ".join(clauses)
        query += " ORDER BY occurred_at DESC LIMIT ?"
        params.append(limit)
        with self.connect() as connection:
            rows = connection.execute(query, params).fetchall()
        return [self._row(row) for row in rows]

    def request_action(self, action: dict[str, Any]) -> dict[str, Any]:
        now = utcnow()
        key = action.get("idempotency_key") or stable_id(
            action["action_type"], action.get("target", ""), json.dumps(action.get("request", {}), sort_keys=True)
        )
        action_id = action.get("id") or key
        decision = action["policy_decision"]
        status = "denied" if decision == "never" else ("confirmed" if decision == "automatic" else "proposed")
        values = (
            action_id,
            now,
            action["action_type"],
            action.get("target"),
            action.get("risk", "medium"),
            decision,
            status,
            action.get("confidence"),
            action.get("source_event_id"),
            key,
            json.dumps(action.get("request", {}), sort_keys=True),
            now if status == "confirmed" else None,
            now,
        )
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO actions(
                    id, requested_at, action_type, target, risk, policy_decision,
                    status, confidence, source_event_id, idempotency_key,
                    request_json, confirmed_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(idempotency_key) DO NOTHING
                """,
                values,
            )
            row = connection.execute("SELECT * FROM actions WHERE idempotency_key=?", (key,)).fetchone()
        return self._row(row)

    def confirm_action(self, action_id: str) -> dict[str, Any]:
        now = utcnow()
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM actions WHERE id=?", (action_id,)).fetchone()
            if row is None:
                raise KeyError(action_id)
            if row["policy_decision"] == "never":
                raise PermissionError("policy-denied actions cannot be confirmed")
            if row["status"] == "confirmed":
                return self._row(row)
            if row["status"] not in {"proposed", "failed"}:
                raise PermissionError(f"cannot confirm an action in {row['status']} state")
            connection.execute(
                "UPDATE actions SET status='confirmed', confirmed_at=?, updated_at=? WHERE id=?",
                (now, now, action_id),
            )
            row = connection.execute("SELECT * FROM actions WHERE id=?", (action_id,)).fetchone()
        return self._row(row)

    def finish_action(
        self,
        action_id: str,
        *,
        status: str,
        result: dict[str, Any] | None = None,
        undo: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if status not in {"executed", "failed", "undone"}:
            raise ValueError(status)
        now = utcnow()
        with self.connect() as connection:
            existing = connection.execute("SELECT * FROM actions WHERE id=?", (action_id,)).fetchone()
            if existing is None:
                raise KeyError(action_id)
            if status in {"executed", "failed"} and existing["status"] != "confirmed":
                raise PermissionError("only a confirmed action may be executed")
            if status == "undone" and existing["status"] != "executed":
                raise PermissionError("only an executed action may be undone")
            connection.execute(
                """
                UPDATE actions
                SET status=?, result_json=?, undo_json=?, executed_at=?, updated_at=?
                WHERE id=?
                """,
                (
                    status,
                    json.dumps(result or {}, sort_keys=True),
                    json.dumps(undo or {}, sort_keys=True),
                    now,
                    now,
                    action_id,
                ),
            )
            row = connection.execute("SELECT * FROM actions WHERE id=?", (action_id,)).fetchone()
        return self._row(row)

    def get_action(self, action_id: str) -> dict[str, Any]:
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM actions WHERE id=?", (action_id,)).fetchone()
        if row is None:
            raise KeyError(action_id)
        return self._row(row)

    def list_actions(self, status: str | None = None, limit: int = 100) -> list[dict[str, Any]]:
        query = "SELECT * FROM actions"
        params: list[Any] = []
        if status:
            query += " WHERE status=?"
            params.append(status)
        query += " ORDER BY requested_at DESC LIMIT ?"
        params.append(limit)
        with self.connect() as connection:
            rows = connection.execute(query, params).fetchall()
        return [self._row(row) for row in rows]

    def record_decision(self, decision: dict[str, Any]) -> dict[str, Any]:
        now = utcnow()
        decided_at = decision.get("decided_at") or now
        decision_id = decision.get("id") or stable_id(
            decision.get("source_ref", ""),
            decision["title"].strip().casefold(),
            str(decided_at)[:10],
        )
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO decisions(
                    id, title, decision, rationale, decided_at, review_at, status,
                    source_ref, project_id, expected_outcome, actual_outcome,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title=excluded.title,
                    decision=excluded.decision,
                    rationale=excluded.rationale,
                    review_at=COALESCE(excluded.review_at, decisions.review_at),
                    status=excluded.status,
                    source_ref=COALESCE(excluded.source_ref, decisions.source_ref),
                    project_id=COALESCE(excluded.project_id, decisions.project_id),
                    expected_outcome=COALESCE(excluded.expected_outcome, decisions.expected_outcome),
                    actual_outcome=COALESCE(excluded.actual_outcome, decisions.actual_outcome),
                    updated_at=excluded.updated_at
                """,
                (
                    decision_id,
                    decision["title"],
                    decision["decision"],
                    decision.get("rationale"),
                    decided_at,
                    decision.get("review_at"),
                    decision.get("status", "active"),
                    decision.get("source_ref"),
                    decision.get("project_id"),
                    decision.get("expected_outcome"),
                    decision.get("actual_outcome"),
                    now,
                    now,
                ),
            )
            row = connection.execute("SELECT * FROM decisions WHERE id=?", (decision_id,)).fetchone()
        return self._row(row)

    def list_decisions(
        self,
        *,
        status: str | None = "active",
        review_before: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if status:
            clauses.append("status=?")
            params.append(status)
        if review_before:
            clauses.append("review_at IS NOT NULL AND review_at<=?")
            params.append(review_before)
        query = "SELECT * FROM decisions"
        if clauses:
            query += " WHERE " + " AND ".join(clauses)
        query += " ORDER BY COALESCE(review_at, '9999-12-31'), decided_at DESC LIMIT ?"
        params.append(limit)
        with self.connect() as connection:
            rows = connection.execute(query, params).fetchall()
        return [self._row(row) for row in rows]

    def save_draft(self, draft: dict[str, Any]) -> dict[str, Any]:
        now = utcnow()
        body_hash = hashlib.sha256(draft["body"].encode("utf-8")).hexdigest()
        draft_id = draft.get("id") or stable_id(
            draft["channel"],
            draft.get("source_thread_id", ""),
            draft.get("recipient", ""),
            body_hash,
        )
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO drafts(
                    id, channel, source_thread_id, recipient, body, voice_mode,
                    status, content_hash, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    voice_mode=excluded.voice_mode,
                    status=excluded.status,
                    updated_at=excluded.updated_at
                """,
                (
                    draft_id,
                    draft["channel"],
                    draft.get("source_thread_id"),
                    draft.get("recipient"),
                    draft["body"],
                    draft.get("voice_mode", "default"),
                    draft.get("status", "draft"),
                    body_hash,
                    now,
                    now,
                ),
            )
            row = connection.execute("SELECT * FROM drafts WHERE id=?", (draft_id,)).fetchone()
        return self._row(row)

    def list_drafts(
        self,
        *,
        status: str | None = "draft",
        channel: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if status:
            clauses.append("status=?")
            params.append(status)
        if channel:
            clauses.append("channel=?")
            params.append(channel)
        query = "SELECT * FROM drafts"
        if clauses:
            query += " WHERE " + " AND ".join(clauses)
        query += " ORDER BY updated_at DESC LIMIT ?"
        params.append(limit)
        with self.connect() as connection:
            rows = connection.execute(query, params).fetchall()
        return [self._row(row) for row in rows]

    def set_checkpoint(self, connector: str, cursor: str | None, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
        now = utcnow()
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO checkpoints(connector, cursor, observed_at, metadata_json)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(connector) DO UPDATE SET
                    cursor=excluded.cursor,
                    observed_at=excluded.observed_at,
                    metadata_json=excluded.metadata_json
                """,
                (connector, cursor, now, json.dumps(metadata or {}, sort_keys=True)),
            )
            row = connection.execute("SELECT * FROM checkpoints WHERE connector=?", (connector,)).fetchone()
        return self._row(row)

    def get_checkpoint(self, connector: str) -> dict[str, Any] | None:
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM checkpoints WHERE connector=?", (connector,)).fetchone()
        return self._row(row) if row else None

    def record_review(self, review: dict[str, Any]) -> dict[str, Any]:
        review_id = review.get("id") or stable_id(review["review_type"], review["period_start"], review["period_end"])
        now = utcnow()
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO review_runs(id, review_type, period_start, period_end, note_ref, summary, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(review_type, period_start, period_end) DO UPDATE SET
                    note_ref=excluded.note_ref,
                    summary=excluded.summary
                """,
                (
                    review_id,
                    review["review_type"],
                    review["period_start"],
                    review["period_end"],
                    review.get("note_ref"),
                    review.get("summary"),
                    now,
                ),
            )
            row = connection.execute(
                "SELECT * FROM review_runs WHERE review_type=? AND period_start=? AND period_end=?",
                (review["review_type"], review["period_start"], review["period_end"]),
            ).fetchone()
        return self._row(row)

    def list_reviews(
        self,
        *,
        review_type: str | None = None,
        period_start: str | None = None,
        period_end: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if review_type:
            clauses.append("review_type=?")
            params.append(review_type)
        if period_start:
            clauses.append("period_start>=?")
            params.append(period_start)
        if period_end:
            clauses.append("period_end<=?")
            params.append(period_end)
        query = "SELECT * FROM review_runs"
        if clauses:
            query += " WHERE " + " AND ".join(clauses)
        query += " ORDER BY period_end DESC, created_at DESC LIMIT ?"
        params.append(limit)
        with self.connect() as connection:
            rows = connection.execute(query, params).fetchall()
        return [self._row(row) for row in rows]

    @staticmethod
    def _row(row: sqlite3.Row | None) -> dict[str, Any]:
        if row is None:
            return {}
        result = dict(row)
        for key in ("payload_json", "request_json", "result_json", "undo_json", "metadata_json"):
            if key in result and result[key] is not None:
                try:
                    result[key.removesuffix("_json")] = json.loads(result[key])
                except json.JSONDecodeError:
                    result[key.removesuffix("_json")] = {}
                del result[key]
        return result
