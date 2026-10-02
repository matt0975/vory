#!/usr/bin/env python3
"""A protocol-faithful fake Hermes dashboard, for developing the iOS app without a real agent.

Speaks the same surface the app uses: the dashboard REST endpoints plus the JSON-RPC
WebSocket at /api/ws (gateway.ready, session.*, prompt.submit, streamed message.delta,
tool.start/complete, an `approval` server->client request, session.usage ticks,
message.complete). No AI provider, no API keys, no network calls.

    python3 mock_gateway.py --port 9119 --token mock-token

Then add a gateway in the app with URL http://127.0.0.1:9119 and that session token.
Requires the `websockets` package (it ships in the Hermes venv).
"""
from __future__ import annotations

import argparse
import asyncio
import os
import json
import random
import time
import uuid

from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.http11 import Response

TOKEN = "mock-token"
PROFILES = ["default", "work"]
MODEL = "anthropic/claude-sonnet-4.6"
PROVIDER = "anthropic"
CONTEXT_MAX = 200_000

# The reply the fake agent "writes", chosen to exercise markdown, a code fence and tool cards.
REPLY_PART_1 = """I'll look at what's filling the disk on that host, then clean up safely.

## What I found

`/var/log` is using **4.2 GB**, almost all of it rotated files older than 90 days:

- `nginx/access.log.*` — 2.1 GB across 34 files
- `postgres/*.log` — 1.4 GB, the oldest from March
- `app/debug.log.*` — 0.7 GB, left over from the verbose-logging experiment

"""

REPLY_PART_2 = """The live logs and anything written in the last 90 days stay untouched. Here is the
command I want to run:

```bash
find /var/log -name '*.log.*' -mtime +90 -delete
```

"""

REPLY_PART_3 = """Done — 4.2 GB freed, and the filesystem is back to 41% used.

I left `nginx/access.log` and today's `postgres` log alone since both are still open by
running processes. If you want this to keep happening on its own, `logrotate` already has a
config at `/etc/logrotate.d/nginx`; it just has `rotate 52` set, which is why a year of logs
accumulated. Lowering that to `rotate 8` would hold the directory near 400 MB."""


def usage(output: int, calls: int = 1) -> dict:
    used = 18_400 + output * 4
    return {
        "model": MODEL, "input": 17_900, "output": output, "reasoning": 0,
        "total": 17_900 + output, "calls": calls, "compressions": 0,
        "context_used": used, "context_max": CONTEXT_MAX,
        "context_percent": int(used / CONTEXT_MAX * 100),
        "context_source": "models.dev", "context_estimated": False,
        "cache_hit_pct": 62, "cache_read": 11_040, "cache_write": 6_860,
        "avg_tps": 48.2, "cost_usd": 0.0231, "cost_status": "estimated",
    }


def session_info(title: str, running: bool, profile: str) -> dict:
    return {
        "model": MODEL, "provider": PROVIDER, "reasoning_effort": "medium",
        "reasoning_effort_wire": "medium", "service_tier": "", "fast": False, "yolo": False,
        "approval_mode": "smart", "tools": {}, "skills": {}, "cwd": "/srv/app", "branch": "main",
        "terminal_backend": "local", "personality": "", "running": running,
        "title": title, "stored_session_id": "", "version": "0.21.4", "release_date": "",
        "update_command": "", "usage": usage(0, 0), "profile_name": profile,
        "mcp_servers": [], "lazy": False,
    }


# ── REST ──────────────────────────────────────────────────────────────────────────────────────

RESUMES: list[dict] = []
STORED_SESSIONS: list[dict] = [
    {"id": "20260921_154212_a1b2c3", "title": "Disk cleanup on the log host",
     "preview": "I'll look at what's filling the disk on that host, then clean up safely.",
     "source": "tui", "model": MODEL, "started_at": time.time() - 5400,
     "last_active": time.time() - 5100, "message_count": 6, "is_active": False,
     "archived": False, "pinned": True, "profile": "default", "cwd": "/srv/app"},
    {"id": "20260921_093355_d4e5f6", "title": "Rewrite the nightly export job",
     "preview": "The export is timing out because the query has no index on created_at.",
     "source": "tui", "model": MODEL, "started_at": time.time() - 29000,
     "last_active": time.time() - 27600, "message_count": 24, "is_active": False,
     "archived": False, "pinned": False, "profile": "default", "cwd": "/srv/app"},
    {"id": "20260930_221000_work01", "title": "Bot Chat",
     "preview": "Got it. The export is paused until you say go; I'll hold the 2 AM run too.",
     "source": "cli", "model": MODEL, "started_at": time.time() - 90000,
     "last_active": time.time() - 4900, "message_count": 4, "is_active": False,
     "archived": False, "pinned": False, "profile": "work", "cwd": "/srv/export"},
    {"id": "20260920_221014_99aabb", "title": "Weekly dependency audit",
     "preview": "Three advisories this week, one of them reachable from our code path.",
     "source": "cron", "model": MODEL, "started_at": time.time() - 100000,
     "last_active": time.time() - 99000, "message_count": 11, "is_active": False,
     "archived": False, "pinned": False, "profile": "default", "cwd": "/srv/app"},
]

CONFIG = {
    "model": MODEL,
    "approvals": {"mode": "smart", "timeout": 300, "cron_mode": "deny"},
    "agent": {"reasoning_effort": "medium", "max_iterations": 40},
    "display": {"streaming": True, "show_reasoning": True, "timestamps": False},
    "logging": {"level": "INFO"},
    "terminal": {"backend": "local"},
}

CONFIG_SCHEMA = {
    "fields": {
        "model": {"type": "string", "description": "Default model (e.g. anthropic/claude-sonnet-4.6)", "category": "general"},
        "model_context_length": {"type": "number", "description": "Context window override (0 = auto-detect from model metadata)", "category": "general"},
        "max_live_sessions": {"type": "number", "description": "Max Live Sessions", "category": "general"},
        "approvals.mode": {"type": "select", "description": "Dangerous command approval mode", "category": "security", "options": ["manual", "smart", "off"]},
        "approvals.timeout": {"type": "number", "description": "Seconds before an unanswered prompt fails closed", "category": "security"},
        "agent.reasoning_effort": {"type": "select", "description": "Reasoning effort", "category": "agent", "options": ["", "minimal", "low", "medium", "high", "xhigh", "max"]},
        "agent.max_iterations": {"type": "number", "description": "Maximum tool-loop iterations per turn", "category": "agent"},
        "display.streaming": {"type": "boolean", "description": "Stream tokens as they arrive", "category": "display"},
        "display.show_reasoning": {"type": "boolean", "description": "Show the model's reasoning blocks", "category": "display"},
        "display.timestamps": {"type": "boolean", "description": "Show [HH:MM] timestamps on transcript rows", "category": "display"},
        "logging.level": {"type": "select", "description": "Log level for agent.log", "category": "logging", "options": ["DEBUG", "INFO", "WARNING", "ERROR"]},
        "terminal.backend": {"type": "select", "description": "Terminal execution backend", "category": "terminal", "options": ["local", "docker", "ssh", "modal"]},
    },
    "category_order": ["general", "agent", "terminal", "display", "security", "logging"],
}

ENV_VARS = {
    # The real gateway's row shape (is_set, redacted_value with the «redacted:…» wrapper).
    "ANTHROPIC_API_KEY": {"is_set": True, "redacted_value": "«redacted:sk-a...9f2c»", "description": "Anthropic API key", "category": "LLM Providers", "is_password": True, "provider": "anthropic"},
    "OPENAI_API_KEY": {"is_set": False, "redacted_value": None, "description": "OpenAI API key", "category": "LLM Providers", "is_password": True, "provider": "openai"},
    "OPENROUTER_API_KEY": {"is_set": False, "redacted_value": None, "description": "OpenRouter API key", "category": "LLM Providers", "is_password": True, "provider": "openrouter"},
    "TAVILY_API_KEY": {"is_set": True, "redacted_value": "«redacted:tvly...a13b»", "description": "Tavily search API key", "category": "Tool API Keys", "is_password": True},
    "BRAVE_API_KEY": {"is_set": False, "redacted_value": None, "description": "Brave Search API key", "category": "Tool API Keys"},
    "TELEGRAM_BOT_TOKEN": {"is_set": False, "redacted_value": None, "description": "Telegram bot token", "category": "Messaging"},
}

TOOLSETS = [
    {"name": "web", "label": "Web Search & Scraping", "description": "web_search, web_extract", "platform": "cli", "enabled": True, "configured": True, "tools": ["web_extract", "web_search"]},
    {"name": "terminal", "label": "Terminal & Processes", "description": "terminal, process", "platform": "cli", "enabled": True, "configured": True, "tools": ["process_manage", "terminal"]},
    {"name": "files", "label": "File Operations", "description": "read, write, patch, search", "platform": "cli", "enabled": True, "configured": True, "tools": ["patch", "read_file", "search_files", "write_file"]},
    {"name": "code", "label": "Code Execution", "description": "execute_code", "platform": "cli", "enabled": True, "configured": True, "tools": ["execute_code"]},
    {"name": "browser", "label": "Browser Automation", "description": "navigate, click, type, scroll", "platform": "cli", "enabled": False, "configured": True, "tools": ["browser_click", "browser_navigate"]},
    {"name": "vision", "label": "Vision / Image Analysis", "description": "vision_analyze", "platform": "cli", "enabled": True, "configured": False, "tools": ["vision_analyze"]},
]

SKILLS = [
    {"name": "code-review", "description": "Review a diff for correctness bugs and suggest fixes", "category": "engineering", "enabled": True, "usage": 42, "provenance": "bundled"},
    {"name": "incident-writeup", "description": "Turn an incident timeline into a postmortem", "category": "ops", "enabled": True, "usage": 7, "provenance": "hub"},
    {"name": "release-notes", "description": "Draft release notes from merged pull requests", "category": "engineering", "enabled": False, "usage": 3, "provenance": "agent"},
]

CRON_JOBS = [
    {"job_id": "morning-brief", "name": "Morning brief", "schedule": "0 7 * * 1-5",
     "prompt_preview": "Summarize overnight alerts, failed jobs and open PRs.", "deliver": "local",
     "enabled": True, "state": "active", "next_run_at": "2026-09-23T07:00:00Z",
     "last_run_at": "2026-09-22T07:00:00Z", "last_status": "ok"},
    {"job_id": "dep-audit", "name": "Weekly dependency audit", "schedule": "0 3 * * 0",
     "prompt_preview": "Run the dependency audit and report anything reachable from our code.",
     "deliver": "local", "enabled": False, "state": "paused", "last_status": "ok"},
]


def rest(path: str, query: dict) -> tuple[int, object] | None:
    base = path.split("?")[0]
    if base == "/api/status":
        return 200, {"version": "0.21.4", "gateway": {"status": "running", "pid": 4242},
                     "gateway_running": True, "gateway_state": "running", "active_sessions": 1,
                     "auth_required": False, "auth_providers": [], "auth_flows": [],
                     "memory": {"pressure": "ok", "gateway_rss_mb": 412, "system_available_mb": 9200},
                     "disk": {"pressure": "ok", "free_mb": 184_320, "total_mb": 494_384, "used_percent": 41}}
    if base == "/api/health":
        return 200, {"ok": True, "version": "0.21.4", "auth_required": False}
    if base == "/api/profiles":
        return 200, {"profiles": [
            {"name": "default", "path": "/home/hermes/.hermes", "is_default": True, "model": MODEL,
             "provider": PROVIDER, "description": "Main agent", "skill_count": 18, "has_env": True},
            {"name": "work", "path": "/home/hermes/.hermes-work", "is_default": False, "model": MODEL,
             "provider": PROVIDER, "description": "Work profile", "skill_count": 11, "has_env": True}]}
    if base.startswith("/api/profiles/") and base.endswith("/soul"):
        return 200, {"content": "# Workshop assistant\n\nYou are a careful operator. Prefer read-only commands, ask before deleting, and summarize what you changed.", "exists": True}
    if base == "/api/profiles/active":
        return 200, {"active": "default", "current": "default"}
    if base == "/api/sessions":
        # The real gateway refuses a page over 100 (FastAPI le=100 → 422), as a tester's Home found out.
        if int(query.get("limit") or 20) > 100:
            return 422, {"detail": [{"loc": ["query", "limit"], "msg": "Input should be less than or equal to 100", "type": "less_than_equal"}]}
        # The mock lists every chat under every bot (the demo data is small), but each row says
        # whose store it is in, as the real gateway's rows do.
        return 200, {"sessions": [{**s, "profile": s.get("profile") or "default"} for s in STORED_SESSIONS],
                     "total": len(STORED_SESSIONS), "limit": 100, "offset": 0}
    if base == "/api/_mock/resumes":
        # Every session.resume as it arrived, for checking which bot a client resumed a chat under.
        return 200, {"resumes": RESUMES}
    if base.startswith("/api/sessions/") and base.count("/") == 3 and base.split("/")[3] not in ("search", "stats"):
        # One stored row, from the store of the bot that was asked: 404 from every other bot.
        sid = base.split("/")[3]
        row = next((r for r in STORED_SESSIONS if r["id"] == sid), None)
        asked = query.get("profile") or "default"
        if not row or (row.get("profile") or "default") != asked:
            return 404, {"detail": "session not found"}
        return 200, {**row, "profile": asked, "is_default_profile": asked == "default"}
    if base == "/api/sessions/search":
        q = (query.get("q") or "").lower()
        return 200, {"sessions": [s for s in STORED_SESSIONS if q in json.dumps(s).lower()]}
    if base.startswith("/api/sessions/") and base.endswith("/messages"):
        # The raw stored-row shape (content parts, integer id, ISO timestamp), not the flattened
        # WebSocket history — the app's lenient decoder must cope with both.
        sid = base.split("/")[3]
        row = next((r for r in STORED_SESSIONS if r["id"] == sid), None)
        if not row:
            return 404, {"detail": "session not found"}
        iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t))
        if row["title"] == "Bot Chat":
            msgs = [
                {"id": 1, "role": "user", "content": "Message from 🤖 default: Heads up, I'm auditing the nightly export's query plan this week.", "timestamp": iso(row["started_at"])},
                {"id": 2, "role": "assistant", "content": "Noted. The export runs at 2 AM; I'll leave the schedule alone until you're done.", "timestamp": iso(row["started_at"] + 30)},
                {"id": 3, "role": "user", "content": "Message from 🤖 default: I'm about to clear the rotated logs on the log host. Hold your nightly export until I confirm.", "timestamp": iso(row["last_active"] - 20)},
                {"id": 4, "role": "assistant", "content": "Got it. The export is paused until you say go; I'll hold the 2 AM run too.", "timestamp": iso(row["last_active"])},
            ]
            return 200, {"session_id": sid, "profile": "work", "messages": msgs,
                         "pagination": {"limit": 60, "offset": 0, "order": "latest", "returned": len(msgs)}}
        msgs = [
            {"id": 1, "role": "user", "content": "The log host is at 94% disk. Can you take a look?", "timestamp": iso(row["started_at"])},
            {"id": 2, "role": "assistant", "content": [{"type": "text", "text": REPLY_PART_1 + REPLY_PART_2}], "timestamp": iso(row["last_active"]),
             "tool_calls": [{"id": "c1", "function": {"name": "terminal", "arguments": "{}"}}]},
            {"id": 3, "role": "tool", "content": "/var/log 41G", "name": "terminal", "timestamp": iso(row["last_active"])},
            {"id": 4, "role": "assistant", "content": REPLY_PART_3, "timestamp": iso(row["last_active"])},
        ]
        return 200, {"session_id": sid, "profile": "default", "messages": msgs,
                     "pagination": {"limit": 60, "offset": 0, "order": "latest", "returned": len(msgs)}}
    if base == "/api/sessions/stats":
        return 200, {"total": len(STORED_SESSIONS), "active_store": len(STORED_SESSIONS), "archived": 1,
                     "messages": 41, "by_source": {"ios": 2, "tui": 1, "cron": 1}}
    if base == "/api/hermes/update/check":
        return 200, {"install_method": "git", "current_version": "0.21.4", "behind": 3,
                     "update_available": True, "can_apply": True, "update_command": "hermes update", "message": None,
                     "commits": [{"sha": "be65eab584", "summary": "fix(dashboard): model picker skew guard", "author": "hermes"},
                                 {"sha": "9c1d2e3f40", "summary": "feat(gateway): hosted rooms replica state", "author": "hermes"},
                                 {"sha": "17aa0b9cd1", "summary": "chore: bump deps", "author": "hermes"}]}
    if base == "/api/gateway/restart":
        RESTART["started"] = time.time()
        return 200, {"ok": True, "pid": 4243, "name": "gateway-restart"}
    if base == "/api/actions/gateway-restart/status":
        running = time.time() - RESTART.get("started", 0) < 4
        return 200, {"name": "gateway-restart", "running": running, "exit_code": None if running else 0, "pid": 4243,
                     "lines": ["=== hermes gateway restart ===", "stopping gateway (pid 4242)", "starting gateway"] + ([] if running else ["gateway up (pid 4243)"])}
    if base == "/api/model/options":
        return 200, {"model": MODEL, "provider": PROVIDER, "providers": [
            {"slug": "claude-subscription-directsdk-experimental", "name": "Claude subscription", "authenticated": False,
             "warning": "Needs the Claude Code CLI installed and signed in on the gateway machine.",
             "featured_models": ["claude-subscription/claude-opus-4.6"], "models": ["claude-subscription/claude-opus-4.6"]},
            {"slug": "anthropic", "name": "Anthropic", "authenticated": True, "is_current": True,
             "featured_models": ["anthropic/claude-opus-4.6", "anthropic/claude-sonnet-4.6", "anthropic/claude-haiku-4.5"],
             "models": ["anthropic/claude-opus-4.6", "anthropic/claude-sonnet-4.6", "anthropic/claude-haiku-4.5"],
             "capabilities": {MODEL: {"fast": True, "reasoning": True, "can_disable_reasoning": True}}},
            {"slug": "openai", "name": "OpenAI", "authenticated": False,
             "featured_models": ["openai/gpt-5.1", "openai/gpt-5.1-mini"],
             "models": ["openai/gpt-5.1", "openai/gpt-5.1-mini"]},
            {"slug": "nous", "name": "Nous Research", "authenticated": True, "free_tier": True,
             "featured_models": ["nous/hermes-4-70b"], "models": ["nous/hermes-4-70b"]}]}
    if base == "/api/model/auxiliary":
        return 200, {"main": {"provider": PROVIDER, "model": MODEL}, "tasks": [
            {"task": "titles", "provider": "auto", "model": "", "base_url": "", "local_endpoint": False},
            {"task": "compression", "provider": "auto", "model": "", "base_url": "", "local_endpoint": False}]}
    if base == "/api/config":
        return 200, {"config": CONFIG}
    if base == "/api/config/schema":
        return 200, CONFIG_SCHEMA
    if base == "/api/analytics/usage":
        days = int(query.get("days") or 30)
        import datetime, random
        rnd = random.Random(7)
        daily = []
        for i in range(days - 1, -1, -1):
            d = datetime.date.today() - datetime.timedelta(days=i)
            if d.weekday() == 6 and rnd.random() < 0.7:
                continue
            n = rnd.randint(1, 6)
            daily.append({"day": d.isoformat(), "input_tokens": n * rnd.randint(9000, 40000), "output_tokens": n * rnd.randint(1500, 6000),
                          "cache_read_tokens": n * rnd.randint(40000, 120000), "reasoning_tokens": 0, "estimated_cost": round(n * 0.31, 2),
                          "actual_cost": 0, "sessions": n, "api_calls": n * rnd.randint(4, 15)})
        tot = lambda k: sum(x[k] for x in daily)
        return 200, {"daily": daily, "period_days": days,
                     "by_model": [{"model": MODEL, "input_tokens": tot("input_tokens"), "output_tokens": tot("output_tokens"), "estimated_cost": tot("estimated_cost"), "sessions": tot("sessions"), "api_calls": tot("api_calls")},
                                  {"model": "openai/gpt-5.5", "input_tokens": 120000, "output_tokens": 9000, "estimated_cost": 1.2, "sessions": 3, "api_calls": 20}],
                     "totals": {"total_input": tot("input_tokens"), "total_output": tot("output_tokens"), "total_cache_read": tot("cache_read_tokens"), "total_reasoning": 0,
                                "total_estimated_cost": tot("estimated_cost"), "total_actual_cost": 0, "total_sessions": tot("sessions"), "total_api_calls": tot("api_calls")},
                     "skills": {}, "tools": {}}
    if base == "/api/dashboard/plugins/hub":
        return 200, {"plugins": [
            {"name": "vory-push", "version": "1.0.33", "description": "Vory's companion: push notifications, Live Activities and the Bot Chat watch.",
             "source": "user", "runtime_status": "enabled", "has_dashboard_manifest": False, "path": "/home/hermes/.hermes/plugins/vory-push",
             "can_remove": True, "can_update_git": False, "auth_required": False, "user_hidden": False},
            {"name": "kanban", "version": "0.4.2", "description": "A board of the agent's tasks on the dashboard.",
             "source": "bundled", "runtime_status": "bundled", "has_dashboard_manifest": True, "path": "/opt/hermes/plugins/kanban",
             "can_remove": False, "can_update_git": False, "auth_required": False, "user_hidden": False},
            {"name": "dispatcher", "version": "1.2.0", "description": "Routes cron deliveries and channel messages to the right profile.",
             "source": "git", "runtime_status": "enabled", "has_dashboard_manifest": True, "path": "/home/hermes/.hermes/plugins/dispatcher",
             "can_remove": True, "can_update_git": True, "auth_required": False, "user_hidden": False},
            {"name": "memory-sqlite", "version": "0.9.0", "description": "Long-term memory in a local SQLite file.",
             "source": "user", "runtime_status": "disabled", "has_dashboard_manifest": False, "path": "/home/hermes/.hermes/plugins/memory-sqlite",
             "can_remove": True, "can_update_git": False, "auth_required": False, "user_hidden": False},
            {"name": "github", "version": "2.1.0", "description": "Pull requests, issues and reviews through the GitHub API.",
             "source": "user", "runtime_status": "enabled", "has_dashboard_manifest": False, "path": "/home/hermes/.hermes/plugins/github",
             "can_remove": True, "can_update_git": True, "auth_required": True, "auth_command": "hermes plugins auth github", "user_hidden": False},
        ], "orphan_dashboard_plugins": [], "providers": {"memory_provider": "memory-sqlite", "memory_options": [], "context_engine": "default", "context_options": []}}
    if base == "/api/env":
        return 200, ENV_VARS
    if base == "/api/tools/toolsets":
        return 200, TOOLSETS
    if base == "/api/skills":
        return 200, SKILLS
    if base == "/api/mcp/servers":
        return 200, {"servers": [
            {"name": "filesystem", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/srv"], "enabled": True, "transport": "stdio"},
            {"name": "github", "url": "https://api.githubcopilot.com/mcp/", "enabled": False, "transport": "http"}]}
    if base == "/api/cron/jobs":
        return 200, {"jobs": CRON_JOBS, "count": len(CRON_JOBS)}
    if base == "/api/messaging/platforms":
        return 200, {"platforms": [
            {"id": "telegram", "label": "Telegram", "status": "not configured", "enabled": False},
            {"id": "discord", "label": "Discord", "status": "not configured", "enabled": False}]}
    if base == "/api/files":
        # MOCK_FILES_FAIL=1: the home listing fails the way a broken symlink makes the real
        # gateway fail (a tester's report); folders opened by path still list.
        if os.environ.get("MOCK_FILES_FAIL") and not query.get("path"):
            return 500, {"detail": "Could not stat path: [Errno 2] No such file or directory: '~/.local/share/Steam/linux32/steam'"}
        return 200, {"path": "/home/hermes", "parent": None, "root": None, "locked_root": None, "entries": [
            {"name": ".git", "path": "/home/hermes/.git", "is_directory": True, "modified_at": time.time() - 9000},
            {"name": ".env", "path": "/home/hermes/.env", "is_directory": False, "size": 212, "modified_at": time.time() - 9000, "mime_type": "text/plain"},
            {"name": "projects", "path": "/home/hermes/projects", "is_directory": True, "modified_at": time.time() - 400},
            {"name": "reports", "path": "/home/hermes/reports", "is_directory": True, "modified_at": time.time() - 8000},
            {"name": "disk-report.md", "path": "/home/hermes/disk-report.md", "is_directory": False, "size": 4_120, "modified_at": time.time() - 300, "mime_type": "text/markdown"},
            {"name": "cleanup.log", "path": "/home/hermes/cleanup.log", "is_directory": False, "size": 88_402, "modified_at": time.time() - 280, "mime_type": "text/plain"}]}
    if base == "/api/logs":
        lines = []
        for i in range(9):
            lines.append(f"2026-09-22 20:39:{i:02d},{i * 97 % 1000:03d} INFO httpx2: HTTP Request: POST http://127.0.0.1:8795/tools/mcp \"HTTP/1.1 200 OK\"")
        lines += ["2026-09-22 20:39:10,004 WARNING tools.registry: check_fn _check_xai_video_requirements returned False;",
                  "    dependent tools will be unavailable this turn",
                  "2026-09-22 20:39:11,120 INFO tui_gateway.server: session resumed (ios)"]
        return 200, {"lines": lines}
    if base == "/api/files/upload":
        return 200, {"ok": True, "path": "(mock)"}
    if base.startswith("/api/"):
        return 200, {}
    return None


RESTART: dict = {}
ROOMS: list = []
ROOM_LOGS: dict = {}


def process_request(connection, request):
    path = request.path
    if path.split("?")[0] == "/api/ws":
        return None  # let the WebSocket handshake proceed
    query = {}
    if "?" in path:
        for pair in path.split("?", 1)[1].split("&"):
            k, _, v = pair.partition("=")
            query[k] = v
    method = getattr(request, "method", "GET") or "GET"
    base = path.split("?")[0]
    if method == "PATCH" and base.startswith("/api/sessions/"):
        # Title rename from the chat info sheet; the body is not readable here (websockets only
        # hands us headers), so echo a plausible title so the sheet's "saved" path is exercised.
        sid = base.split("/")[3]
        row = next((r for r in STORED_SESSIONS if r["id"] == sid), None)
        result = (200, {"ok": True, "title": row["title"] if row else ""})
    else:
        result = rest(path, query)
    status, payload = result if result else (404, {"detail": "Not found"})
    body = json.dumps(payload).encode()
    return Response(status, "OK", Headers([("Content-Type", "application/json"),
                                           ("Content-Length", str(len(body)))]), body)


# ── WebSocket JSON-RPC ────────────────────────────────────────────────────────────────────────


class Session:
    """A live session, shared by every socket that resumed it — like the real gateway, where a
    session's events and requests go to every attached client (a fan-out), and a mid-turn
    resume returns the rows flushed so far plus what is still inflight."""
    def __init__(self, sid: str, stored: str, title: str, profile: str) -> None:
        self.sid, self.stored, self.title, self.profile = sid, stored, title, profile
        self.output_tokens = 0
        self.members: set = set()          # Gateways attached to this session
        self.history: list[dict] = []      # rows flushed so far (user/assistant/tool)
        self.inflight: dict | None = None  # {user, assistant, streaming} while a turn runs
        self.running = False
        self.turn_started_at = 0.0
        self.pending: dict[str, asyncio.Future] = {}   # open server→client requests
        self.open_frames: dict[str, dict] = {}         # their frames, replayed on resume


PROJECTS: list[dict] = [
    {"id": "p_1a2b3c4d", "slug": "acme", "name": "Acme", "description": None, "icon": "rocket", "color": "hsl(30 70% 50%)",
     "board_slug": None, "primary_path": "/srv/app", "archived": False, "created_at": int(time.time()) - 86400,
     "folders": [{"path": "/srv/app", "label": None, "is_primary": True, "added_at": int(time.time()) - 86400}]},
    {"id": "p_5e6f7a8b", "slug": "homelab", "name": "Homelab", "description": None, "icon": None, "color": "hsl(210 70% 50%)",
     "board_slug": None, "primary_path": "/home/hermes/homelab", "archived": False, "created_at": int(time.time()) - 3600,
     "folders": [{"path": "/home/hermes/homelab", "label": None, "is_primary": True, "added_at": int(time.time()) - 3600}]},
]
PROJECT_META: dict = {"active_id": None}
if len(STORED_SESSIONS) > 1:
    STORED_SESSIONS[1]["cwd"] = "/home/hermes/homelab"

LIVE: dict[str, Session] = {}   # by runtime id


class Gateway:
    def __init__(self, ws) -> None:
        self.ws = ws
        self.sessions: dict[str, Session] = {}
        self.pending: dict[str, asyncio.Future] = {}

    async def send(self, frame: dict) -> None:
        await self.ws.send(json.dumps(frame))

    async def event(self, kind: str, sid: str, payload: dict | None = None) -> None:
        params = {"type": kind, "session_id": sid}
        if payload is not None:
            params["payload"] = payload
        frame = {"jsonrpc": "2.0", "method": "event", "params": params}
        live = LIVE.get(sid)
        if live is not None and live.inflight is not None:
            if kind == "message.delta":
                live.inflight["assistant"] = live.inflight.get("assistant", "") + str((payload or {}).get("text", ""))
            elif kind == "tool.complete":
                live.history.append({"role": "tool", "name": (payload or {}).get("name", "tool"), "text": (payload or {}).get("summary", ""),
                                     "timestamp": time.time(), "row_id": len(live.history) + 1})
        targets = list(live.members) if live is not None and live.members else [self]
        for m in targets:
            try:
                await m.send(frame)
            except Exception:  # noqa: BLE001
                if live is not None:
                    live.members.discard(m)

    async def ask(self, method: str, sid: str, params: dict, timeout: float = 300) -> dict | None:
        """Server -> client request to EVERY attached client; the first answer settles it."""
        rid = f"srq-{uuid.uuid4().hex[:12]}"
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        live = LIVE.get(sid)
        (live.pending if live is not None else self.pending)[rid] = fut
        self.pending[rid] = fut
        frame = {"jsonrpc": "2.0", "id": rid, "method": method, "params": {"session_id": sid, **params}}
        if live is not None:
            live.open_frames[rid] = frame
        for m in (list(live.members) if live is not None and live.members else [self]):
            try:
                await m.send(frame)
            except Exception:  # noqa: BLE001
                pass
        try:
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError:
            await self.event("request.cancel", sid, {"id": rid, "method": method, "reason": "timeout"})
            return None
        finally:
            self.pending.pop(rid, None)

    # -- streaming ----------------------------------------------------------------------------

    async def stream_words(self, s: Session, text: str, delay: float = 0.035) -> None:
        """Emit exact substrings, so the concatenated deltas equal the text a real gateway
        reports in message.complete."""
        i = 0
        while i < len(text):
            chunk = text[i:i + random.randint(3, 14)]
            i += len(chunk)
            await self.event("message.delta", s.sid, {"text": chunk})
            s.output_tokens += max(1, len(chunk) // 4)
            await asyncio.sleep(delay)

    async def run_turn(self, s: Session, prompt: str) -> None:
        s.running = True
        s.turn_started_at = time.time()
        s.inflight = {"user": prompt, "assistant": "", "streaming": True}
        try:
            await self._run_turn(s, prompt)
        finally:
            s.running = False
            s.inflight = None

    async def _run_turn(self, s: Session, prompt: str) -> None:
        await asyncio.sleep(0.4)
        if prompt.strip().lower().startswith("fail"):
            # The bot's provider needs a CLI the gateway does not have (a tester's Claude
            # subscription plugin): the gateway cannot start the turn.
            await self.event("error", s.sid, {"message": "Hermes could not start the assistant for this session. Details: Could not find the "
                             "'claude-subscription-directsdk-experimental' CLI command '(none configured)'. Install it.. "
                             "Check the model and provider with /model, or run `hermes setup` in a terminal to reconfigure."})
            return
        if prompt.strip().lower().startswith("interrupt"):
            # What a turn looks like after the gateway stopped it (Stop, or no app connected for
            # longer than its grace): the bot's message is the gateway's own sentence.
            await self.event("message.start", s.sid)
            await asyncio.sleep(0.6)
            text = "Operation interrupted: waiting for model response (12.4s elapsed)." if "model" in prompt.lower() else "Operation interrupted."
            await self.event("message.complete", s.sid, {"text": text, "status": "interrupted", "usage": usage(s.output_tokens, 1)})
            return
        await self.event("message.start", s.sid)
        await self.stream_words(s, REPLY_PART_1)
        await self.event("session.usage", s.sid, {"usage": usage(s.output_tokens)})

        tool_id = f"t-{uuid.uuid4().hex[:8]}"
        await self.event("tool.start", s.sid, {
            "tool_id": tool_id, "name": "terminal", "context": "du -sh /var/log/* | sort -rh | head",
            "args": {"command": "du -sh /var/log/* | sort -rh | head"}})
        await asyncio.sleep(1.4)
        await self.event("tool.complete", s.sid, {
            "tool_id": tool_id, "name": "terminal", "duration_s": 1.38,
            "summary": "10 entries, 4.2 GB total",
            "result_text": "2.1G\t/var/log/nginx\n1.4G\t/var/log/postgres\n0.7G\t/var/log/app\n"
                           "12M\t/var/log/syslog\n4.0M\t/var/log/auth.log\n"})

        # A todo list, as the todo tool files one: the app draws it as a checklist.
        todo_id = f"t-{uuid.uuid4().hex[:8]}"
        todos = {"todos": [{"id": "1", "content": "Measure /var/log and find the big rotated files", "status": "completed"},
                           {"id": "2", "content": "Propose the cleanup command and wait for approval", "status": "in_progress"},
                           {"id": "3", "content": "Run the cleanup and confirm the space is back", "status": "pending"},
                           {"id": "4", "content": "Add a logrotate rule so it does not grow again", "status": "pending"},
                           {"id": "5", "content": "Write the summary", "status": "pending"}]}
        await self.event("tool.start", s.sid, {"tool_id": todo_id, "name": "todo_list", "context": "5 items", "args": todos})
        await asyncio.sleep(0.3)
        await self.event("tool.complete", s.sid, {"tool_id": todo_id, "name": "todo_list", "duration_s": 0.0, "summary": "1 of 5 done", "result_text": ""})

        # A word to the other bot, the Bot Mode way: a quiet run of its CLI through the terminal
        # tool. The app shows it as "Messaged work", then "Message from work" when the reply lands.
        d_id = f"t-{uuid.uuid4().hex[:8]}"
        d_cmd = ("/home/hermes/.hermes/tools/python-3.14.7/bin/python3 /home/hermes/.hermes/hermes-agent/tools/bot_mode_dm.py --run-delivery "
                 "--author '{\"id\":\"default\"}' local /home/hermes/.hermes/profiles/default/cache/bot_dm/dm-hold-export.md "
                 "/home/hermes/.hermes/venv/bin/hermes -p work chat --in ~ -c 'Bot Chat' --create-if-missing -Q")
        await self.event("tool.start", s.sid, {"tool_id": d_id, "name": "terminal", "context": d_cmd[:120], "args": {"command": d_cmd, "background": True}})
        await asyncio.sleep(1.2)
        await self.event("tool.complete", s.sid, {
            "tool_id": d_id, "name": "terminal", "duration_s": 1.2, "summary": "Messaged work",
            "result_text": "session_id: 20260930_221000_work01\nGot it. The export is paused until you say go; I'll hold the 2 AM run too.\n"})

        await self.stream_words(s, REPLY_PART_2)
        await self.event("session.usage", s.sid, {"usage": usage(s.output_tokens)})
        await asyncio.sleep(0.3)

        answer = await self.ask("approval", s.sid, {
            "request_id": f"req-{uuid.uuid4().hex[:8]}",
            "command": "find /var/log -name '*.log.*' -mtime +90 -delete",
            "description": "Delete 34 rotated log files older than 90 days (4.2 GB) under /var/log",
            "tool_name": "terminal",
            "choices": ["once", "session", "always", "deny"],
            "allow_session": True, "allow_permanent": True})
        choice = (answer or {}).get("choice", "deny")

        if choice == "deny":
            await self.event("message.delta", s.sid, {
                "text": "\n\nUnderstood, I'll leave the files in place. "
                        "Say the word if you want a dry run instead."})
            text = (REPLY_PART_1 + REPLY_PART_2 + "\n\nUnderstood, I'll leave the files in place. "
                    "Say the word if you want a dry run instead.")
            s.history += [{"role": "user", "text": prompt, "timestamp": time.time(), "row_id": len(s.history) + 1},
                          {"role": "assistant", "text": text, "timestamp": time.time(), "row_id": len(s.history) + 2}]
            s.inflight = None
            await self.event("message.complete", s.sid, {"text": text, "status": "complete", "usage": usage(s.output_tokens, 2)})
            return

        tool2 = f"t-{uuid.uuid4().hex[:8]}"
        await self.event("tool.start", s.sid, {
            "tool_id": tool2, "name": "terminal",
            "context": "find /var/log -name '*.log.*' -mtime +90 -delete",
            "args": {"command": "find /var/log -name '*.log.*' -mtime +90 -delete"}})
        await asyncio.sleep(1.8)
        await self.event("tool.complete", s.sid, {
            "tool_id": tool2, "name": "terminal", "duration_s": 1.82,
            "summary": "34 files removed, 4.2 GB freed",
            "result_text": "removed 34 files\n/dev/sda1  470G  190G  257G  41% /\n"})

        await self.stream_words(s, "\n\n" + REPLY_PART_3)
        full = REPLY_PART_1 + REPLY_PART_2 + "\n\n" + REPLY_PART_3
        await self.event("session.title", s.sid, {"session_id": s.stored, "title": "Disk cleanup on the log host"})
        s.title = "Disk cleanup on the log host"
        s.history += [{"role": "user", "text": prompt, "timestamp": time.time(), "row_id": len(s.history) + 1},
                      {"role": "assistant", "text": full, "timestamp": time.time(), "row_id": len(s.history) + 2}]
        s.inflight = None
        await self.event("message.complete", s.sid, {
            "text": full, "status": "complete", "usage": usage(s.output_tokens, 2)})

    # -- dispatch -----------------------------------------------------------------------------

    async def handle(self, msg: dict) -> dict | None:
        # A response to one of OUR requests (approval / clarify / ...).
        if ("result" in msg or "error" in msg) and isinstance(msg.get("id"), str):
            fut = self.pending.get(msg["id"]) or next((l.pending[msg["id"]] for l in LIVE.values() if msg["id"] in l.pending), None)
            if fut and not fut.done():
                fut.set_result(msg.get("result") if "result" in msg else None)
            for l in LIVE.values():
                l.open_frames.pop(msg["id"], None)
            return None

        rid, method, p = msg.get("id"), msg.get("method", ""), msg.get("params") or {}
        profile = p.get("profile") or "default"

        def ok(result: dict) -> dict:
            return {"jsonrpc": "2.0", "id": rid, "result": result}

        def err(code: int, message: str) -> dict:
            return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}

        if method == "ping":
            return ok({"pong": True})
        if method == "profiles.list":
            return ok({"profiles": [{"name": "default", "is_default": True},
                                    {"name": "work", "is_default": False,
                                     "canonical_session": {"id": "20260930_221000_work01", "resolved_id": "20260930_221000_work01", "title": "Bot Chat", "message_count": 4}}]})
        if method == "session.active_list":
            return ok({"sessions": [{"id": l.sid, "session_key": l.stored, "title": l.title, "source": "ios",
                                     "status": "streaming" if l.running else "idle", "current": False}
                                    for l in LIVE.values()]})
        if method == "groups.capabilities":
            return ok({"protocol_version": 1, "driver": True, "methods": ["groups.list", "groups.create", "groups.send", "groups.log"]})
        if method == "groups.list":
            return ok({"rooms": ROOMS, "next_offset": None})
        if method == "groups.create":
            members = [{"member_id": f"m{i + 1}", "profile": m.get("profile"), "handle": m.get("handle") or m.get("profile"),
                        "display_name": (m.get("handle") or m.get("profile") or "").capitalize()} for i, m in enumerate(p.get("members") or [])] \
                or [{"member_id": "m1", "profile": "default", "handle": "hermes", "display_name": "Hermes"}]
            room = {"room_id": p.get("room_id") or f"room-{len(ROOMS) + 1}", "name": p.get("name") or "Room", "members": members,
                "updated_at": time.time(), "disbanded_at": None, "latest_seq": 0}
            ROOMS.append(room)
            return ok({"room": room})
        if method == "groups.send":
            # The real gateway insists on payload == {text, thread_id} and an identifier event_id.
            payload = p.get("payload") or {}
            if set(payload) != {"text", "thread_id"}:
                return err(-32602, "user payload is missing fields: thread_id" if "thread_id" not in payload else "unexpected payload fields")
            room_id = p.get("room_id"); log = ROOM_LOGS.setdefault(room_id, [])
            def ev(kind, actor, pl):
                log.append({"room_id": room_id, "seq": len(log) + 1, "event_id": f"evt-{uuid.uuid4().hex[:12]}",
                            "kind": kind, "actor": actor, "payload": pl, "created_at": time.time()})
            ev("message.user", {"kind": "user", "id": "user"}, {"text": payload["text"], "thread_id": "main"})
            ev("room.activity", {"kind": "system", "id": "room"}, {"status": "hermes is typing…"})
            sent = log[-2]
            # The member answers a few seconds later, as a real bot would; the app polls for it.
            def reply():
                ev("message.member", {"kind": "member", "id": "m1"}, {"text": f"Got it — **{payload['text']}**. On it.", "member_id": "m1", "thread_id": "main"})
                ev("room.activity", {"kind": "system", "id": "room"}, {"status": "settled"})
            asyncio.get_event_loop().call_later(4.0, reply)
            return ok({"event_id": sent["event_id"], "seq": sent["seq"]})
        if method == "groups.log":
            log = ROOM_LOGS.get(p.get("room_id"), [])
            since = int(p.get("since_seq") or 0)
            evs = [e for e in log if e["seq"] > since]
            return ok({"events": evs, "cursor": (evs[-1]["seq"] if evs else since), "latest_seq": len(log), "has_more": False})
        if method == "client.capabilities":
            return ok({"server_requests": ["approval", "clarify", "sudo", "secret",
                                           "vault.unlock_prompt", "vault.save_login", "vault.code"]})
        if method == "gateway.capabilities":
            return ok({"per_session_exclusive_submit": True})
        if method == "config.get":
            if p.get("key") == "profile":
                return ok({"home": "/home/hermes/.hermes", "display": profile})
            if p.get("key") == "project":
                # The bot's own working folder: where a chat goes when it leaves every project.
                return ok({"cwd": p.get("cwd") or "/home/hermes", "branch": None})
            return ok({"value": "", "config": CONFIG})
        if method == "session.create":
            sid, stored = uuid.uuid4().hex[:8], time.strftime("%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:6]
            s = Session(sid, stored, "New chat", profile)
            self.sessions[sid] = s
            if p.get("cwd"):
                # The real gateway writes the stored row on the first prompt; the mock files it now so
                # the project grouping can be seen at once.
                STORED_SESSIONS.insert(0, {"id": stored, "title": "New chat", "preview": "", "source": "ios", "model": MODEL,
                                           "started_at": time.time(), "last_active": time.time(), "message_count": 0, "is_active": True,
                                           "archived": False, "pinned": False, "profile": profile, "cwd": p["cwd"]})
            return ok({"session_id": sid, "stored_session_id": stored, "message_count": 0,
                       "messages": [], "info": session_info(s.title, False, profile)})
        if method in ("session.resume", "session.activate"):
            stored = p.get("session_id", "")
            if method == "session.resume":
                RESUMES.append({"session_id": stored, "profile": p.get("profile") or "", "at": time.time()})
                # What the real gateway does with a chat of the default store resumed under a
                # named bot: it moves the chat into that bot's store.
                moved = next((r for r in STORED_SESSIONS if r["id"] == stored), None)
                if moved is not None and (moved.get("profile") or "default") == "default" and (p.get("profile") or "default") != "default":
                    moved["profile"] = p["profile"]
                    print(f"[mock] adopted stranded session {stored} from default store into profile {p['profile']}", flush=True)
            live = next((l for l in LIVE.values() if l.stored == stored or l.sid == stored), None)
            if live is None:
                sid = uuid.uuid4().hex[:8]
                row = next((r for r in STORED_SESSIONS if r["id"] == stored), None)
                live = Session(sid, stored, row["title"] if row else "Chat", profile)
                if row and row["title"] == "Bot Chat":
                    # The other bot's own thread: what the first bot sent it, and what it said back.
                    live.profile = row["profile"]
                    live.history = [
                        {"role": "user", "text": "Message from 🤖 default: Heads up, I'm auditing the nightly export's query plan this week.", "timestamp": row["started_at"], "row_id": 1},
                        {"role": "assistant", "text": "Noted. The export runs at 2 AM; I'll leave the schedule alone until you're done.", "timestamp": row["started_at"] + 30, "row_id": 2},
                        {"role": "user", "text": "Message from 🤖 default: I'm about to clear the rotated logs on the log host. Hold your nightly export until I confirm.", "timestamp": row["last_active"] - 20, "row_id": 3},
                        {"role": "assistant", "text": "Got it. The export is paused until you say go; I'll hold the 2 AM run too.", "timestamp": row["last_active"], "row_id": 4},
                    ]
                elif row and row["id"] == "20260921_093355_d4e5f6":
                    # The export chat: a background job reported in while nobody was looking (the
                    # gateway puts that in the user's seat), and a cut tool preview.
                    live.history = [
                        {"role": "user", "text": "Why is the nightly export timing out?", "timestamp": row["started_at"], "row_id": 1},
                        {"role": "assistant", "text": REPLY_PART_1, "timestamp": row["started_at"] + 20, "row_id": 2},
                        {"role": "tool", "name": "terminal", "context": "python3 - <<'EOF'\nimport json, shutil\nrows=json.load(open('downloads.json'))\nfor r in rows: ...", "text": "39 of 40 remuxed", "timestamp": row["started_at"] + 60, "row_id": 3},
                        {"role": "user", "text": "[IMPORTANT: Background process proc_bb0091529c2c completed normally (exit code 0).\nCommand: cd /srv/app/_meta && python3 convert_to_mp4.py 2>&1 | tee convert_run.log\nOutput:\n...(first 1910 characters cut)\nremux 39/40 ok\nverify 39/40 ok]", "timestamp": row["last_active"] - 30, "row_id": 4},
                        {"role": "assistant", "text": REPLY_PART_3, "timestamp": row["last_active"], "row_id": 5},
                    ]
                elif row:
                    live.history = [
                        {"role": "user", "text": "The log host is at 94% disk. Can you take a look?",
                         "timestamp": row["started_at"], "row_id": 1},
                        {"role": "assistant", "text": REPLY_PART_1 + REPLY_PART_2 + "\n\n" + REPLY_PART_3,
                         "timestamp": row["last_active"], "row_id": 2},
                    ]
                    # MOCK_LONG=n: the same exchange n times over, for scroll-performance checks.
                    reps = int(os.environ.get("MOCK_LONG", "1") or 1)
                    if reps > 1:
                        base, live.history = live.history, []
                        for i in range(reps):
                            for m in base:
                                live.history.append({**m, "timestamp": m["timestamp"] - (reps - i) * 600, "row_id": len(live.history) + 1})
                LIVE[sid] = live
            live.members.add(self)
            self.sessions[live.sid] = live
            messages = [] if p.get("omit_messages") else list(live.history)
            result = {"session_id": live.sid, "stored_session_id": live.stored,
                      "message_count": len(live.history), "messages": messages,
                      "info": session_info(live.title, live.running, profile), "running": live.running,
                      "open_requests": [{"id": f["id"], "method": f["method"], "params": f["params"]} for f in live.open_frames.values()],
                      "resumed": stored, "turn_started_at": live.turn_started_at if live.running else None}
            if live.inflight is not None:
                result["inflight"] = dict(live.inflight)
            return ok(result)
        if method == "session.usage":
            s = self.sessions.get(p.get("session_id", ""))
            return ok(usage(s.output_tokens if s else 0, 1))
        if method == "session.context_breakdown":
            s = self.sessions.get(p.get("session_id", ""))
            used = usage(s.output_tokens if s else 0)["context_used"]
            return ok({"categories": [
                {"id": "system", "label": "System prompt", "tokens": 4_820, "color": "blue"},
                {"id": "tools", "label": "Tools", "tokens": 6_140, "color": "purple"},
                {"id": "skills", "label": "Skills", "tokens": 2_260, "color": "teal"},
                {"id": "memory", "label": "Memory", "tokens": 1_180, "color": "green"},
                {"id": "mcp", "label": "MCP", "tokens": 940, "color": "indigo"},
                {"id": "conversation", "label": "Conversation", "tokens": max(0, used - 15_340), "color": "orange"},
                {"id": "free", "label": "Free", "tokens": CONTEXT_MAX - used, "color": "gray"}],
                "context_max": CONTEXT_MAX, "context_percent": int(used / CONTEXT_MAX * 100),
                "context_used": used, "estimated_total": used, "context_estimated": False,
                "context_source": "models.dev", "model": MODEL, "context_files": []})
        if method == "session.workspace.move":
            # Re-home a stored chat: its folder decides which project it is in.
            row = next((r for r in STORED_SESSIONS if r["id"] == p.get("session_key")), None)
            if not p.get("session_key"):
                return err(4007, "session_key required")
            if not p.get("cwd"):
                return err(4016, "cwd required")
            if row is None:
                return err(4007, "session not found")
            if str(p["cwd"]).startswith("/nowhere"):
                return err(4017, f"working directory does not exist: {p['cwd']}")
            row["cwd"] = p["cwd"]
            print(f"moved {row['id']} to {p['cwd']}", flush=True)
            return ok({"cwd": p["cwd"], "branch": None, "git_repo_root": None})
        if method == "projects.list":
            return ok({"projects": PROJECTS, "active_id": PROJECT_META["active_id"]})
        if method == "projects.tree":
            nodes = [{"id": "__no_project__", "label": "Home", "isAuto": False, "isNoProject": True, "sessionCount": 0, "sessionIds": []}]
            for pr in PROJECTS:
                if pr["archived"]:
                    continue
                paths = [f["path"] for f in pr["folders"]]
                ids = [s["id"] for s in STORED_SESSIONS if any((s.get("cwd") or "").startswith(pth) for pth in paths)]
                nodes.append({"id": pr["id"], "label": pr["name"], "path": pr["primary_path"], "color": pr["color"], "isAuto": False,
                              "isNoProject": False, "sessionCount": len(ids), "sessionIds": ids})
            placed = {i for n in nodes[1:] for i in n["sessionIds"]}
            nodes[0]["sessionIds"] = [s["id"] for s in STORED_SESSIONS if s["id"] not in placed]
            return ok({"projects": nodes, "active_id": PROJECT_META["active_id"], "scoped_session_ids": []})
        if method == "projects.create":
            name = (p.get("name") or "").strip(); folders = p.get("folders") or []
            if not name or not folders:
                return err(5063, "name and at least one folder are required")
            if any(f["path"] == folders[0] for pr in PROJECTS for f in pr["folders"]):
                return err(5063, f"{folders[0]} already belongs to a project")
            pr = {"id": "p_" + uuid.uuid4().hex[:8], "slug": name.lower().replace(" ", "-"), "name": name, "description": p.get("description"),
                  "icon": p.get("icon"), "color": p.get("color"), "board_slug": None, "primary_path": folders[0], "archived": False,
                  "created_at": int(time.time()),
                  "folders": [{"path": f, "label": None, "is_primary": i == 0, "added_at": int(time.time())} for i, f in enumerate(folders)]}
            PROJECTS.append(pr)
            if p.get("use"):
                PROJECT_META["active_id"] = pr["id"]
            return ok({"project": pr})
        if method in ("projects.update", "projects.archive", "projects.delete", "projects.set_active", "projects.get"):
            pr = next((x for x in PROJECTS if x["id"] == p.get("id") or x["slug"] == p.get("id")), None)
            if method == "projects.set_active":
                PROJECT_META["active_id"] = pr["id"] if pr else None
                return ok({"active_id": PROJECT_META["active_id"]})
            if pr is None:
                return err(5062, "no such project")
            if method == "projects.get":
                return ok({"project": pr})
            if method == "projects.update":
                for k in ("name", "description", "icon", "color", "board_slug"):
                    if k in p:
                        pr[k] = p[k] or None
                return ok({"project": pr})
            if method == "projects.archive":
                pr["archived"] = not p.get("restore", False)
            else:
                PROJECTS.remove(pr)
                if PROJECT_META["active_id"] == pr["id"]:
                    PROJECT_META["active_id"] = None
            return ok({"projects": PROJECTS, "active_id": PROJECT_META["active_id"]})
        if method == "session.list":
            return ok({"sessions": [{"id": r["id"], "title": r["title"], "preview": r["preview"],
                                     "started_at": r["started_at"], "message_count": r["message_count"],
                                     "source": r["source"]} for r in STORED_SESSIONS]})
        if method == "session.title":
            s = self.sessions.get(p.get("session_id", ""))
            if s and p.get("title"):
                s.title = p["title"]
            return ok({"title": s.title if s else ""})
        if method == "commands.catalog":
            return ok({"pairs": [["new", "Start a new chat"], ["model", "Switch the model"],
                                 ["approve", "Approve the waiting command"], ["compress", "Compress the context"],
                                 ["status", "Show session status"], ["usage", "Show token usage"],
                                 ["agents", "Show the delegation tree"], ["rollback", "Restore a checkpoint"], ["cron", "Scheduled jobs"], ["academic-paper-acquisition", "Find and fetch papers"]],
                       "categories": [], "canon": {}, "commands": {"/cron": {"argument_mode": "text", "desktop": "terminal"}, "/usage": {"argument_mode": "text", "desktop": None}}, "skills": {"/academic-paper-acquisition": {"usage": 2}}, "skill_count": 3, "warning": ""})
        if method == "slash.exec":
            cmd = (p.get("command") or "").lstrip("/")
            name = cmd.split(" ", 1)[0]
            if name == "usage":
                return ok({"output": "Session Token Usage\n  input   12,480\n  output   3,112\n  cache    9,004\n  context  21.3k / 200k (10.6%)"})
            if name in ("my-skill", "academic-paper-acquisition"):
                return err(4018, f"skill command: use command.dispatch for /{name}")
            return ok({"output": f"(mock) /{cmd} ran on the gateway", "warning": "" if name != "personality" else "mirrored onto the live session"})
        if method == "command.dispatch":
            return ok({"type": "exec", "output": f"(mock) ran /{p.get('name', '')}"})
        if method == "prompt.submit":
            s = self.sessions.get(p.get("session_id", ""))
            if s is None:
                return {"jsonrpc": "2.0", "id": rid, "error": {"code": 4006, "message": "unknown session"}}
            asyncio.create_task(self.run_turn(s, str(p.get("text", ""))))
            return ok({"status": "streaming"})
        if method == "session.interrupt":
            return ok({"status": "interrupted", "interrupted": True})
        if method == "config.set":
            s = self.sessions.get(p.get("session_id", ""))
            return ok({"key": p.get("key", ""), "value": str(p.get("value", "")),
                       "info": session_info(s.title if s else "", False, profile)})
        if method in ("session.close", "session.delete"):
            self.sessions.pop(p.get("session_id", ""), None)
            return ok({"closed": True, "deleted": p.get("session_id", "")})
        if method == "approval.respond":
            return ok({"resolved": 1})
        if method == "approval.received":
            return ok({"acknowledged": True})
        if method in ("image.attach_bytes", "pdf.attach"):
            return ok({"attached": True, "filename": p.get("filename", "")})
        if method == "file.attach":
            return ok({"ref_text": f"[file: {p.get('name', 'file')}]"})
        return {"jsonrpc": "2.0", "id": rid,
                "error": {"code": -32601, "message": f"unknown method: {method}"}}


async def ws_handler(ws):
    gw = Gateway(ws)
    await gw.send({"jsonrpc": "2.0", "method": "event", "params": {
        "type": "gateway.ready", "session_id": "",
        "payload": {"skin": {"name": "default", "description": "", "colors": {}, "light_colors": {},
                             "dark_colors": {}, "branding": {}, "banner_logo": "", "banner_hero": "",
                             "tool_prefix": "", "help_header": ""},
                    "change_events": True, "replay_epoch": uuid.uuid4().hex[:8], "heartbeat": True}}})
    try:
        async for raw in ws:
            for line in str(raw).splitlines():
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                reply = await gw.handle(msg)
                if reply is not None:
                    await gw.send(reply)
    except Exception:
        pass
    finally:
        for live in LIVE.values():
            live.members.discard(gw)


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9119)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--token", default="mock-token")
    args = ap.parse_args()
    global TOKEN
    TOKEN = args.token
    print(f"mock Hermes gateway on http://{args.host}:{args.port}  (session token: {TOKEN})", flush=True)
    async with serve(ws_handler, args.host, args.port, process_request=process_request, max_size=None) as server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
