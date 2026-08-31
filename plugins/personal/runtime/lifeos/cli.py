from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from .runtime import LifeOS, LifeOSError


def emit(value: Any) -> None:
    print(json.dumps(value, indent=2, sort_keys=True, default=str))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lifeos", description="Local-first Personal AI / Life OS runtime")
    parser.add_argument("--home", type=Path, help="Override the machine-local Life OS state directory")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("init", help="Create the local state directory, policy, profiles, and ledger")
    sub.add_parser("doctor", help="Check runtime and connector readiness")

    connector = sub.add_parser("connector-verify", help="Record a completed behavioral connector canary")
    connector.add_argument("connector", choices=("gmail", "ticktick", "imessage", "obsidian", "oura", "apple_health"))
    connector.add_argument("--identity")
    connector.add_argument("--metadata-json", default="{}")

    policy = sub.add_parser("policy", help="Evaluate a proposed side effect")
    policy.add_argument("action_type")
    policy.add_argument("--confidence", type=float)
    policy.add_argument("--recipient")

    event = sub.add_parser("event-record", help="Record or update a normalized event")
    event.add_argument("--source", required=True)
    event.add_argument("--source-id", required=True)
    event.add_argument("--type", required=True)
    event.add_argument("--occurred-at")
    event.add_argument("--source-ref")
    event.add_argument("--summary")
    event.add_argument("--confidence", type=float, default=1.0)
    event.add_argument("--sensitivity", default="private")
    event.add_argument("--payload-json", default="{}")

    events = sub.add_parser("events", help="List normalized events")
    events.add_argument("--source")
    events.add_argument("--since")
    events.add_argument("--limit", type=int, default=200)

    commitment = sub.add_parser("commitment-upsert", help="Record a commitment candidate or open loop")
    commitment.add_argument("--direction", choices=("to_me", "by_me"), required=True)
    commitment.add_argument("--source", required=True)
    commitment.add_argument("--source-id", required=True)
    commitment.add_argument("--obligation", required=True)
    commitment.add_argument("--confidence", type=float, required=True)
    commitment.add_argument("--due-at")
    commitment.add_argument("--reason")
    commitment.add_argument("--suggested-action")
    commitment.add_argument("--status", choices=("candidate", "open", "resolved", "dismissed"))

    commitments = sub.add_parser("commitments", help="List commitments")
    commitments.add_argument("--status", choices=("candidate", "open", "resolved", "dismissed", "all"), default="open")
    commitments.add_argument("--limit", type=int, default=100)

    resolve = sub.add_parser("commitment-resolve", help="Resolve or dismiss a commitment")
    resolve.add_argument("id")
    resolve.add_argument("--dismiss", action="store_true")

    request = sub.add_parser("action-request", help="Create an audited action proposal")
    request.add_argument("--type", required=True)
    request.add_argument("--target")
    request.add_argument("--request-json", required=True)
    request.add_argument("--confidence", type=float)
    request.add_argument("--idempotency-key")

    actions = sub.add_parser("actions", help="List audited actions")
    actions.add_argument("--status", choices=("proposed", "confirmed", "executed", "failed", "undone", "denied"))
    actions.add_argument("--limit", type=int, default=100)

    confirm = sub.add_parser("action-confirm", help="Confirm one proposed action")
    confirm.add_argument("id")

    draft = sub.add_parser("draft-save", help="Save an idempotent local communication draft")
    draft.add_argument("--channel", choices=("gmail", "imessage", "other"), required=True)
    draft.add_argument("--thread")
    draft.add_argument("--recipient")
    draft.add_argument("--body-file", type=Path, required=True)
    draft.add_argument("--voice-mode", default="default")
    drafts = sub.add_parser("drafts", help="List local communication drafts")
    drafts.add_argument("--status", choices=("draft", "approved", "sent", "discarded", "all"), default="draft")
    drafts.add_argument("--channel", choices=("gmail", "imessage", "other"))
    drafts.add_argument("--limit", type=int, default=100)

    decision = sub.add_parser("decision-record", help="Record or update a normalized decision")
    decision.add_argument("--title", required=True)
    decision.add_argument("--decision", required=True)
    decision.add_argument("--rationale")
    decision.add_argument("--decided-at")
    decision.add_argument("--review-at")
    decision.add_argument("--status", default="active")
    decision.add_argument("--source-ref")
    decision.add_argument("--project-id")
    decision.add_argument("--expected-outcome")
    decision.add_argument("--actual-outcome")
    decision.add_argument("--id")
    decisions = sub.add_parser("decisions", help="List normalized decisions")
    decisions.add_argument("--status", default="active")
    decisions.add_argument("--review-before")
    decisions.add_argument("--limit", type=int, default=100)

    ticktick = sub.add_parser("ticktick-create-followup", help="Request and optionally execute a TickTick follow-up")
    ticktick.add_argument("--title", required=True)
    ticktick.add_argument("--project")
    ticktick.add_argument("--content")
    ticktick.add_argument("--due-date")
    ticktick.add_argument("--priority", type=int)
    ticktick.add_argument("--tags")
    ticktick.add_argument("--confidence", type=float, required=True)
    ticktick.add_argument("--idempotency-key", required=True)
    ticktick.add_argument("--confirmed", action="store_true")

    ticktick_task = sub.add_parser("ticktick-create-task", help="Create a user-requested TickTick task with an audit record")
    ticktick_task.add_argument("--title", required=True)
    ticktick_task.add_argument("--project")
    ticktick_task.add_argument("--content")
    ticktick_task.add_argument("--due-date")
    ticktick_task.add_argument("--priority", type=int)
    ticktick_task.add_argument("--tags")
    ticktick_task.add_argument("--idempotency-key", required=True)
    ticktick_task.add_argument("--confirmed", action="store_true", help="The user explicitly requested this exact task")

    sub.add_parser("ticktick-projects", help="List TickTick projects as JSON")
    ticktick_tasks = sub.add_parser("ticktick-tasks", help="List TickTick tasks as JSON")
    ticktick_tasks.add_argument("--start-date")
    ticktick_tasks.add_argument("--end-date")
    ticktick_tasks.add_argument("--status", default="0")
    ticktick_tasks.add_argument("--projects")
    ticktick_completed = sub.add_parser("ticktick-completed", help="List completed TickTick tasks")
    ticktick_completed.add_argument("--start-date")
    ticktick_completed.add_argument("--end-date")
    sub.add_parser("ticktick-habits", help="List TickTick habits")
    sub.add_parser("ticktick-tags", help="List TickTick tags")
    ticktick_project = sub.add_parser("ticktick-ensure-followups", help="Ensure the AI Follow-ups project exists")
    ticktick_project.add_argument("--confirmed", action="store_true")

    imessage_recent = sub.add_parser("imessage-recent", help="Read recent iMessages and checkpoint metadata")
    imessage_recent.add_argument("--lookback-hours", type=int)
    imessage_recent.add_argument("--chat-limit", type=int, default=25)
    imessage_recent.add_argument("--message-limit", type=int, default=30)

    imessage_send = sub.add_parser("imessage-send", help="Request or execute a confirmed iMessage send")
    imessage_send.add_argument("--to", required=True)
    imessage_send.add_argument("--text", required=True)
    imessage_send.add_argument("--idempotency-key", required=True)
    imessage_send.add_argument("--confirmed", action="store_true")

    health = sub.add_parser("health-ingest", help="Ingest a Health Auto Export JSON file")
    health.add_argument("path", type=Path)
    health_scan = sub.add_parser("health-scan", help="Ingest JSON exports from configured Apple Health inboxes")
    health_scan.add_argument("--path", action="append", type=Path, dest="paths")
    health_scan.add_argument("--max-files", type=int, default=100)

    oura = sub.add_parser("oura-sync", help="Synchronize read-only Oura daily summaries")
    oura.add_argument("--start-date")
    oura.add_argument("--end-date")
    oura_url = sub.add_parser("oura-auth-url", help="Generate an Oura OAuth authorization URL")
    oura_url.add_argument("--client-id", required=True)
    oura_url.add_argument("--redirect-uri")
    oura_authorize = sub.add_parser("oura-authorize", help="Run the loopback Oura OAuth flow; client secret is read from stdin")
    oura_authorize.add_argument("--client-id", required=True)
    oura_authorize.add_argument("--timeout-seconds", type=int, default=300)
    oura_exchange = sub.add_parser("oura-exchange-code", help="Exchange an Oura OAuth code; client secret is read from stdin")
    oura_exchange.add_argument("--code", required=True)
    oura_exchange.add_argument("--state", required=True)

    snapshot = sub.add_parser("context", help="Emit a normalized context snapshot")
    snapshot.add_argument("--since")

    note = sub.add_parser("obsidian-write", help="Write a new note inside a designated Life OS vault root")
    note.add_argument("relative_path")
    note.add_argument("--content-file", type=Path, required=True)
    note.add_argument("--overwrite", action="store_true")
    note.add_argument("--confirmed", action="store_true", help="The user approved this exact overwrite")

    review = sub.add_parser("review-record", help="Record a completed durable review")
    review.add_argument("--type", required=True)
    review.add_argument("--period-start", required=True)
    review.add_argument("--period-end", required=True)
    review.add_argument("--note-ref")
    review.add_argument("--summary")
    reviews = sub.add_parser("reviews", help="List durable review records")
    reviews.add_argument("--type")
    reviews.add_argument("--period-start")
    reviews.add_argument("--period-end")
    reviews.add_argument("--limit", type=int, default=100)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    lifeos = LifeOS(home=args.home)
    try:
        if args.command == "init":
            emit(lifeos.initialize())
        elif args.command == "doctor":
            emit(lifeos.doctor())
        elif args.command == "connector-verify":
            metadata = json.loads(args.metadata_json)
            metadata["behavior_verified"] = True
            if args.identity:
                metadata["identity"] = args.identity
            emit(lifeos.store.set_checkpoint(args.connector, args.identity, metadata))
        elif args.command == "policy":
            emit(lifeos.policy_decision(args.action_type, confidence=args.confidence, recipient=args.recipient))
        elif args.command == "event-record":
            emit(
                lifeos.store.record_event(
                    {
                        "source": args.source,
                        "source_id": args.source_id,
                        "event_type": args.type,
                        "occurred_at": args.occurred_at,
                        "source_ref": args.source_ref,
                        "summary": args.summary,
                        "confidence": args.confidence,
                        "sensitivity": args.sensitivity,
                        "payload": json.loads(args.payload_json),
                    }
                )
            )
        elif args.command == "events":
            emit(lifeos.store.list_events(source=args.source, since=args.since, limit=args.limit))
        elif args.command == "commitment-upsert":
            payload = {
                "direction": args.direction,
                "source": args.source,
                "source_id": args.source_id,
                "obligation": args.obligation,
                "confidence": args.confidence,
                "due_at": args.due_at,
                "reason": args.reason,
                "suggested_action": args.suggested_action,
            }
            if args.status:
                payload["status"] = args.status
            emit(lifeos.store.upsert_commitment(payload))
        elif args.command == "commitments":
            emit(lifeos.store.list_commitments(status=None if args.status == "all" else args.status, limit=args.limit))
        elif args.command == "commitment-resolve":
            emit(lifeos.store.resolve_commitment(args.id, "dismissed" if args.dismiss else "resolved"))
        elif args.command == "action-request":
            emit(
                lifeos.request_action(
                    args.type,
                    target=args.target,
                    request=json.loads(args.request_json),
                    confidence=args.confidence,
                    idempotency_key=args.idempotency_key,
                )
            )
        elif args.command == "actions":
            emit(lifeos.store.list_actions(status=args.status, limit=args.limit))
        elif args.command == "action-confirm":
            emit(lifeos.store.confirm_action(args.id))
        elif args.command == "draft-save":
            emit(
                lifeos.store.save_draft(
                    {
                        "channel": args.channel,
                        "source_thread_id": args.thread,
                        "recipient": args.recipient,
                        "body": args.body_file.read_text(encoding="utf-8"),
                        "voice_mode": args.voice_mode,
                    }
                )
            )
        elif args.command == "drafts":
            emit(
                lifeos.store.list_drafts(
                    status=None if args.status == "all" else args.status,
                    channel=args.channel,
                    limit=args.limit,
                )
            )
        elif args.command == "decision-record":
            emit(
                lifeos.store.record_decision(
                    {
                        "id": args.id,
                        "title": args.title,
                        "decision": args.decision,
                        "rationale": args.rationale,
                        "decided_at": args.decided_at,
                        "review_at": args.review_at,
                        "status": args.status,
                        "source_ref": args.source_ref,
                        "project_id": args.project_id,
                        "expected_outcome": args.expected_outcome,
                        "actual_outcome": args.actual_outcome,
                    }
                )
            )
        elif args.command == "decisions":
            emit(
                lifeos.store.list_decisions(
                    status=None if args.status == "all" else args.status,
                    review_before=args.review_before,
                    limit=args.limit,
                )
            )
        elif args.command == "ticktick-create-followup":
            request = {
                "title": args.title,
                "project": args.project,
                "content": args.content,
                "due_date": args.due_date,
                "priority": args.priority,
                "tags": args.tags,
                "time_zone": lifeos.config["timezone"],
            }
            action = lifeos.request_action(
                "ticktick.create_followup",
                target=args.project,
                request=request,
                confidence=args.confidence,
                idempotency_key=args.idempotency_key,
            )
            if action["policy_decision"] == "automatic" or args.confirmed:
                action = lifeos.execute_ticktick_create(action["id"], confirmed=args.confirmed)
            emit(action)
        elif args.command == "ticktick-create-task":
            request = {
                "title": args.title,
                "project": args.project,
                "content": args.content,
                "due_date": args.due_date,
                "priority": args.priority,
                "tags": args.tags,
                "time_zone": lifeos.config["timezone"],
            }
            action = lifeos.request_action(
                "ticktick.create_task",
                target=args.project,
                request=request,
                idempotency_key=args.idempotency_key,
            )
            if args.confirmed:
                action = lifeos.execute_ticktick_create(action["id"], confirmed=True)
            emit(action)
        elif args.command == "ticktick-projects":
            emit(lifeos.ticktick_projects())
        elif args.command == "ticktick-tasks":
            emit(lifeos.ticktick_tasks(start_date=args.start_date, end_date=args.end_date, status=args.status, projects=args.projects))
        elif args.command == "ticktick-completed":
            emit(lifeos.ticktick_completed(start_date=args.start_date, end_date=args.end_date))
        elif args.command == "ticktick-habits":
            emit(lifeos.ticktick_habits())
        elif args.command == "ticktick-tags":
            emit(lifeos.ticktick_tags())
        elif args.command == "ticktick-ensure-followups":
            emit(lifeos.ensure_ticktick_followup_project(confirmed=args.confirmed))
        elif args.command == "imessage-recent":
            emit(lifeos.imessage_recent(lookback_hours=args.lookback_hours, chat_limit=args.chat_limit, message_limit=args.message_limit))
        elif args.command == "imessage-send":
            action = lifeos.request_action(
                "imessage.send",
                target=args.to,
                request={"to": args.to, "text": args.text},
                idempotency_key=args.idempotency_key,
            )
            if args.confirmed:
                action = lifeos.execute_imessage_send(action["id"], confirmed=True)
            emit(action)
        elif args.command == "health-ingest":
            emit(lifeos.ingest_health_file(args.path))
        elif args.command == "health-scan":
            emit(lifeos.scan_health_inboxes(paths=args.paths, max_files=args.max_files))
        elif args.command == "oura-sync":
            emit(lifeos.oura_sync(start_date=args.start_date, end_date=args.end_date))
        elif args.command == "oura-auth-url":
            emit(lifeos.oura_auth_url(client_id=args.client_id, redirect_uri=args.redirect_uri))
        elif args.command == "oura-authorize":
            client_secret = sys.stdin.readline().rstrip("\n")
            if not client_secret:
                raise LifeOSError("Oura client secret was not provided on stdin")
            emit(
                lifeos.oura_authorize(
                    client_id=args.client_id,
                    client_secret=client_secret,
                    timeout_seconds=args.timeout_seconds,
                )
            )
        elif args.command == "oura-exchange-code":
            client_secret = sys.stdin.readline().rstrip("\n")
            if not client_secret:
                raise LifeOSError("Oura client secret was not provided on stdin")
            emit(lifeos.oura_exchange_code(code=args.code, client_secret=client_secret, returned_state=args.state))
        elif args.command == "context":
            emit(lifeos.context_snapshot(since=args.since))
        elif args.command == "obsidian-write":
            emit(
                lifeos.write_obsidian_note(
                    args.relative_path,
                    args.content_file.read_text(encoding="utf-8"),
                    overwrite=args.overwrite,
                    confirmed=args.confirmed,
                )
            )
        elif args.command == "review-record":
            emit(
                lifeos.store.record_review(
                    {
                        "review_type": args.type,
                        "period_start": args.period_start,
                        "period_end": args.period_end,
                        "note_ref": args.note_ref,
                        "summary": args.summary,
                    }
                )
            )
        elif args.command == "reviews":
            emit(
                lifeos.store.list_reviews(
                    review_type=args.type,
                    period_start=args.period_start,
                    period_end=args.period_end,
                    limit=args.limit,
                )
            )
        else:
            raise LifeOSError(f"unsupported command: {args.command}")
    except (LifeOSError, PermissionError, FileNotFoundError, FileExistsError, KeyError, ValueError, json.JSONDecodeError) as exc:
        emit({"status": "error", "error": str(exc), "error_type": type(exc).__name__})
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
