"""Unit tests for the companion (hermes_push.py and the plugin's single-instance lock).

No Hermes is imported or run: a fake gateway answers the companion's calls over a local
WebSocket, and Windows' msvcrt is a stand-in. Run from the repo root:

    PYTHONPATH=<a folder with websockets> python3 -m unittest discover -s server/hermes-push/tests

PyJWT (used only to sign APNs requests) is replaced by an empty module when it is not installed.
"""
from __future__ import annotations

import asyncio
import importlib.util
import json
import logging
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
os.environ.setdefault("HERMES_PUSH_GATEWAY_URL", "http://127.0.0.1:9")
if "jwt" not in sys.modules:
    try:
        import jwt  # noqa: F401
    except ImportError:
        sys.modules["jwt"] = types.ModuleType("jwt")
sys.path.insert(0, str(ROOT))
import hermes_push  # noqa: E402
import websockets  # noqa: E402


def load_plugin():
    """The plugin's __init__.py as a module of its own (its folder name has a hyphen)."""
    spec = importlib.util.spec_from_file_location("vory_push_plugin", ROOT / "plugin" / "vory-push" / "__init__.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeGateway:
    """Answers every call with an empty result, client.capabilities as told: "ok", "unknown"
    (JSON-RPC -32601), "unknown-text" (an error whose message says so, with no code) or "fail"."""

    def __init__(self, capabilities: str) -> None:
        self.capabilities = capabilities
        self.calls: list[str] = []

    async def handler(self, ws) -> None:
        async for raw in ws:
            msg = json.loads(raw)
            self.calls.append(msg["method"])
            if msg["method"] == "client.capabilities" and self.capabilities != "ok":
                err = {"unknown": {"code": -32601, "message": "Method not found"},
                       "unknown-text": {"message": "unknown method: client.capabilities"},
                       "fail": {"code": -32000, "message": "boom"}}[self.capabilities]
                await ws.send(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": err}))
            else:
                await ws.send(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {}}))


class CapabilitiesTests(unittest.IsolatedAsyncioTestCase):
    """#400: an older Hermes answers client.capabilities with "unknown method". The relay goes on
    without it, says once what is missing, and tells the app; any other failure still fails."""

    async def connect(self, capabilities: str):
        fake = FakeGateway(capabilities)
        server = await websockets.serve(fake.handler, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        gw = hermes_push.Gateway()
        gw._ws_for = lambda url: (f"ws://127.0.0.1:{port}/api/ws", "test")
        self.addAsyncCleanup(self.close, server, gw)
        return gw, fake

    async def close(self, server, gw) -> None:
        if gw.ws is not None:
            await gw.ws.close()
        server.close()
        await server.wait_closed()

    async def test_a_gateway_that_takes_it(self) -> None:
        gw, fake = await self.connect("ok")
        await gw.connect()
        self.assertTrue(gw.server_requests)
        self.assertEqual(fake.calls, ["client.capabilities"])
        # The connection goes on working.
        self.assertEqual(await gw.call("session.list"), {})

    async def test_an_older_gateway_is_not_fatal_and_says_so_once(self) -> None:
        for answer in ("unknown", "unknown-text"):
            with self.subTest(answer=answer):
                gw, _ = await self.connect(answer)
                with self.assertLogs("hermes-push", level="WARNING") as logs:
                    await gw.connect()
                self.assertIs(gw.server_requests, False)
                self.assertEqual(len(logs.records), 1)
                self.assertIn("Update Hermes", logs.output[0])
                self.assertEqual(await gw.call("session.list"), {})

    async def test_the_hint_is_not_repeated_on_a_reconnect(self) -> None:
        gw, _ = await self.connect("unknown")
        with self.assertLogs("hermes-push", level="WARNING"):
            await gw.connect()
        await gw.ws.close()
        logger = logging.getLogger("hermes-push")
        seen: list[logging.LogRecord] = []
        handler = logging.Handler()
        handler.emit = seen.append
        logger.addHandler(handler)
        try:
            await gw.connect()
        finally:
            logger.removeHandler(handler)
        self.assertEqual([r for r in seen if r.levelno >= logging.WARNING], [])

    async def test_any_other_failure_still_fails(self) -> None:
        gw, _ = await self.connect("fail")
        with self.assertRaises(hermes_push.RPCError) as caught:
            await gw.connect()
        self.assertEqual(caught.exception.code, -32000)

    def test_the_status_tells_the_app(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            status = Path(d) / "status.json"
            old = hermes_push.status_path
            hermes_push.status_path = lambda: status
            try:
                relay = hermes_push.Relay.__new__(hermes_push.Relay)
                relay.gw = types.SimpleNamespace(server_requests=False)
                relay.last_test, relay.last_la = {}, {}
                relay._status(connected=True)
            finally:
                hermes_push.status_path = old
            written = json.loads(status.read_text())
        self.assertIs(written["server_requests"], False)
        self.assertEqual(written["version"], hermes_push.VERSION)


class ReconnectTests(unittest.IsolatedAsyncioTestCase):
    """A reconnect closes the socket it replaces, and a socket released on purpose does not
    report "closed" after its replacement is up: that stale "closed" made the relay reconnect
    without closing the new socket, leaking one attached socket per idle release."""

    async def asyncSetUp(self) -> None:
        self.open: set = set()
        fake = FakeGateway("ok")

        async def handler(ws) -> None:
            self.open.add(ws)
            try:
                await fake.handler(ws)
            finally:
                self.open.discard(ws)

        self.server = await websockets.serve(handler, "127.0.0.1", 0)
        port = self.server.sockets[0].getsockname()[1]
        self.gw = hermes_push.Gateway()
        self.gw._ws_for = lambda url: (f"ws://127.0.0.1:{port}/api/ws", "test")

    async def asyncTearDown(self) -> None:
        await self.gw.close()
        self.server.close()
        await self.server.wait_closed()

    async def settle(self) -> None:
        for _ in range(50):
            await asyncio.sleep(0.01)

    async def test_a_released_socket_is_not_reported_closed(self) -> None:
        await self.gw.connect()
        await self.gw.close()  # ReleaseIdle / a config reload
        await self.gw.connect()
        await self.settle()
        self.assertTrue(self.gw.events.empty())
        self.assertEqual(len(self.open), 1)

    async def test_a_reconnect_closes_the_socket_it_replaces(self) -> None:
        await self.gw.connect()
        await self.gw.connect()
        await self.settle()
        self.assertEqual(len(self.open), 1)
        self.assertTrue(self.gw.events.empty())

    async def test_the_current_socket_closing_is_still_news(self) -> None:
        await self.gw.connect()
        for ws in list(self.open):
            await ws.close()
        ev = await asyncio.wait_for(self.gw.events.get(), timeout=2)
        self.assertEqual(ev["type"], "__closed__")


class FakeMsvcrt(types.ModuleType):
    """Windows' msvcrt, as far as the lock goes: one holder per file, LK_NBLCK raising OSError
    while another handle holds it."""
    LK_NBLCK, LK_UNLCK = 2, 0

    def __init__(self) -> None:
        super().__init__("msvcrt")
        self.held: dict[str, int] = {}

    def locking(self, fd: int, mode: int, nbytes: int) -> None:
        path = str(os.fstat(fd).st_ino)  # one file, whichever handle
        if mode == self.LK_NBLCK:
            if self.held.get(path, fd) != fd:
                raise OSError(36, "Resource deadlock avoided")
            self.held[path] = fd
        elif mode == self.LK_UNLCK and self.held.get(path) == fd:
            del self.held[path]


class SingleInstanceTests(unittest.TestCase):
    """#403: on Windows, which has no fcntl, the relay's lock is msvcrt's, so the dashboard and the
    gateway do not both run a relay (every push arrived twice)."""

    def setUp(self) -> None:
        self.saved = {k: sys.modules.get(k) for k in ("fcntl", "msvcrt")}
        sys.modules["fcntl"] = None  # import fcntl raises ImportError
        self.msvcrt = FakeMsvcrt()
        sys.modules["msvcrt"] = self.msvcrt
        self.plugin = load_plugin()
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "relay.lock"

    def tearDown(self) -> None:
        for k, v in self.saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v
        self.dir.cleanup()

    def test_one_holder_at_a_time_without_fcntl(self) -> None:
        first, second = open(self.path, "w"), open(self.path, "w")
        try:
            self.assertTrue(self.plugin._try_lock(first), "the first relay did not get the lock")
            self.assertFalse(self.plugin._try_lock(second), "a second relay got the lock too")
            self.msvcrt.locking(first.fileno(), FakeMsvcrt.LK_UNLCK, 1)
            self.assertTrue(self.plugin._try_lock(second), "the lock was not free once its holder let go")
        finally:
            first.close(); second.close()

    def test_the_claim_takes_the_lock_through_msvcrt(self) -> None:
        hp = types.SimpleNamespace(status_path=lambda: self.path.with_name("status.json"))
        self.assertTrue(self.plugin._claim_single_instance(hp))
        self.assertEqual(len(self.msvcrt.held), 1)

    def test_with_neither_lock_the_relay_runs(self) -> None:
        sys.modules["msvcrt"] = None
        with open(self.path, "w") as h:
            self.assertTrue(self.plugin._try_lock(h))


if __name__ == "__main__":
    unittest.main()


class ComplicationPushTests(unittest.TestCase):
    """#499: the Watch's complication refresh push, through the relay, carries no chat data. What the Companion posts
    to the relay is captured (no network): the install id, its secret and the push type, and nothing else, so neither
    the gateway's address nor any title, text or bot name leaves the gateway with it."""

    def test_a_relay_complication_push_carries_no_chat_data(self) -> None:
        posted: list[dict] = []

        class Answer:
            status = 200
            def read(self) -> bytes: return b'{"ok":true}'
            def __enter__(self): return self
            def __exit__(self, *a) -> None: return None

        def capture(req, timeout=None):
            posted.append(json.loads(req.data.decode()))
            return Answer()

        import urllib.request
        real = urllib.request.urlopen
        urllib.request.urlopen = capture
        try:
            apns = hermes_push.APNs()
            apns.dry_run = False
            device = {"device_id": "watch-1-watch", "platform": "watchos", "bundle_id": "com.vorantx.vory.watchkitapp",
                      "relay": {"url": "https://relay.test", "install_id": "w1", "secret": "s" * 48}}
            payload = {"aps": {"content-available": 1}, "hermes": {"kind": "complication", "gateway": "https://gateway.example",
                                                                   "title": "Rewrite the nightly export job", "bot": "Hermes"}}
            self.assertTrue(apns.send(device, payload, push_type="complication"))
        finally:
            urllib.request.urlopen = real
        self.assertEqual(len(posted), 1)
        self.assertEqual(posted[0], {"install_id": "w1", "secret": "s" * 48, "push_type": "complication"})
        text = json.dumps(posted[0])
        for word in ("gateway.example", "nightly", "Hermes", "title", "alert", "content_state", "attributes", "enc"):
            self.assertNotIn(word, text)


def _have_aesgcm() -> bool:
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: F401
        return True
    except ImportError:
        return False


class SealedLiveActivityTests(unittest.TestCase):
    """#497: in relay mode, for an app that opens sealed fields, a Live Activity push carries the goal line and the chat's
    names sealed with the install's key. What the Companion posts to the relay is captured (no network). Where the
    `cryptography` package is missing, a stand-in seals: it records what it was given and returns random bytes of the
    real length, so the fields' moves and the payload's size are still checked; the blobs are opened only with the real
    cipher."""

    KEY = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="   # bytes 0 to 31
    GOAL = "Finding why the nightly export times out"
    NAMES = {"sessionTitle": "Rewrite the nightly export job", "botName": "Archivist", "profile": "archivist",
             "tintHex": "#FF8800", "avatar": "animated:pebble"}
    PLAIN_STATE = {"phase", "detail", "outputTokens", "contextPercent", "contextUsed", "contextMax", "needsAttention",
                   "startedAtUnix", "endedAtUnix", "sealed"}
    FIXED_WORDS = {"Waiting for you", "Turn finished", "The turn failed", "Thinking…", "Writing…", "Running a tool…", "Working…"}

    def setUp(self) -> None:
        import base64, urllib.request
        self.posted: list[dict] = []
        self.sealed: list[dict] = []

        class Answer:
            status = 200
            def read(self) -> bytes: return b'{"ok":true}'
            def __enter__(self): return self
            def __exit__(self, *a) -> None: return None

        def capture(req, timeout=None):
            self.posted.append(json.loads(req.data.decode()))
            return Answer()

        self.real_urlopen, urllib.request.urlopen = urllib.request.urlopen, capture
        self.real_encrypt = hermes_push.encrypt_for_device
        if not _have_aesgcm():
            def stand_in(device: dict, obj: dict) -> str | None:
                if not device.get("payload_key"):
                    return None
                self.sealed.append(obj)
                plain = json.dumps(obj, separators=(",", ":")).encode()
                return base64.b64encode(os.urandom(12 + len(plain) + 16)).decode()
            hermes_push.encrypt_for_device = stand_in

    def tearDown(self) -> None:
        import urllib.request
        urllib.request.urlopen = self.real_urlopen
        hermes_push.encrypt_for_device = self.real_encrypt

    def device(self, sealed: bool = True) -> dict:
        d = {"device_id": "phone-1", "platform": "ios", "bundle_id": "com.vorantx.vory", "payload_key": self.KEY,
             "relay": {"url": "https://relay.test", "install_id": "i1", "secret": "s" * 48}}
        if sealed:
            d["la_sealed"] = 1
        return d

    def send(self, device: dict, aps: dict) -> dict:
        apns = hermes_push.APNs()
        apns.dry_run = False
        self.assertTrue(apns.send(device, {"aps": aps}, push_type="liveactivity", token_override="la-token"))
        return self.posted[-1]

    def opened(self, blob: str) -> dict:
        """A sealed field, opened: with the real cipher and the device's key, else what the stand-in was given."""
        if not _have_aesgcm():
            return self.sealed.pop(0)
        import base64
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        raw = base64.b64decode(blob)
        return json.loads(AESGCM(base64.b64decode(self.KEY)).decrypt(raw[:12], raw[12:], None))

    def update(self, **extra) -> dict:
        state = {"phase": "tool", "detail": "terminal: tail -n 200 /var/log/export.log", "outputTokens": 812, "contextPercent": 41,
                 "needsAttention": False, "startedAtUnix": 1792700000.0, "endedAtUnix": None, "goal": self.GOAL}
        return {"timestamp": 1792700100, "event": "update", "content-state": state, **extra}

    def start(self) -> dict:
        state = {"phase": "thinking", "detail": "Thinking…", "outputTokens": 0, "contextPercent": None, "needsAttention": False,
                 "startedAtUnix": 1792700000.0, "endedAtUnix": None, "goal": self.GOAL}
        attrs = {"storedSessionID": "3f6c2a1e9b", "connectionID": "C0FFEE00-0000-4000-8000-000000000001", "model": "", **self.NAMES}
        return {"timestamp": 1792700000, "event": "start", "content-state": state, "attributes-type": "HermesTurnAttributes", "attributes": attrs}

    def assert_no_names(self, body: dict) -> None:
        text = json.dumps(body, ensure_ascii=False)
        for word in ("nightly", "export", "Archivist", "archivist", "FF8800", "pebble", "tail -n", "/var/log"):
            self.assertNotIn(word, text)

    def test_an_update_seals_the_goal_and_keeps_only_fixed_words_plain(self) -> None:
        body = self.send(self.device(), self.update())
        state = body["content_state"]
        self.assertNotIn("goal", state)
        self.assertLessEqual(set(state), self.PLAIN_STATE)
        self.assertIn(state["detail"], self.FIXED_WORDS)
        self.assertEqual(self.opened(state["sealed"]), {"goal": self.GOAL})
        self.assert_no_names(body)

    def test_a_push_to_start_seals_the_names_and_keeps_the_ids_plain(self) -> None:
        body = self.send(self.device(), self.start())
        attrs = body["attributes"]
        for key in self.NAMES:
            self.assertEqual(attrs[key], "")
        self.assertEqual((attrs["storedSessionID"], attrs["connectionID"], attrs["model"]), ("3f6c2a1e9b", "C0FFEE00-0000-4000-8000-000000000001", ""))
        self.assertEqual(set(attrs), {*self.NAMES, "storedSessionID", "connectionID", "model", "sealed"})
        self.assertEqual(self.opened(body["content_state"]["sealed"]), {"goal": self.GOAL})
        self.assertEqual(self.opened(attrs["sealed"]), {"title": self.NAMES["sessionTitle"], "bot": "Archivist", "profile": "archivist",
                                                         "hex": "#FF8800", "avatar": "animated:pebble"})
        self.assert_no_names(body)

    def test_an_approvals_alert_is_titled_vory(self) -> None:
        alert = {"title": "Archivist", "body": "Approval needed. Tap to answer. It waits for you.", "sound": "default"}
        body = self.send(self.device(), self.update(alert=alert))
        self.assertEqual(body["alert"], {**alert, "title": "Vory"})
        self.assert_no_names(body)

    def test_an_app_that_does_not_open_sealed_fields_gets_todays_payload(self) -> None:
        alert = {"title": "Archivist", "body": "Approval needed. Tap to answer. It waits for you."}
        body = self.send(self.device(sealed=False), {**self.start(), "alert": alert})
        self.assertEqual(body["content_state"]["goal"], self.GOAL)
        self.assertNotIn("sealed", body["content_state"])
        self.assertEqual({k: body["attributes"][k] for k in self.NAMES}, self.NAMES)
        self.assertNotIn("sealed", body["attributes"])
        self.assertEqual(body["alert"]["title"], "Archivist")
        self.assertEqual(self.sealed, [])

    def test_direct_mode_is_unchanged(self) -> None:
        apns = hermes_push.APNs()
        apns.direct, apns.dry_run = True, True
        device = {k: v for k, v in self.device().items() if k != "relay"}
        with self.assertLogs(hermes_push.log, level="INFO") as logs:
            self.assertTrue(apns.send(device, {"aps": self.start()}, push_type="liveactivity", token_override="la-token"))
        # The dry run logs the payload's first 300 characters: the goal line is among them, plain, and nothing is sealed.
        self.assertTrue(any(self.GOAL in line for line in logs.output))
        self.assertFalse(any("sealed" in line for line in logs.output))
        self.assertEqual((self.posted, self.sealed), ([], []))

    def test_the_longest_push_to_start_fits_apples_limit(self) -> None:
        # The goal line at its longest (160 characters, each four bytes in UTF-8) and a 300-character chat title.
        aps = self.start()
        aps["content-state"]["goal"] = "😀" * 160
        aps["attributes"]["sessionTitle"] = "T" * 300
        aps["alert"] = {"title": "Archivist", "body": "Approval needed. Tap to answer. It waits for you.", "sound": "default"}
        body = self.send(self.device(), aps)
        # What the relay hands Apple: the aps dictionary rebuilt from the posted fields.
        forwarded = {"aps": {"timestamp": aps["timestamp"], "event": body["event"], "content-state": body["content_state"],
                             "attributes-type": "HermesTurnAttributes", "attributes": body["attributes"], "alert": body["alert"],
                             "dismissal-date": 1792790000}}
        size = len(json.dumps(forwarded, separators=(",", ":"), ensure_ascii=False).encode())
        self.assertLess(size, 4096, f"the push is {size} bytes")

    @unittest.skipUnless(_have_aesgcm(), "needs the cryptography package")
    def test_the_sealing_matches_the_apps_vector(self) -> None:
        # The sealer itself, with the nonce pinned, against the vector the app's PushRelayCryptoTests opens: a zero key,
        # a zero nonce and {"title":"hi","body":"there"}. Both sides agree byte for byte.
        import base64
        saved, os.urandom = os.urandom, (lambda n: bytes(n))   # the sealer draws its nonce from os.urandom
        try:
            blob = self.real_encrypt({"payload_key": base64.b64encode(bytes(32)).decode()}, {"title": "hi", "body": "there"})
        finally:
            os.urandom = saved
        self.assertEqual(blob, APP_VECTOR)


#: The vector in the app's PushRelayCryptoTests.decryptsCompanionVector (VoryTests/HermesRemoteTests.swift).
APP_VECTOR = "AAAAAAAAAAAAAAAAtYU0VDkMDkw9bK26mN+/eh0EeugNhF4ctNCQrAgnBvQ6vurB94SMNXCYlKJV"
