#!/usr/bin/env python3
"""hermes-push: APNs relay for the Hermes iOS app.

Runs next to YOUR Hermes install. It connects to your gateway's /api/ws as an ordinary
client, watches live sessions, and sends Apple Push Notifications to the devices that the
iOS app registered under <HERMES_HOME>/push/devices/*.json.

Pushes: approval waiting, clarify/secret question waiting, turn finished, turn error,
cron session finished. Live Activities registered by the app are ended when the turn ends.

Configuration (environment variables, all HERMES_PUSH_*):
  HERMES_PUSH_GATEWAY_URL          e.g. http://127.0.0.1:9119 (local) or https://hermes.example.com
  HERMES_PUSH_PUBLIC_URL           the URL the phone itself uses; carried in every push so the app can route it
  HERMES_PUSH_GATEWAY_TOKEN        dashboard session token (HERMES_DASHBOARD_SESSION_TOKEN) -- loopback / no auth gate
  HERMES_PUSH_GATEWAY_BEARER       OR a bearer access token for a gated gateway (from /auth/native/token)
  HERMES_PUSH_CF_ACCESS_CLIENT_ID / HERMES_PUSH_CF_ACCESS_CLIENT_SECRET   optional Cloudflare Access service token
  HERMES_PUSH_APNS_KEY_FILE        path to your AuthKey_XXXXXXXXXX.p8
  HERMES_PUSH_APNS_KEY_ID          the 10-char key id
  HERMES_PUSH_APNS_TEAM_ID         your Apple Developer team id
  HERMES_PUSH_APNS_TOPIC           the app's bundle id (default com.vorantx.vory)
  HERMES_PUSH_APNS_SANDBOX         1 for development builds (default: follow each device's apns_environment)
  HERMES_PUSH_DEVICES_DIR          default <HERMES_HOME>/push/devices
  HERMES_PUSH_POLL_SECONDS         session discovery / test-request interval (default 3)
  HERMES_PUSH_FINISH_EXPAND        1 to make the finish expand the Dynamic Island with an alert (default: the
                                   card just switches to "Finished" and the reply arrives as a notification)
  HERMES_PUSH_FINISH_ISLAND        seconds the finished card stays in the Dynamic Island (default 30)
  HERMES_PUSH_FINISH_LINGER        seconds it then stays on the Lock Screen before iOS removes it (default 60)

Dependencies: websockets, PyJWT, cryptography (all present in the Hermes venv).
"""
from __future__ import annotations

import asyncio
import glob
import hashlib
import json
import logging
import os
import ssl
import subprocess
import sys
import time
import re
import urllib.parse
import uuid
from pathlib import Path

try:
    import jwt  # PyJWT
    import websockets
except ImportError as exc:  # pragma: no cover
    sys.exit(f"missing dependency: {exc}. Run with the Hermes venv python or `pip install websockets pyjwt cryptography`.")

log = logging.getLogger("hermes-push")

# Keep in step with plugin/vory-push/plugin.yaml; the app compares the two.
VERSION = "1.0.37"
USER_AGENT = f"Vory-Push/{VERSION} (Hermes companion)"
try:
    # Fingerprint of the code actually running: the app compares it with the copy it ships, so a
    # reinstall without a gateway restart is caught even when the version number did not move.
    SCRIPT_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
except Exception:  # noqa: BLE001
    SCRIPT_SHA256 = ""


_CONF_PATH: Path | None = None
_CONF: dict[str, str] = {}


def _load_conf() -> None:
    """KEY=VALUE file named by HERMES_PUSH_CONFIG (or <HERMES_HOME>/push/hermes-push.conf when it
    exists). Environment variables win over the file. The Vory app writes this file."""
    global _CONF_PATH
    candidates = [os.environ.get("HERMES_PUSH_CONFIG", "").strip()]
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    candidates.append(str(home / "push" / "hermes-push.conf"))
    for c in candidates:
        if c and Path(c).expanduser().is_file():
            _CONF_PATH = Path(c).expanduser()
            for line in _CONF_PATH.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                _CONF[k.strip().removeprefix("export ").strip()] = v.strip().strip('"').strip("'")
            return


def env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or _CONF.get(name) or default).strip()


def save_conf_value(name: str, value: str) -> None:
    """Persist a rotated credential back to the config file (no-op without one)."""
    if _CONF_PATH is None:
        return
    lines = _CONF_PATH.read_text(encoding="utf-8").splitlines()
    out, done = [], False
    for line in lines:
        if line.split("=", 1)[0].strip().removeprefix("export ").strip() == name:
            out.append(f"{name}={value}"); done = True
        else:
            out.append(line)
    if not done:
        out.append(f"{name}={value}")
    _CONF_PATH.write_text("\n".join(out) + "\n", encoding="utf-8")
    _CONF[name] = value


# ── APNs ──────────────────────────────────────────────────────────────────────────────────────


def encrypt_for_device(device: dict, obj: dict) -> str | None:
    """AES-256-GCM with the key the app minted for this install (`payload_key`, base64). The relay
    forwards the ciphertext untouched; the app's notification extension opens it."""
    key_b64 = device.get("payload_key")
    if not key_b64:
        return None
    import base64, os as _os
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    key = base64.b64decode(key_b64)
    nonce = _os.urandom(12)
    ct = AESGCM(key).encrypt(nonce, json.dumps(obj, separators=(",", ":")).encode(), None)
    return base64.b64encode(nonce + ct).decode()


class APNs:
    """Delivery: through the developer's relay when the device registered with one (no APNs key
    needed here), otherwise straight to APNs over HTTP/2 via curl with your own key."""

    def __init__(self) -> None:
        self.key_file = env("HERMES_PUSH_APNS_KEY_FILE")
        self.key_id = env("HERMES_PUSH_APNS_KEY_ID")
        self.team_id = env("HERMES_PUSH_APNS_TEAM_ID")
        self.topic = env("HERMES_PUSH_APNS_TOPIC", "com.vorantx.vory")
        self.force_sandbox = env("HERMES_PUSH_APNS_SANDBOX") in {"1", "true", "yes"}
        self._jwt = ""
        self._jwt_at = 0.0
        #: What the relay / APNs answered last, for the app's test-notification diagnostics.
        self.last_response = ""
        self.direct = bool(self.key_file and self.key_id and self.team_id)
        self._key = Path(self.key_file).read_text(encoding="utf-8") if self.direct else ""
        if not self.direct:
            log.info("relay mode: no APNs key on this gateway, pushes go through the Vory relay")

    def send_via_relay(self, device: dict, *, alert: dict | None = None, push_type: str = "alert", collapse_id: str | None = None,
                       token_override: str | None = None, content_state: dict | None = None, event: str | None = None,
                       la_alert: dict | None = None, dismissal_date: int | None = None, attributes: dict | None = None) -> bool:
        relay = device.get("relay") or {}
        url, install_id, secret = relay.get("url", "").rstrip("/"), relay.get("install_id"), relay.get("secret")
        if not (url and install_id and secret):
            return False
        body: dict = {"install_id": install_id, "secret": secret, "push_type": push_type}
        if push_type == "alert":
            enc = encrypt_for_device(device, alert or {})
            if not enc:
                log.warning("device %s has a relay but no payload_key; skipping", device.get("device_id"))
                return False
            body.update({"enc": enc, "collapse_id": collapse_id, "thread_id": (alert or {}).get("thread_id", ""),
                         "interruption": (alert or {}).get("interruption", "active")})
        elif push_type == "sound":
            # A buzz with nothing to read: no banner, just the notification sound and haptic.
            body.update({"thread_id": (alert or {}).get("thread_id", ""), "collapse_id": collapse_id})
        elif push_type == "liveactivity":
            body.update({"token": token_override, "content_state": content_state or {}, "event": event or "update"})
            if attributes:
                body["attributes"] = attributes   # a push-to-start: the activity's fixed fields
            if la_alert:
                body["alert"] = la_alert   # plain words only: no extension can decrypt a Live Activity push
            if dismissal_date:
                body["dismissal_date"] = dismissal_date
        if self.dry_run:
            log.info("DRY-RUN relay %s %s → %s %s", push_type, device.get("device_name") or device.get("device_id"), url, json.dumps(body)[:200])
            return True
        import urllib.request, urllib.error
        req = urllib.request.Request(url + "/v1/push", method="POST", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", "User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                self.last_response = f"relay {r.status}: {r.read().decode('utf-8', 'replace')[:160]}"
                return r.status == 200
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")[:200]
            self.last_response = f"relay {exc.code}: {body}"
            log.warning("relay %s → %s %s", device.get("device_id"), exc.code, body)
            return False
        except Exception as exc:  # noqa: BLE001
            self.last_response = f"relay unreachable: {exc}"
            log.warning("relay call failed: %s", exc)
            return False

    def token(self) -> str:
        if time.time() - self._jwt_at > 45 * 60:
            self._jwt = jwt.encode({"iss": self.team_id, "iat": int(time.time())}, self._key, algorithm="ES256", headers={"kid": self.key_id})
            self._jwt_at = time.time()
        return self._jwt

    dry_run = False

    def send(self, device: dict, payload: dict, *, push_type: str = "alert", collapse_id: str | None = None, token_override: str | None = None) -> bool:
        if device.get("relay"):
            aps = payload.get("aps", {})
            if push_type == "alert":
                alert = {**(aps.get("alert") or {}), "category": aps.get("category", "HERMES_TURN"), "thread_id": aps.get("thread-id", ""),
                         "interruption": aps.get("interruption-level", "active"), "hermes": payload.get("hermes", {})}
                return self.send_via_relay(device, alert=alert, collapse_id=collapse_id)
            if push_type == "sound":
                return self.send_via_relay(device, push_type="sound", alert={"thread_id": aps.get("thread-id", "")}, collapse_id=collapse_id)
            if push_type == "liveactivity":
                # No extension can decrypt a Live Activity update, so only generic words travel.
                state = dict(aps.get("content-state") or {})
                state["detail"] = {"waiting": "Waiting for you", "done": "Turn finished", "error": "The turn failed", "thinking": "Thinking…",
                                   "streaming": "Writing…", "tool": "Running a tool…"}.get(state.get("phase"), "Working…")
                return self.send_via_relay(device, push_type="liveactivity", token_override=token_override, content_state=state, event=aps.get("event"),
                                           la_alert=aps.get("alert"), dismissal_date=aps.get("dismissal-date"), attributes=aps.get("attributes"))
            return self.send_via_relay(device, push_type=push_type)
        if not self.direct:
            return False
        sandbox = self.force_sandbox or device.get("apns_environment") == "development"
        host = "api.sandbox.push.apple.com" if sandbox else "api.push.apple.com"
        token = token_override or device.get("apns_token", "")
        if not token:
            return False
        # Each device file names the bundle it was built with (iOS, macOS and watchOS apps have
        # their own), so the topic follows the device rather than one global setting.
        topic = (device.get("bundle_id") or self.topic) + (".push-type.liveactivity" if push_type == "liveactivity" else "")
        if device.get("platform") == "watchos" and push_type == "complication":
            topic = (device.get("bundle_id") or self.topic) + ".complication"
        if self.dry_run:
            log.info("DRY-RUN %s %s → %s [%s] %s", push_type, device.get("device_name") or device.get("device_id"), host, topic, json.dumps(payload)[:300])
            return True
        cmd = ["curl", "-sS", "--http2", "-o", "-", "-w", "\n%{http_code}",
               "-H", f"authorization: bearer {self.token()}", "-H", f"apns-topic: {topic}",
               "-H", f"apns-push-type: {'alert' if push_type == 'sound' else push_type}", "-H", "apns-priority: 10", "-H", "apns-expiration: 0",
               "-H", "content-type: application/json"]
        if collapse_id:
            cmd += ["-H", f"apns-collapse-id: {collapse_id[:64]}"]
        cmd += ["-d", json.dumps(payload), f"https://{host}/3/device/{token}"]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        except Exception as exc:  # noqa: BLE001
            log.warning("apns curl failed: %s", exc)
            return False
        body, _, code = (out.stdout or "").rpartition("\n")
        if code != "200":
            log.warning("apns %s → %s %s", device.get("device_id"), code, body.strip())
            return False
        return True


# ── device registry ───────────────────────────────────────────────────────────────────────────


def devices_dir() -> Path:
    if d := env("HERMES_PUSH_DEVICES_DIR"):
        return Path(d).expanduser()
    home = Path(env("HERMES_HOME") or Path.home() / ".hermes")
    return home / "push" / "devices"


_dup_devices_logged: set = set()


# ── where a chat was last prompted from ───────────────────────────────────────────────────────
#
# Each app writes <push dir>/origins/<stored session id>.json = {device_id, platform, at} when it
# sends a prompt. A phone that asked to be quiet for chats driven from a Mac
# (`mute_desktop_origin` in its device file) is skipped for a session whose latest prompt came
# from a Mac within ORIGIN_WINDOW; replying from the phone writes the file again and takes the
# chat back. The test push and anything without a session go to every device.

ORIGIN_WINDOW = 12 * 3600
_origins_pruned_at = 0.0


def origins_dir() -> Path:
    return devices_dir().parent / "origins"


def session_origin(session_id: str) -> dict | None:
    """The origin marker for a stored session, when there is a recent one."""
    if not session_id:
        return None
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", session_id)
    p = origins_dir() / f"{safe}.json"
    try:
        o = json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None
    at = float(o.get("at") or 0)
    return o if time.time() - at < ORIGIN_WINDOW else None


def prune_origins() -> None:
    """Markers older than the window are dead weight; drop them, at most once an hour."""
    global _origins_pruned_at
    now = time.time()
    if now - _origins_pruned_at < 3600:
        return
    _origins_pruned_at = now
    for f in glob.glob(str(origins_dir() / "*.json")):
        try:
            if now - os.path.getmtime(f) > ORIGIN_WINDOW:
                os.remove(f)
        except OSError:
            pass
    prune_goals()
    prune_answers()


# ── what a working chat is after ──────────────────────────────────────────────────────────
#
# The app's Vory Summaries writes one line per working turn ("Finding why the export times
# out") and files it as <push dir>/goals/<stored session id>.json = {goal, device_id, at}. A Live
# Activity update replaces the card's whole state, so every update this companion pushes
# carries the line along, or the card would lose it the moment the app is suspended. The line
# belongs to one turn: only one written since the activity started counts.

#: How long the system keeps one Live Activity going. Past this it has ended it itself.
LA_MAX_AGE = 8 * 3600


def goals_dir() -> Path:
    return devices_dir().parent / "goals"


def session_goal(session_id: str, since: float = 0.0) -> str | None:
    """The goal line filed for a stored session, when it was written at or after ``since``."""
    if not session_id:
        return None
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", session_id)
    try:
        o = json.loads((goals_dir() / f"{safe}.json").read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None
    goal = o.get("goal") if isinstance(o, dict) else None
    at = float(o.get("at") or 0) if isinstance(o, dict) else 0.0
    if not isinstance(goal, str) or not goal.strip():
        return None
    # A few seconds of slack: the phone's clock and this machine's are not the same clock.
    if at < since - 5 or time.time() - at > LA_MAX_AGE:
        return None
    return goal.strip()[:160]


def prune_goals() -> None:
    """Goal lines of turns long over; dropped with the origin markers, at most once an hour."""
    now = time.time()
    for f in glob.glob(str(goals_dir() / "*.json")):
        try:
            if now - os.path.getmtime(f) > LA_MAX_AGE:
                os.remove(f)
        except OSError:
            pass


# ── who answered an approval ───────────────────────────────────────────────────────────────
#
# The app writes <push dir>/answers/<request id>.json = {device_id, session_id, at} when an
# approval is answered on it. The gateway tells nobody when an approval is answered, so this
# companion finds out by asking what is still pending; the marker then says which device
# needs no "answered" note of its own.

def answers_dir() -> Path:
    return devices_dir().parent / "answers"


def approval_answered_by(*request_ids: str) -> str | None:
    """The device that answered one of these request ids, when its marker is there."""
    for rid in request_ids:
        if not rid:
            continue
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", rid)
        try:
            o = json.loads((answers_dir() / f"{safe}.json").read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            continue
        if isinstance(o, dict) and o.get("device_id") and time.time() - float(o.get("at") or 0) < 3600:
            return str(o["device_id"])
    return None


def prune_answers() -> None:
    now = time.time()
    for f in glob.glob(str(answers_dir() / "*.json")):
        try:
            if now - os.path.getmtime(f) > 3600:
                os.remove(f)
        except OSError:
            pass


def pending_request_ids(reply) -> set | None:
    """The request ids in an ``approval.pending`` reply, or None when the reply is not a list
    (an older gateway answers with one approval, which says nothing about the others)."""
    if not isinstance(reply, dict):
        return None
    items = reply.get("approvals") if isinstance(reply.get("approvals"), list) else reply.get("pending") if isinstance(reply.get("pending"), list) else None
    if items is None:
        return None
    ids = set()
    for it in items:
        if isinstance(it, dict):
            ids |= {str(v) for v in (it.get("request_id"), it.get("id")) if v}
    return ids


def idle_long_enough(first_seen_idle: float | None, now: float, grace: float) -> bool:
    """A session counts as over only once it has been seen not running for ``grace`` seconds.
    One poll that misses it (the live list failed, the session was between two ids) is not that."""
    return first_seen_idle is not None and now - first_seen_idle >= grace


def load_devices(gateway_url: str) -> list[dict]:
    """Every registered device, one per APNs token. A phone that registered again under a new
    install id (a reinstall, a reset) leaves its old file behind with the same token, and each
    file used to get its own copy of every push: the newest registration wins, the rest are
    skipped and said so once."""
    rows = []
    for f in glob.glob(str(devices_dir() / "*.json")):
        try:
            d = json.loads(Path(f).read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            continue
        if d.get("platform") in {"ios", "macos", "watchos"} and d.get("apns_token"):
            rows.append((str(d.get("registered_at") or ""), os.path.getmtime(f), f, d))
    rows.sort(key=lambda r: (r[0], r[1]), reverse=True)
    out, seen = [], set()
    for _, _, f, d in rows:
        key = (d.get("platform"), d.get("apns_token"))
        if key in seen:
            if f not in _dup_devices_logged:
                _dup_devices_logged.add(f)
                log.info("device file %s repeats a token already registered under a newer id: skipped", Path(f).name)
            continue
        seen.add(key)
        out.append(d)
    return out


def describe_error(exc: BaseException) -> str:
    """One short line per failure cause, in words the app can show."""
    reason = getattr(exc, "reason", None)
    text = str(reason if reason is not None else exc)
    if "refused" in text.lower() or "Errno 111" in text or "Errno 61" in text:
        return "connection refused (nothing listens there on this machine)"
    if isinstance(exc, asyncio.TimeoutError) or "timed out" in text.lower():
        return "timed out"
    status = getattr(getattr(exc, "response", None), "status_code", None)
    if status:
        return f"WebSocket rejected with HTTP {status}"
    return text.strip("<>")[:160]


class ConfigChanged(Exception):
    """The app rewrote hermes-push.conf: reconnect with the new settings, no restart needed."""


class ReleaseIdle(Exception):
    """Every tracked session has been idle long enough: reconnect to drop the mirror memberships."""


class CodeChanged(Exception):
    """hermes_push.py on disk is no longer the code running: the host reloads or re-execs it."""


def code_changed() -> bool:
    try:
        return hashlib.sha256(Path(__file__).read_bytes()).hexdigest() != SCRIPT_SHA256
    except OSError:
        return False


def conf_mtime() -> float:
    try:
        return _CONF_PATH.stat().st_mtime if _CONF_PATH else 0.0
    except OSError:
        return 0.0


def status_path() -> Path:
    return devices_dir().parent / "status.json"


def write_status(**fields) -> None:
    """Heartbeat the app reads back (Settings › Background push) to show the companion is up
    and which version is actually running."""
    try:
        p = status_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({"version": VERSION, "script_sha256": SCRIPT_SHA256, "pid": os.getpid(), "updated_at": time.time(),
                                 "profile": os.environ.get("HERMES_PROFILE") or "default", **fields}), encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        log.debug("status write failed: %s", exc)


# ── gateway client ────────────────────────────────────────────────────────────────────────────


class Gateway:
    def __init__(self) -> None:
        #: Exactly the URL the user typed in the app; nothing else is tried.
        self.url = env("HERMES_PUSH_GATEWAY_URL").rstrip("/")
        if not self.url:
            sys.exit("set HERMES_PUSH_GATEWAY_URL")
        #: The URL the phone uses: pushes carry it so the app can route to the right connection.
        self.public_url = env("HERMES_PUSH_PUBLIC_URL").rstrip("/") or self.url
        #: How the last connection was made, for the status heartbeat.
        self.transport = ""
        self.token = env("HERMES_PUSH_GATEWAY_TOKEN")
        self.bearer = env("HERMES_PUSH_GATEWAY_BEARER")
        self.refresh_token = env("HERMES_PUSH_GATEWAY_REFRESH_TOKEN")
        # Cloudflare's bot rules answer 403 to the stock Python-urllib agent; name ourselves instead.
        self.headers: dict[str, str] = {"User-Agent": USER_AGENT}
        cid, csec = env("HERMES_PUSH_CF_ACCESS_CLIENT_ID"), env("HERMES_PUSH_CF_ACCESS_CLIENT_SECRET")
        if cid and csec:
            self.headers.update({"CF-Access-Client-Id": cid, "CF-Access-Client-Secret": csec})
        if self.bearer:
            self.headers["Authorization"] = f"Bearer {self.bearer}"
        elif self.token:
            self.headers["X-Hermes-Session-Token"] = self.token
        self.ws = None
        self._id = 0
        self._pending: dict[int, asyncio.Future] = {}
        self.events: asyncio.Queue = asyncio.Queue()

    def _http(self, method: str, path: str, body: dict | None = None, *, _retry: bool = True) -> dict:
        import urllib.error
        import urllib.request
        req = urllib.request.Request(self.url + path, method=method, headers={**self.headers, "Accept": "application/json", "Content-Type": "application/json"},
                                     data=json.dumps(body).encode() if body is not None else None)
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as exc:
            if exc.code == 401 and _retry and self.refresh_token and self.refresh():
                return self._http(method, path, body, _retry=False)
            raise

    def refresh(self) -> bool:
        """Rotate the bearer through /auth/native/refresh; the new refresh token is written back
        to the config file so the next restart still works."""
        import urllib.request
        req = urllib.request.Request(self.url + "/auth/native/refresh", method="POST",
                                     headers={k: v for k, v in self.headers.items() if k != "Authorization"} | {"Content-Type": "application/json"},
                                     data=json.dumps({"refresh_token": self.refresh_token}).encode())
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                data = json.loads(r.read().decode())
        except Exception as exc:  # noqa: BLE001
            log.warning("token refresh failed: %s", exc)
            return False
        access = data.get("access_token") or ""
        if not access:
            return False
        self.bearer = access
        self.headers["Authorization"] = f"Bearer {access}"
        if data.get("refresh_token"):
            self.refresh_token = data["refresh_token"]
            save_conf_value("HERMES_PUSH_GATEWAY_REFRESH_TOKEN", self.refresh_token)
        save_conf_value("HERMES_PUSH_GATEWAY_BEARER", access)
        log.info("gateway bearer refreshed")
        return True

    def _ws_for(self, base: str) -> tuple[str, str]:
        """WebSocket URL (with credential) for one base URL, plus how it authenticates. ``self.url``
        must already be ``base`` so the ticket request goes to the same place."""
        scheme = "wss" if base.startswith("https") else "ws"
        ws_base = scheme + base[base.index("://"):] + "/api/ws"
        if self.bearer:
            import urllib.error
            try:
                ticket = self._http("POST", "/api/auth/ws-ticket", {})["ticket"]
            except urllib.error.HTTPError as exc:
                body = exc.read().decode("utf-8", "replace")[:300].lower()
                hint = " (Cloudflare refused it — the companion needs the Access service token, or use a loopback URL)" if "cloudflare" in body or "cf-" in body \
                    else " (sign-in rejected — sign in for the companion again)" if exc.code in (401, 403) else ""
                raise RuntimeError(f"HTTP {exc.code} {exc.reason}{hint}") from None
            except urllib.error.URLError as exc:
                raise RuntimeError(describe_error(exc)) from None
            return f"{ws_base}?ticket={ticket}", "companion bearer"
        return f"{ws_base}?token={self.token}", "session token"

    async def connect(self) -> None:
        """Connect to the configured URL; the error says what that URL answered, for the app."""
        try:
            ready, how = await asyncio.to_thread(self._ws_for, self.url)
            kwargs = {"additional_headers": {k: v for k, v in self.headers.items() if not k.startswith("Authorization") and k != "X-Hermes-Session-Token"},
                      "max_size": 64 * 1024 * 1024}
            # A hung upgrade (tunnel, half-open socket) must not freeze the relay without a heartbeat.
            self.ws = await asyncio.wait_for(websockets.connect(ready, **kwargs), timeout=30)
        except Exception as exc:  # noqa: BLE001
            raise ConnectionError(f"{self.url}: {describe_error(exc)}") from None
        self.transport = f"{self.url} ({how})"
        asyncio.create_task(self._reader())
        # Advertise that server→client requests may be sent to this socket. The companion never
        # ANSWERS one (see _reader): the phone does, or the request waits in the gateway's
        # open_requests for the phone's next resume. Without this, an approval raised while the
        # phone is backgrounded and only the companion is attached would be withdrawn as
        # unanswerable instead of waiting — and the companion would never see it.
        await self.call("client.capabilities", {"server_requests": True})
        self.requests: asyncio.Queue = asyncio.Queue()

    async def _reader(self) -> None:
        try:
            async for raw in self.ws:
                for line in str(raw).splitlines():
                    if not line.strip():
                        continue
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if msg.get("method") == "event":
                        await self.events.put(msg.get("params") or {})
                    elif "id" in msg and isinstance(msg["id"], int) and (fut := self._pending.pop(msg["id"], None)):
                        if "error" in msg:
                            fut.set_exception(RuntimeError(msg["error"].get("message", "rpc error")))
                        else:
                            fut.set_result(msg.get("result") or {})
                    elif isinstance(msg.get("id"), str) and msg.get("method"):
                        # A server→client request (approval, clarify, …). Never answered from here:
                        # the gateway settles a request on the FIRST response, so an error reply
                        # would withdraw the phone's card. It is news for the phone, so it goes to
                        # the relay loop as a request event.
                        await self.events.put({"type": "__request__", "id": msg["id"], "method": msg["method"], "params": msg.get("params") or {}})
        except Exception as exc:  # noqa: BLE001
            log.warning("ws reader ended: %s", exc)
        await self.events.put({"type": "__closed__"})

    async def call(self, method: str, params: dict | None = None, timeout: float = 60) -> dict:
        self._id += 1
        fut = asyncio.get_running_loop().create_future()
        self._pending[self._id] = fut
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}}))
        return await asyncio.wait_for(fut, timeout)


# ── relay ─────────────────────────────────────────────────────────────────────────────────────


class Relay:
    def __init__(self) -> None:
        self.apns = APNs()
        self.gw = Gateway()
        self.attached: dict[str, dict] = {}   # runtime session id → {stored, title, profile, bot, source}
        self.labels: dict[str, str] = {}      # profile name → display name
        self.notified: set[str] = set()       # request ids already pushed
        self.poll = float(env("HERMES_PUSH_POLL_SECONDS", "3"))
        #: Seconds of nothing running before the mirrored sessions are released (see ReleaseIdle).
        self.release_after = float(env("HERMES_PUSH_RELEASE_IDLE_SECONDS", "600"))
        self._last_running_at = time.time()
        self.last_test: dict = {}                # last_test_nonce / last_test_devices / last_test_at, for the heartbeat
        self.last_la: dict = {}                  # what the last Live Activity push was and what the relay said

    def _status(self, **fields) -> None:
        write_status(**fields, **self.last_test, **self.last_la)

    def _note_la(self, event: str, ok: bool, detail: str | None = None) -> None:
        self.last_la = {"last_la_event": event, "last_la_ok": ok, "last_la_response": (detail if detail is not None else self.apns.last_response)[:300], "last_la_at": time.time()}

    def _la_skip(self, what: str, stored: str) -> None:
        """No phone qualified for a Live Activity push: say what each phone's device file looked like,
        so a token that never arrived or a session id that does not match is visible in the app."""
        seen = []
        for d in load_devices(self.gw.url):
            if d.get("platform") != "ios":
                continue
            entries = d.get("live_activities")
            if not isinstance(entries, list):
                entries = [{"session_id": d.get("live_activity_session_id"), "started_at": d.get("live_activity_started_at")}] if d.get("live_activity_token") else []
            name = (d.get('device_name') or d.get('device_id') or '?')[:14]
            if not entries:
                seen.append(f"{name}: no activity")
            for e in entries:
                sid = (e.get("session_id") if isinstance(e, dict) else None) or "-"
                age = int(time.time() - float((e.get("started_at") if isinstance(e, dict) else 0) or 0))
                seen.append(f"{name}: session={sid[:12]} age={age}s")
        self._note_la(f"skipped ({what}) for session {stored[:12]}", False, "; ".join(seen) or "no iOS device files")

    def _maybe_send_test(self) -> None:
        """The app drops `test-request.json` next to the config; answer it with one real push to every
        registered phone and note the nonce in the heartbeat so the app can tell 'sent' from 'arrived'."""
        p = status_path().with_name("test-request.json")
        if not p.exists():
            return
        try:
            req = json.loads(p.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            req = {}
        try:
            p.unlink()
        except OSError:
            pass
        nonce = str(req.get("nonce") or uuid.uuid4())
        sent = self.push_all("test", "Vory", "Test notification from your gateway ✓", {"nonce": nonce, "session_id": ""}, collapse="vory-test")
        self.last_test = {"last_test_nonce": nonce, "last_test_devices": sent, "last_test_at": time.time(), "last_test_detail": self.apns.last_response}
        self._status(connected=True, gateway=self.gw.public_url, transport=self.gw.transport, attached=len(self.attached), devices=len(load_devices(self.gw.url)))
        log.info("test notification %s sent to %d device(s)", nonce[:8], sent)

    def push_all(self, kind: str, title: str, body: str, meta: dict, collapse: str | None = None, skip: set | frozenset = frozenset(),
                 only: set | None = None, reached: set | None = None) -> int:
        """Returns how many devices accepted the push. ``skip`` names devices already reached another
        way (their Live Activity alerted), so they do not get a second buzz for the same thing.
        ``only`` limits it to those devices; ``reached`` collects the ids that accepted it. A
        "settled" push is quiet: it replaces an earlier banner (same collapse id) with a line
        that asks for nothing, without sound or waking the screen."""
        quiet = kind == "settled"
        payload = {
            "aps": {"alert": {"title": title, "body": body}, "thread-id": meta.get("session_id", ""),
                    "category": {"approval": "HERMES_APPROVAL", "clarify": "HERMES_CLARIFY", "error": "HERMES_ERROR", "settled": "HERMES_INFO"}.get(kind, "HERMES_TURN"),
                    "interruption-level": "passive" if quiet else "time-sensitive" if kind in {"approval", "clarify"} else "active"},
            "hermes": {"kind": kind, "gateway": self.gw.public_url, **meta},
        }
        if not quiet:
            payload["aps"]["sound"] = "default"
        # Apple caps a push at 4 KB and the relay encrypts this part: drop thread lines, then
        # shorten the text, until it fits comfortably.
        h = payload["hermes"]
        while len(json.dumps(h, ensure_ascii=False).encode()) > 2300:
            if h.get("thread"):
                h["thread"] = h["thread"][1:]
                if not h["thread"]:
                    h.pop("thread", None)
            elif len(h.get("text") or "") > 400:
                h["text"] = h["text"][:max(400, len(h["text"]) - 300)]
            else:
                break
        sent = 0
        origin = session_origin(str(meta.get("session_id") or ""))
        from_mac = bool(origin) and origin.get("platform") == "macos"
        prune_origins()
        for d in load_devices(self.gw.url):
            if d.get("platform") == "watchos" or d.get("device_id") in skip:
                continue  # the phone's alert is mirrored to the watch; a direct one would double up
            if only is not None and d.get("device_id") not in only:
                continue
            if from_mac and d.get("platform") == "ios" and d.get("mute_desktop_origin") and not quiet:
                log.info("push %s → %s: skipped, the chat is being driven from a Mac and this phone asked for quiet", kind, d.get("device_name") or d.get("device_id"))
                continue
            ok = self.apns.send(d, payload, collapse_id=collapse)
            sent += 1 if ok else 0
            if ok and reached is not None:
                reached.add(d.get("device_id"))
            log.info("push %s → %s: %s (%s)", kind, d.get("device_name") or d.get("device_id"), "sent" if ok else "FAILED", title[:60])
        self.refresh_complications()
        return sent

    _last_complication_push = 0.0

    def refresh_complications(self) -> None:
        """Ask watch complications to reload (budgeted by Apple at ~50/day, so at most one every
        three minutes here). The watch app fetches fresh state and reloads its timelines."""
        now = time.time()
        if now - self._last_complication_push < 180:
            return
        watches = [d for d in load_devices(self.gw.url) if d.get("platform") == "watchos"]
        if not watches:
            return
        self._last_complication_push = now
        for d in watches:
            self.apns.send(d, {"aps": {"content-available": 1}, "hermes": {"kind": "complication", "gateway": self.gw.public_url}}, push_type="complication")

    def live_activity_devices(self, stored: str, runtime_id: str = "") -> list[dict]:
        """Phones showing a Live Activity for this session right now: they get their news through it
        (the Island expands and buzzes) instead of a separate banner. The phone files the token under
        the STORED session id; the gateway sometimes only tells us the runtime id, so both count."""
        ids = {i for i in (stored, runtime_id) if i}
        out = []
        for d in load_devices(self.gw.url):
            if d.get("platform") != "ios":
                continue
            # App 1.1 (5)+ files every open activity under `live_activities` (one per running
            # chat); older apps file only the latest one in the single fields. Each match becomes
            # its own target with that activity's token, so two chats running at once each get
            # their own updates and end.
            entries = d.get("live_activities")
            if not isinstance(entries, list):
                entries = [{"session_id": d.get("live_activity_session_id"), "token": d.get("live_activity_token"),
                            "started_at": d.get("live_activity_started_at")}] if d.get("live_activity_token") else []
            for e in entries:
                if not isinstance(e, dict) or not e.get("token"):
                    continue
                if e.get("session_id") and e["session_id"] not in ids:
                    continue
                # Long work is the point: an activity is aimed at for as long as the system keeps
                # it (three hours here used to freeze the card of a long turn and lose its finish).
                if time.time() - float(e.get("started_at") or 0) > LA_MAX_AGE:
                    continue
                out.append({**d, "live_activity_token": e["token"], "live_activity_started_at": e.get("started_at"),
                            "live_activity_session_id": e.get("session_id")})
        return out

    def end_live_activities(self, stored: str, phase: str, bot: str = "Hermes", runtime_id: str = "", usage: dict | None = None) -> set:
        """Finish the activity in two steps: an update switches the card to "Finished"/"Failed" without
        expanding the Island (an ended activity leaves the Island at once, so it stays active for
        HERMES_PUSH_FINISH_ISLAND seconds), then an end push keeps it on the Lock Screen for
        HERMES_PUSH_FINISH_LINGER more seconds. The reply itself follows as a normal notification
        (sound, Reply action). Returns the ids of the devices reached."""
        now = int(time.time())
        reached = set()
        targets = self.live_activity_devices(stored, runtime_id)
        if not targets:
            self._la_skip(f"finish {phase}", stored)
        usage = usage if isinstance(usage, dict) else {}
        num = lambda v: int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None  # noqa: E731
        def secs(name: str, default: int) -> int:
            try:
                return max(0, int(float(env(name, str(default)))))
            except ValueError:
                return default
        island, linger = secs("HERMES_PUSH_FINISH_ISLAND", 30), secs("HERMES_PUSH_FINISH_LINGER", 60)
        for d in targets:
            state = {"phase": phase, "detail": "Turn finished" if phase == "done" else "The turn failed",
                     "outputTokens": num(usage.get("output")) or 0,
                     "contextPercent": num(usage.get("context_percent", usage.get("contextPercent"))),
                     "contextUsed": num(usage.get("context_used", usage.get("contextUsed"))),
                     "contextMax": num(usage.get("context_max", usage.get("contextMax"))), "needsAttention": False,
                     "startedAtUnix": float(d.get("live_activity_started_at") or now), "endedAtUnix": float(now)}
            aps = {"timestamp": now, "event": "update", "content-state": state}
            if env("HERMES_PUSH_FINISH_EXPAND") in {"1", "true", "yes"}:
                aps["alert"] = {"title": bot, "body": "Finished — tap to read the reply" if phase == "done" else "The turn failed — tap to see why", "sound": "default"}
            ok = self.apns.send(d, {"aps": aps}, push_type="liveactivity", token_override=d["live_activity_token"])
            self._note_la(f"finish update ({phase})", ok)
            if ok:
                reached.add(d.get("device_id"))
                self._schedule_end(d, state, island, linger)
            # No separate "end" push: when the phone holds pushes (idle, sandbox), only the latest state
            # gets applied and an end would swallow the alert. The finished card stays until the app is
            # opened, and the app ends it then.
        return reached

    def _schedule_end(self, device: dict, state: dict, island: int, linger: int) -> None:
        """Second step of the finish: after ``island`` seconds end the activity with a dismissal date
        ``linger`` seconds out, so it leaves the Island but stays on the Lock Screen a while longer."""
        def send_end() -> None:
            now = int(time.time())
            ok = self.apns.send(device, {"aps": {"timestamp": now, "event": "end", "content-state": state, "dismissal-date": now + linger}},
                                push_type="liveactivity", token_override=device["live_activity_token"])
            self._note_la(f"finish end (+{island}s, lingers {linger}s)", ok)
        try:
            asyncio.get_event_loop().call_later(island, send_end)
        except RuntimeError:
            send_end()

    #: activity token → when this companion ended it for a turn that was already over.
    _la_reaped: dict[str, float] = {}

    #: Whether the last discovery poll got the gateway's live list, and what was running in it.
    _live_ok = False
    _live_running: set = set()
    #: activity token → when its session was first seen not running (cleared when it runs again).
    _la_idle_since: dict[str, float] = {}
    #: Seconds a session must be seen not running, poll after poll, before its activity is ended.
    REAP_GRACE = 45.0

    def _moved_on_and_running(self, stored: str) -> bool:
        """A long turn that compressed its context carries on under a new stored id, while the
        phone's activity is still filed under the old one. True when the session's latest
        descendant is running."""
        try:
            q = "?" + urllib.parse.urlencode({"profile": self.session_profile[stored]}) if self.session_profile.get(stored) else ""
            latest = self.gw._http("GET", f"/api/sessions/{urllib.parse.quote(stored, safe='')}/latest-descendant{q}").get("session_id")
        except Exception:  # noqa: BLE001
            return False
        return bool(latest and latest != stored and latest in self._live_running)

    def reap_live_activities(self) -> int:
        """Ends the activities whose turn is over. The finish push needs the activity's own token,
        which the phone files only once it is awake and connected: a turn that started and ended
        while the app was closed (the companion started the activity by push) can file it late,
        after the finish went out to nobody. Runs after each discovery poll.

        It ends an activity only on what it knows: the gateway's live list must have been read
        this poll, and the session must have been seen not running for REAP_GRACE seconds on
        end. One failed read, a session not tracked yet, or a turn that moved to a new id after
        compressing used to count as "over", and the card of a turn still working vanished."""
        if not self._live_ok:
            return 0
        now = time.time()
        running: set[str] = set(self._live_running)
        for sid, a in self.attached.items():
            if (a.get("status") or "idle") not in ("idle", "", "done", "finished"):
                running |= {sid, a.get("stored") or sid}   # the phone files under the stored id, older ones under the runtime id
        ended = 0
        seen: set[str] = set()
        for d in load_devices(self.gw.url):
            if d.get("platform") != "ios":
                continue
            entries = d.get("live_activities")
            if not isinstance(entries, list):
                entries = [{"session_id": d.get("live_activity_session_id"), "token": d.get("live_activity_token"),
                            "started_at": d.get("live_activity_started_at")}] if d.get("live_activity_token") else []
            for e in entries:
                if not isinstance(e, dict) or not e.get("token") or e["token"] in self._la_reaped:
                    continue
                token = e["token"]
                seen.add(token)
                stored = e.get("session_id") or ""
                started = float(e.get("started_at") or 0)
                if stored in running or now - started < 120 or now - self._la_push_started.get(stored, 0) < 120:
                    self._la_idle_since.pop(token, None)
                    continue
                if now - started > LA_MAX_AGE:
                    continue   # the system has ended it, and the token is dead
                first = self._la_idle_since.setdefault(token, now)
                if not idle_long_enough(first, now, self.REAP_GRACE):
                    continue
                if self._moved_on_and_running(stored):
                    self._la_idle_since.pop(token, None)
                    continue
                state = {"phase": "done", "detail": "Turn finished", "outputTokens": 0, "contextPercent": None, "needsAttention": False,
                         "startedAtUnix": started or float(now), "endedAtUnix": float(now)}
                ok = self.apns.send(d, {"aps": {"timestamp": int(now), "event": "end", "content-state": state, "dismissal-date": int(now) + 60}},
                                    push_type="liveactivity", token_override=token)
                self._note_la("end (turn already over)", ok)
                self._la_reaped[token] = now
                self._la_idle_since.pop(token, None)
                ended += 1
                log.info("ended a Live Activity for %s whose turn was already over", stored[:12])
        for token in [t for t in self._la_idle_since if t not in seen]:
            self._la_idle_since.pop(token, None)
        if len(self._la_reaped) > 200:
            self._la_reaped = {t: at for t, at in self._la_reaped.items() if now - at < 86400}
        return ended

    #: stored session id → when a push-to-start went out for it (one per turn, not per event).
    _la_push_started: dict[str, float] = {}

    def start_live_activities(self, stored: str, runtime_id: str, state_patch: dict) -> int:
        """The app is closed and no phone shows an activity for this turn: start one by push on
        every phone that filed a push-to-start token (app 1.1 (13)+). The phone then publishes
        the new activity's own token and the usual updates and end follow. One start per turn."""
        if time.time() - self._la_push_started.get(stored, 0) < 600:
            return 0
        a = self.attached.get(runtime_id) or {"stored": stored}
        now = int(time.time())
        started = 0
        for d in load_devices(self.gw.url):
            if d.get("platform") != "ios":
                continue
            token = d.get("live_activity_push_to_start_token")
            if not token:
                continue
            entries = d.get("live_activities") or []
            if any(isinstance(e, dict) and e.get("token") and e.get("session_id") in (stored, runtime_id) for e in entries):
                continue   # this phone already shows one
            profile = a.get("profile") or "default"
            bot = (d.get("bots") or {}).get(profile) or {}
            attrs = {"sessionTitle": a.get("title") or "Hermes", "storedSessionID": stored, "connectionID": d.get("connection_id") or "",
                     "profile": profile, "model": "", "tintHex": bot.get("hex") or "",
                     "botName": bot.get("label") or a.get("bot") or profile, "avatar": bot.get("avatar") or ""}
            state = {"phase": "thinking", "detail": "Thinking…", "outputTokens": 0, "contextPercent": None, "needsAttention": False,
                     "startedAtUnix": float(now), "endedAtUnix": None, **state_patch}
            aps = {"timestamp": now, "event": "start", "content-state": state, "attributes-type": "HermesTurnAttributes", "attributes": attrs}
            ok = self.apns.send(d, {"aps": aps}, push_type="liveactivity", token_override=token)
            self._note_la("start", ok)
            if ok:
                started += 1
        if started:
            self._la_push_started[stored] = time.time()
            log.info("started %d Live Activity(ies) by push for %s", started, stored[:12])
        return started

    def update_live_activities(self, stored: str, state_patch: dict, alert: dict | None = None, runtime_id: str = "") -> set:
        """Mid-turn update (tool running, waiting for you): only what the companion can know. With
        ``alert`` the Island expands and buzzes. Returns the ids of the devices reached."""
        now = int(time.time())
        reached = set()
        targets = self.live_activity_devices(stored, runtime_id)
        if not targets and state_patch.get("phase") in ("thinking", "streaming", "tool"):
            # Nothing to update: the app is closed. Start one where the phone allows it.
            self.start_live_activities(stored, runtime_id, state_patch)
            targets = self.live_activity_devices(stored, runtime_id)
        if not targets and alert:
            self._la_skip("alert update", stored)
        for d in targets:
            state = {"phase": "streaming", "detail": "Working…", "outputTokens": 0, "contextPercent": None, "needsAttention": False,
                     "startedAtUnix": float(d.get("live_activity_started_at") or now), "endedAtUnix": None, **state_patch}
            if "goal" not in state and (goal := session_goal(d.get("live_activity_session_id") or stored, float(d.get("live_activity_started_at") or 0))):
                state["goal"] = goal
            aps = {"timestamp": now, "event": "update", "content-state": state}
            if alert:
                aps["alert"] = {**alert, "sound": "default"}
            ok = self.apns.send(d, {"aps": aps}, push_type="liveactivity", token_override=d["live_activity_token"])
            self._note_la("update" + (" alert" if alert else ""), ok)
            if ok:
                reached.add(d.get("device_id"))
        return reached

    #: stored session id → profile name, from each profile's own session list (refreshed every minute).
    session_profile: dict[str, str] = {}
    _session_profile_at = 0.0

    #: profile name → its Bot Chat: {"id", "resolved_id", "message_count", "last_active"} (from profiles.list).
    bot_chats: dict[str, dict] = {}

    def _refresh_session_profiles(self, profiles: list, force: bool = False) -> None:
        """Which bot a stored session belongs to: the gateway's all-profiles session list tags
        every row with the store it came from (`/api/profiles/sessions?profile=all`), and each
        profile's Bot Chat (hidden from the lists) comes from profiles.list. The map is rebuilt,
        not merged: a session that moved stores must not keep its old bot. The live list carries
        no profile at all, so a guess from the polling loop is never used (a wrong profile on
        session.resume makes the gateway MOVE the chat into that profile's store)."""
        if not force and time.time() - self._session_profile_at < 60:
            return
        found: dict[str, str] = {}
        try:
            r = self.gw._http("GET", "/api/profiles/sessions?profile=all&order=recent&limit=200")
            for item in r.get("sessions") or []:
                if isinstance(item, dict) and item.get("id") and item.get("profile"):
                    found[str(item["id"])] = str(item["profile"])
        except Exception as exc:  # noqa: BLE001
            log.debug("all-profiles session list failed (%s); per-profile lists instead", exc)
            for name in profiles:
                if not name:
                    continue
                try:
                    r = self.gw._http("GET", f"/api/sessions?order=recent&limit=60&profile={urllib.parse.quote(name)}")
                except Exception as exc2:  # noqa: BLE001
                    log.debug("session list for %s failed: %s", name, exc2)
                    continue
                for item in r.get("sessions") or []:
                    if isinstance(item, dict) and item.get("id"):
                        found[str(item["id"])] = str(item.get("profile") or name)
        for name, bc in self.bot_chats.items():
            for key in ("id", "resolved_id"):
                if bc.get(key):
                    found[str(bc[key])] = name
        if found:
            self.session_profile = found
        self._session_profile_at = time.time()

    def _profile_by_probe(self, stored: str, profiles: list) -> str | None:
        """Last resort for an id no list carries: ask each profile's store for it."""
        for name in profiles:
            if not name:
                continue
            try:
                r = self.gw._http("GET", f"/api/sessions/{urllib.parse.quote(stored)}?profile={urllib.parse.quote(name)}")
                if isinstance(r, dict) and (r.get("id") or r.get("session")):
                    return name
            except Exception:  # noqa: BLE001
                continue
        return None

    def _note_bot_chats(self, listed: list) -> None:
        """Each profile's Bot Chat from profiles.list (`canonical_session`)."""
        for p in listed:
            name, cs = p.get("name"), p.get("canonical_session")
            if name and isinstance(cs, dict) and cs.get("id"):
                self.bot_chats[name] = {"id": cs.get("id"), "resolved_id": cs.get("resolved_id") or cs.get("id"),
                                        "message_count": cs.get("message_count") or 0, "last_active": cs.get("last_active") or 0}

    async def discover(self) -> None:
        try:
            listed = (await self.gw.call("profiles.list", {})).get("profiles", [])
            self.labels = {p["name"]: p.get("display_name") or p["name"] for p in listed if p.get("name")}
            profiles = [p.get("name") for p in listed] or [None]
            self._note_bot_chats(listed)
        except Exception:  # noqa: BLE001
            profiles = [None]
        self._refresh_session_profiles(profiles)
        await self._touch_profiles(profiles)
        # The live list is the same for every profile (the gateway ignores the param): once.
        try:
            live = (await self.gw.call("session.active_list", {})).get("sessions", [])
            self._live_ok = True
        except Exception as exc:  # noqa: BLE001
            log.debug("active_list failed: %s", exc)
            live = []
            self._live_ok = False
        # What is running, straight from the gateway's list and under both of a session's ids,
        # whether or not this companion tracks it yet: the reaper goes by this.
        self._live_running = set()
        for s in live:
            if (s.get("status") or "idle") not in ("idle", "", "done", "finished"):
                self._live_running |= {i for i in (s.get("id"), s.get("session_key"), s.get("stored_session_id")) if i}
        for _once in (True,):
            seen_live = {s.get("id") for s in live}
            for s in live:
                sid = s.get("id")
                if sid in self.attached:
                    self.attached[sid]["status"] = s.get("status") or ""
                    continue
                if not sid:
                    continue
                # NOT session.activate: activating makes this socket the session's attached client,
                # and the gateway then sends approval requests here (which this companion cannot
                # answer) instead of to the phone — "the attached client predates server→client
                # requests". Everything needed is in the live list, the per-profile REST list and
                # approval.pending, none of which attach.
                # The phone files its Live Activity token under the STORED id (the gateway's session_key).
                stored = s.get("session_key") or s.get("stored_session_id") or sid
                # Which bot: the tagged all-profiles list, then a probe of each store. Never a
                # guess: resuming with the wrong profile moves the chat into that store.
                if stored not in self.session_profile:
                    self._refresh_session_profiles(profiles, force=True)
                pname = self.session_profile.get(stored) or self._profile_by_probe(stored, profiles)
                if pname is None:
                    if len([p for p in profiles if p]) <= 1:
                        pname = next((p for p in profiles if p), None) or "default"
                    else:
                        log.info("not mirroring %s: no profile lists it yet", stored[:12])
                        continue
                params = {"profile": pname}
                self.attached[sid] = {"stored": stored, "title": s.get("title") or "Hermes", "profile": pname,
                                      "bot": self.labels.get(pname, pname), "source": s.get("source") or "",
                                      "status": s.get("status") or ""}
                log.info("tracking %s (%s, profile %s)", self.attached[sid]["title"], stored[:12], self.attached[sid]["profile"])
                # The gateway sends a session's events (message.delta, tool.start, session.usage,
                # message.complete, approval requests) ONLY to the clients attached to it. A
                # `session.resume` on a LIVE session attaches this socket ALONGSIDE the phone (a
                # fan-out), unlike `session.activate`, which rebinds the slot and used to steal the
                # phone's approval cards. `omit_messages` skips the transcript read.
                try:
                    r = await asyncio.wait_for(self.gw.call("session.resume", {**params, "session_id": stored, "cols": 80, "omit_messages": True}), timeout=8)
                    self.attached[sid]["mirrored"] = True
                    self._note_la("mirror " + stored[:12], True)
                    # The gateway's own word on the bot beats every list.
                    real = ((r or {}).get("info") or {}).get("profile_name") if isinstance(r, dict) else None
                    if real and real != pname:
                        self.attached[sid]["profile"] = real
                        self.attached[sid]["bot"] = self.labels.get(real, real)
                        self.session_profile[stored] = real
                except Exception as exc:  # noqa: BLE001
                    log.warning("could not mirror %s: %s (updates will lag until the next poll)", stored[:12], describe_error(exc))
                    if "not found" in str(exc).lower():
                        # A one-off run the gateway never kept (a scheduled task): nothing to mirror,
                        # and nothing wrong. Not shown as a failed push in the app.
                        log.debug("mirror %s: session not kept by the gateway", stored[:12])
                    else:
                        self._note_la("mirror " + stored[:12], False, str(exc)[:80])
                try:
                    pend = await asyncio.wait_for(self.gw.call("approval.pending", {**params, "session_id": sid}), timeout=3)
                except Exception:  # noqa: BLE001
                    pend = {}
                if isinstance(pend, dict):
                    items = pend.get("pending") or pend.get("approvals") or ([pend] if pend.get("request_id") else [])
                    for pa in items:
                        if isinstance(pa, dict) and pa.get("request_id"):
                            self.handle_request(sid, "queue-" + str(pa.get("request_id")), "approval", pa)

    def attached_all_idle(self) -> bool:
        """True when no tracked session reports a running status (the live list's `status`)."""
        return all((a.get("status") or "idle") in ("idle", "", "done", "finished") for a in self.attached.values())

    _touched_profiles: set = set()

    async def _touch_profiles(self, profiles: list) -> None:
        """The gateway's change watcher only covers a profile's store once some request named
        that profile: one cheap listing per profile, once, so sessions.changed fires for all."""
        for name in profiles:
            if not name or name in self._touched_profiles:
                continue
            try:
                await asyncio.wait_for(self.gw.call("session.list", {"profile": name, "title": "Bot Chat", "limit": 1}), timeout=5)
            except Exception:  # noqa: BLE001
                pass
            self._touched_profiles.add(name)

    #: (bot chat id, message_count) already pushed, and when a turn push went out per stored id.
    _bot_chat_pushed: dict[tuple, float] = {}
    _turn_pushed_at: dict[str, float] = {}
    _bot_chat_check_at = 0.0

    async def check_bot_chats(self) -> int:
        """A cron job delivered into a Bot Chat (`--deliver bot-chat:<profile>`) runs a turn there
        that no event announces when the chat is not live: the Bot Chat simply grows. Compare each
        profile's Bot Chat with the last look and push the new reply when the prompt that led to
        it was a cron delivery. Runs after each poll and on sessions.changed."""
        now = time.time()
        if now - self._bot_chat_check_at < 2:
            return 0
        self._bot_chat_check_at = now
        try:
            listed = (await self.gw.call("profiles.list", {})).get("profiles", [])
        except Exception:  # noqa: BLE001
            return 0
        before = dict(self.bot_chats)
        self._note_bot_chats(listed)
        pushed = 0
        for name, bc in self.bot_chats.items():
            old = before.get(name)
            rid = str(bc.get("resolved_id") or bc.get("id"))
            count = int(bc.get("message_count") or 0)
            if old is None or count <= int(old.get("message_count") or 0):
                continue
            key = (rid, count)
            if key in self._bot_chat_pushed or now - self._turn_pushed_at.get(rid, 0) < 20:
                continue
            msgs = self._messages(rid, name, 6)
            user = next((m for m in reversed(msgs) if m["role"] == "user"), None)
            reply = next((m for m in reversed(msgs) if m["role"] == "assistant"), None)
            if not user or not reply or not user["text"].startswith("[Cronjob "):
                continue
            m = re.match(r'\[Cronjob "([^"]+)"', user["text"])
            job = m.group(1) if m else "cron job"
            bot = self.labels.get(name, name)
            self._bot_chat_pushed[key] = now
            self.push_all("cron", f"{bot} · {job}", reply["text"][:300],
                          {"session_id": rid, "profile": name, "title": "Bot Chat", "text": reply["text"][:1200], "job": job}, collapse=f"cron-{rid}")
            log.info("cron delivery into %s's Bot Chat (%s): pushed", name, job)
            pushed += 1
        if len(self._bot_chat_pushed) > 200:
            self._bot_chat_pushed = {k: t for k, t in self._bot_chat_pushed.items() if now - t < 86400}
        return pushed

    def _messages(self, stored: str, profile: str | None, limit: int) -> list:
        """The last `limit` user/assistant messages of a stored session, oldest first."""
        try:
            q = f"/api/sessions/{urllib.parse.quote(stored)}/messages?order=latest&limit={limit}"
            if profile:
                q += "&profile=" + urllib.parse.quote(profile)
            snap = self.gw._http("GET", q)
        except Exception as exc:  # noqa: BLE001
            log.debug("messages fetch failed for %s: %s", stored[:12], exc)
            return []
        out = []
        for m in snap.get("messages") or []:
            if not isinstance(m, dict):
                continue
            role, text = m.get("role"), m.get("text") or m.get("content")
            if isinstance(text, list):   # content parts
                text = " ".join(str(part.get("text") or "") for part in text if isinstance(part, dict)).strip()
            if role in {"user", "assistant"} and isinstance(text, str) and text.strip():
                out.append({"role": role, "text": text.strip()})
        return out

    def meta(self, sid: str) -> dict:
        a = self.attached.get(sid, {})
        return {"session_id": a.get("stored", sid), "profile": a.get("profile", "default")}

    #: Approvals this companion announced and has not seen settled: push id → what was sent.
    open_approvals: dict[str, dict] = {}
    #: push id → when the gateway first stopped listing it as pending.
    _approval_missing_since: dict[str, float] = {}

    def settle_approval(self, rid: str, why: str = "answered") -> None:
        """An approval this companion announced is no longer waiting, and the phone may be asleep:
        its Live Activity leaves "Needs approval", and the banner that offered Approve is
        replaced, quietly, on every device that got one except the one that answered."""
        o = self.open_approvals.pop(rid, None)
        self._approval_missing_since.pop(rid, None)
        if not o:
            return
        sid, stored = o["sid"], o["stored"]
        a = self.attached.get(sid)
        if a and (a.get("status") or "idle") not in ("idle", "", "done", "finished"):
            phase = (self.la_phase.get(sid) or ("streaming", 0))[0]
            self.update_live_activities(stored, {**self.la_usage.get(sid, {}), "phase": phase, "needsAttention": False,
                                                 "detail": {"thinking": "Thinking…", "streaming": "Writing…", "tool": "Running a tool…"}.get(phase, "Working…")}, runtime_id=sid)
        by = approval_answered_by(o["req"], rid)
        targets = {d for d in o["banner"] if d and d != by}
        if targets:
            body = f"{o['title']}: answered on another device." if why == "answered" else f"{o['title']}: no longer waiting for an answer."
            self.push_all("settled", f"{o['bot']} · approval answered" if why == "answered" else o["bot"], body,
                          {**self.meta(sid), "request_id": o["req"]}, collapse=rid, only=targets)
        log.info("approval %s settled (%s): %d banner(s) replaced%s", rid[:16], why, len(targets), f", answered on {by}" if by else "")

    async def settle_answered(self) -> int:
        """Asks the gateway what is still pending for each session with an open approval, and
        settles the ones it no longer lists (seen missing on two polls, so the answering
        device's marker has had time to land)."""
        now = time.time()
        settled = 0
        by_sid: dict[str, list[str]] = {}
        for rid, o in self.open_approvals.items():
            if now - o["at"] > 4:
                by_sid.setdefault(o["sid"], []).append(rid)
        for sid, rids in by_sid.items():
            a = self.attached.get(sid)
            if a is None:
                for rid in rids:   # the session is gone: nothing can be waiting on it
                    self.settle_approval(rid, "gone"); settled += 1
                continue
            try:
                reply = await asyncio.wait_for(self.gw.call("approval.pending", {"profile": a.get("profile"), "session_id": sid}), timeout=3)
            except Exception:  # noqa: BLE001
                continue
            ids = pending_request_ids(reply)
            if ids is None:
                continue
            for rid in rids:
                o = self.open_approvals[rid]
                if o["req"] in ids or rid in ids or rid.removeprefix("queue-") in ids:
                    self._approval_missing_since.pop(rid, None)
                    continue
                first = self._approval_missing_since.setdefault(rid, now)
                if now - first >= 2:
                    self.settle_approval(rid); settled += 1
        return settled

    def handle_request(self, sid: str, rid: str, method: str, params: dict) -> None:
        if not rid or rid in self.notified:
            return
        self.notified.add(rid)
        a = self.attached.get(sid, {})
        title = a.get("title", "Hermes")
        bot = a.get("bot") or a.get("profile", "Hermes")
        if method == "approval":
            body = params.get("description") or params.get("command") or "A command is waiting for your decision"
            via_la = self.update_live_activities(a.get("stored", sid), {**self.la_usage.get(sid, {}), "phase": "waiting", "detail": str(body)[:80], "needsAttention": True},
                                                 alert={"title": bot, "body": "Approval needed — tap to answer. It waits for you."}, runtime_id=sid)
            banner: set = set()
            self.push_all("approval", f"{bot} · approval needed", f"{title}: {str(body)[:180]}", {**self.meta(sid), "request_id": params.get("request_id", rid)}, collapse=rid, skip=via_la, reached=banner)
            self.open_approvals[rid] = {"sid": sid, "stored": a.get("stored", sid), "req": str(params.get("request_id") or rid), "at": time.time(),
                                        "bot": bot, "title": title, "banner": banner}
        elif method == "clarify":
            q = params.get("question") or (params.get("questions") or [{}])[0].get("question") or "Hermes has a question"
            self.push_all("clarify", f"{bot} · question", f"{title}: {str(q)[:180]}", {**self.meta(sid), "request_id": rid}, collapse=rid)
        elif method in {"sudo", "secret", "vault.unlock_prompt", "vault.save_login", "vault.code"}:
            self.push_all("clarify", f"{bot} · input needed", f"{title}: {params.get('prompt') or method}", {**self.meta(sid), "request_id": rid}, collapse=rid)

    async def run(self) -> None:
        backoff = 1
        self._conf_loaded = conf_mtime()
        while True:
            try:
                if conf_mtime() != self._conf_loaded:
                    log.info("hermes-push.conf changed; reloading")
                    await self._reload_config()
                self._status(connected=False, gateway=self.gw.public_url, transport=self.gw.transport, error="connecting…")
                await self.gw.connect()
                log.info("connected to %s", self.gw.url)
                backoff = 1
                self.attached.clear()
                last_poll = 0.0
                while True:
                    if time.time() - last_poll > self.poll:
                        if code_changed():
                            raise CodeChanged()
                        if conf_mtime() != self._conf_loaded:
                            raise ConfigChanged()
                        await self.discover()
                        try:
                            self.reap_live_activities()
                        except Exception as exc:  # noqa: BLE001
                            log.debug("reap: %s", exc)
                        try:
                            await self.settle_answered()
                        except Exception as exc:  # noqa: BLE001
                            log.debug("settle approvals: %s", exc)
                        try:
                            await self.check_bot_chats()
                        except Exception as exc:  # noqa: BLE001
                            log.debug("bot chats: %s", exc)
                        self._maybe_send_test()
                        last_poll = time.time()
                        self._status(connected=True, gateway=self.gw.public_url, transport=self.gw.transport, attached=len(self.attached), devices=len(load_devices(self.gw.url)))
                    try:
                        ev = await asyncio.wait_for(self.gw.events.get(), timeout=self.poll)
                    except asyncio.TimeoutError:
                        continue
                    if ev.get("type") == "__closed__":
                        raise ConnectionError("socket closed")
                    if ev.get("type") == "__request__":
                        p = ev.get("params") or {}
                        self.handle_request(str(p.get("session_id") or ""), str(ev.get("id") or ""), str(ev.get("method") or ""), p)
                        continue
                    self.on_event(ev)
                    # A mirrored session stays live for as long as any client is attached — this
                    # socket included. When nothing tracked has run for a while, drop the socket
                    # (and with it every membership) so the gateway's idle reaper can do its job;
                    # the reconnect re-mirrors whatever is live.
                    if self.attached and time.time() - self._last_running_at > self.release_after and self.attached_all_idle():
                        raise ReleaseIdle()
            except ConfigChanged:
                log.info("hermes-push.conf changed; reloading")
                await self._reload_config()
                backoff = 1
            except ReleaseIdle:
                log.info("nothing has run for %ss; releasing the mirrored sessions", int(self.release_after))
                # The clock restarts here, or the first event after the reconnect (the resume's own
                # session.info, a sessions.changed) would release again at once: a reconnect loop
                # that flipped the heartbeat's `connected` and showed as "not running" in the app.
                self._last_running_at = time.time()
                try:
                    if self.gw.ws:
                        await self.gw.ws.close()
                except Exception:  # noqa: BLE001
                    pass
                backoff = 1
            except CodeChanged:
                log.info("hermes_push.py changed on disk; handing over to the new code")
                try:
                    if self.gw.ws:
                        await self.gw.ws.close()
                except Exception:  # noqa: BLE001
                    pass
                self._status(connected=False, gateway=self.gw.public_url, transport=self.gw.transport, error="reloading new code…")
                raise
            except Exception as exc:  # noqa: BLE001
                log.warning("disconnected: %s; retrying in %ss", exc, backoff)
                self._status(connected=False, gateway=self.gw.public_url, transport=self.gw.transport, error=str(exc)[:400])
                # Back off, but wake early when the app drops a new config in.
                for _ in range(backoff):
                    await asyncio.sleep(1)
                    if conf_mtime() != self._conf_loaded:
                        break
                backoff = min(30, backoff * 2)

    async def _reload_config(self) -> None:
        try:
            if self.gw.ws:
                await self.gw.ws.close()
        except Exception:  # noqa: BLE001
            pass
        _CONF.clear()
        _load_conf()
        while True:
            self._conf_loaded = conf_mtime()
            try:
                self.gw = Gateway()
                self.apns = APNs()
                return
            except SystemExit as exc:
                self._status(connected=False, gateway="", transport="", error=f"config incomplete: {exc}")
                await asyncio.sleep(self.poll)
                _CONF.clear()
                _load_conf()

    #: (stored id, text) of the last finish pushed, with when: the same reply announced again within
    #: a minute (the chat mirrored under two runtime ids, a replayed completion) is not pushed twice.
    _finish_pushed: dict[tuple, float] = {}

    async def _finish_turn(self, sid: str, a: dict, p: dict) -> None:
        """The turn's end: finish the Live Activity and send the reply as a notification. The reply
        window (long-press) shows `text` in full, the chat under `title`, and the exchanges that led
        up to it (`thread`, fetched here with a short timeout)."""
        title = a["title"]; bot = a.get("bot") or a.get("profile", "Hermes")
        err = p.get("error")
        stored = str(a.get("stored", sid))
        fkey = (stored, hashlib.sha1((str(p.get("text") or "") + str(err or "")).encode("utf-8", "replace")).hexdigest())
        now = time.time()
        if now - self._finish_pushed.get(fkey, 0) < 60:
            log.info("finish of %s already pushed (%s): skipped", stored[:12], sid[:8])
            self.end_live_activities(stored, "error" if err else "done", bot=bot, runtime_id=sid, usage=p.get("usage"))
            return
        self._finish_pushed[fkey] = now
        if len(self._finish_pushed) > 300:
            self._finish_pushed = {k: t for k, t in self._finish_pushed.items() if now - t < 600}
        # The Live Activity flips to Finished at once; the thread for the reply window is fetched
        # with a short cap so the notification is not held up by a slow gateway.
        self.end_live_activities(a["stored"], "error" if err else "done", bot=bot, runtime_id=sid, usage=p.get("usage"))
        try:
            thread = await asyncio.wait_for(self._recent_thread(sid, a), timeout=1.5)
        except asyncio.TimeoutError:
            thread = []
        if err:
            self.push_all("error", f"{bot} · turn failed", f"{title}: {str(err)[:300]}",
                          {**self.meta(sid), "title": title, "text": str(err)[:1200], "thread": thread}, collapse=f"turn-{stored}")
        else:
            text = p.get("text") if isinstance(p.get("text"), str) else ""
            # A scheduled run's own session is named cron_<job>_<time> (the live list has no source).
            is_cron = a.get("source") == "cron" or str(a.get("stored", "")).startswith("cron_")
            label = "cron job finished" if is_cron else title
            self._turn_pushed_at[str(a.get("stored", sid))] = time.time()
            self.push_all("cron" if is_cron else "turn", f"{bot} · {label}" if is_cron else bot,
                          f"{title}: {(text or 'Done')[:300]}",
                          {**self.meta(sid), "title": title, "text": (text or "Done")[:1200], "thread": thread}, collapse=f"turn-{stored}")

    async def _recent_thread(self, sid: str, a: dict) -> list:
        """Up to three earlier messages of the session (user and assistant text only, shortened) for
        the notification's reply window. Empty when the gateway is slow or has none."""
        # REST, not session.activate: activating would make this socket the session's attached
        # client and steal the approval cards from the phone (see discover()).
        try:
            stored = a.get("stored", sid)
            q = f"/api/sessions/{urllib.parse.quote(stored)}/messages?order=latest&limit=12"
            if a.get("profile"):
                q += "&profile=" + urllib.parse.quote(a["profile"])
            snap = await asyncio.wait_for(asyncio.get_running_loop().run_in_executor(None, self.gw._http, "GET", q), timeout=1.4)
        except Exception as exc:  # noqa: BLE001
            log.debug("thread fetch failed for %s: %s", sid[:12], exc)
            return []
        out = []
        for m in snap.get("messages") or []:
            if not isinstance(m, dict):
                continue
            role, text = m.get("role"), m.get("text") or m.get("content")
            if role in {"user", "assistant"} and isinstance(text, str) and text.strip():
                out.append({"role": role, "text": text.strip()[:200]})
        # The final assistant reply is the notification itself; show what led up to it.
        if out and out[-1]["role"] == "assistant":
            out = out[:-1]
        return out[-3:]

    async def _attach_then_handle(self, sid: str, ev: dict) -> None:
        await self.discover()
        if sid in self.attached:
            self.on_event(ev)

    #: Live Activity phase last pushed per session, with when: (phase, time).
    la_phase: dict[str, tuple[str, float]] = {}
    _PHASE_EVENTS = {"message.start": "thinking", "reasoning.delta": "thinking", "thinking.delta": "thinking",
                     "message.delta": "streaming", "tool.start": "tool", "tool.generating": "tool", "tool.complete": "thinking"}

    #: latest usage seen per session (outputTokens / context), so every update carries the numbers.
    la_usage: dict[str, dict] = {}
    _la_usage_pushed: dict[str, float] = {}

    @staticmethod
    def _usage_patch(usage: dict | None) -> dict:
        if not isinstance(usage, dict):
            return {}
        num = lambda v: int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None  # noqa: E731
        patch = {"outputTokens": num(usage.get("output")) or 0,
                 "contextPercent": num(usage.get("context_percent", usage.get("contextPercent"))),
                 "contextUsed": num(usage.get("context_used", usage.get("contextUsed"))),
                 "contextMax": num(usage.get("context_max", usage.get("contextMax")))}
        return {k: v for k, v in patch.items() if v is not None}

    def _la_phase_event(self, sid: str, a: dict, phase: str) -> None:
        """Mirror the turn's phase into the phone's Live Activity (brain / speech bubble / wrench),
        only when it changes, so the stream of deltas costs one push per switch."""
        prev = self.la_phase.get(sid)
        if prev and prev[0] == phase:
            return
        self.la_phase[sid] = (phase, time.time())
        detail = {"thinking": "Thinking…", "streaming": "Writing…", "tool": "Running a tool…"}[phase]
        self.update_live_activities(a["stored"], {**self.la_usage.get(sid, {}), "phase": phase, "detail": detail}, runtime_id=sid)

    def _la_usage_event(self, sid: str, a: dict, usage: dict | None) -> None:
        """Token and context figures as the turn runs (at most one push every few seconds)."""
        patch = self._usage_patch(usage)
        if not patch:
            return
        self.la_usage[sid] = patch
        now = time.time()
        if now - self._la_usage_pushed.get(sid, 0) < 3:
            return
        self._la_usage_pushed[sid] = now
        phase = (self.la_phase.get(sid) or ("thinking", 0))[0]
        detail = {"thinking": "Thinking…", "streaming": "Writing…", "tool": "Running a tool…"}.get(phase, "Working…")
        self.update_live_activities(a["stored"], {**patch, "phase": phase, "detail": detail}, runtime_id=sid)

    def on_event(self, ev: dict) -> None:
        kind, sid, p = ev.get("type", ""), ev.get("session_id", ""), ev.get("payload") or {}
        a = self.attached.get(sid)
        if kind in self._PHASE_EVENTS or kind in ("session.usage", "message.complete"):
            self._last_running_at = time.time()
        if kind in self._PHASE_EVENTS and a:
            self._la_phase_event(sid, a, self._PHASE_EVENTS[kind])
            return
        if kind == "session.usage" and a:
            self._la_usage_event(sid, a, p.get("usage") if isinstance(p.get("usage"), dict) else p)
            return
        if kind == "sessions.changed":
            asyncio.create_task(self.check_bot_chats())
            return
        if kind == "message.complete" and not a and sid:
            # A chat that started since the last discovery poll: attach now so its finish still
            # ends the phone's Live Activity and sends the alert.
            asyncio.create_task(self._attach_then_handle(sid, ev))
            return
        if kind == "session.title" and a:
            a["title"] = p.get("title") or a["title"]
        elif kind == "message.complete" and a:
            self.la_phase.pop(sid, None)
            for rid in [r for r, o in self.open_approvals.items() if o["sid"] == sid]:
                self.settle_approval(rid)   # the turn is over: nothing of its can still be waiting
            if not isinstance(p.get("usage"), dict) and sid in self.la_usage:
                p = {**p, "usage": {"output": self.la_usage[sid].get("outputTokens"), "context_used": self.la_usage[sid].get("contextUsed"),
                                    "context_max": self.la_usage[sid].get("contextMax"), "context_percent": self.la_usage[sid].get("contextPercent")}}
            self.la_usage.pop(sid, None); self._la_usage_pushed.pop(sid, None)
            asyncio.create_task(self._finish_turn(sid, a, p))
        elif kind == "error" and a:
            self.push_all("error", f"{a.get('bot') or a.get('profile', 'Hermes')} · error", f"{a['title']}: {str(p.get('message', ''))[:180]}", self.meta(sid), collapse=f"err-{sid}")
        elif kind == "request.cancel":
            self.notified.discard(p.get("id", ""))
            if p.get("id", "") in self.open_approvals:
                self.settle_approval(p.get("id", ""), "withdrawn")
            # The ask was answered (from the phone, or elsewhere): the Live Activity stops asking.
            if a and self.la_phase.get(sid):
                phase = self.la_phase[sid][0]
                self.update_live_activities(a["stored"], {**self.la_usage.get(sid, {}), "phase": phase, "needsAttention": False,
                                                          "detail": {"thinking": "Thinking…", "streaming": "Writing…", "tool": "Running a tool…"}.get(phase, "Working…")}, runtime_id=sid)
        elif kind == "session.reclaimed":
            self.attached.pop(p.get("session_id", ""), None)


def main() -> None:
    import argparse
    _load_conf()
    ap = argparse.ArgumentParser(description="Relay Hermes gateway events to APNs for the Vory apps.")
    ap.add_argument("--list", action="store_true", help="print the registered devices and exit")
    ap.add_argument("--test", action="store_true", help="send one test alert to every registered device and exit")
    ap.add_argument("--dry-run", action="store_true", help="log what would be sent instead of calling APNs")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if args.list:
        gw = env("HERMES_PUSH_GATEWAY_URL").rstrip("/")
        devs = load_devices(gw)
        print(f"{len(devs)} device(s) in {devices_dir()}")
        for d in devs:
            print(f"  {d.get('platform'):8} {d.get('device_name') or d.get('device_id'):28} {d.get('bundle_id')}  env={d.get('apns_environment')}  live_activity={'yes' if d.get('live_activity_token') else 'no'}")
        return
    if args.test:
        apns = APNs(); apns.dry_run = args.dry_run
        gw = env("HERMES_PUSH_GATEWAY_URL").rstrip("/")
        devs = load_devices(gw)
        if not devs:
            sys.exit(f"no devices registered in {devices_dir()} — open Vory › Settings › Notifications › Register now first")
        if not apns.direct and not any(d.get("relay") for d in devs):
            sys.exit("no APNs key configured and no device registered with a relay")
        ok = 0
        for d in devs:
            ok += apns.send(d, {"aps": {"alert": {"title": "hermes-push is working", "body": "Background notifications from your gateway are live."}, "sound": "default"},
                               "hermes": {"kind": "test", "gateway": gw}}, collapse_id="hermes-push-test")
        print(f"sent to {ok}/{len(devs)} device(s)")
        sys.exit(0 if ok == len(devs) else 1)
    relay = Relay()
    relay.apns.dry_run = args.dry_run
    try:
        asyncio.run(relay.run())
    except CodeChanged:
        log.info("re-executing with the updated hermes_push.py")
        os.execv(sys.executable, [sys.executable] + sys.argv)


if __name__ == "__main__":
    main()
