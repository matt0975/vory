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


class UnpromptedChatTests(unittest.IsolatedAsyncioTestCase):
    """A chat created and never prompted has no stored row; resuming its key makes the gateway
    write an empty one (Hermes #96793), which every list then shows. The relay leaves it alone
    until it has a message, and mirrors everything else as before."""

    def relay(self, live: list, stored_rows: list):
        relay = hermes_push.Relay.__new__(hermes_push.Relay)
        relay.attached, relay.labels, relay.notified = {}, {}, set()
        relay.last_test, relay.last_la = {}, {}
        relay.session_profile, relay._session_profile_at = {}, 0.0
        relay.bot_chats, relay._touched_profiles = {}, set()
        relay.apns = types.SimpleNamespace(last_response="")
        resumed: list[str] = []

        async def call(method, params=None):
            if method == "profiles.list":
                return {"profiles": [{"name": "default"}]}
            if method == "session.active_list":
                return {"sessions": live}
            if method == "session.resume":
                resumed.append(params["session_id"])
            return {}

        def http(verb, path):
            if path.startswith("/api/profiles/sessions"):
                return {"sessions": [{"id": i, "profile": "default"} for i in stored_rows]}
            raise RuntimeError("not found")

        relay.gw = types.SimpleNamespace(call=call, _http=http)
        return relay, resumed

    async def test_an_unprompted_chat_is_not_resumed(self) -> None:
        live = [{"id": "rt1", "session_key": "20261025_213336_d22bb4", "status": "idle", "message_count": 0, "title": "Hermes"}]
        relay, resumed = self.relay(live, stored_rows=[])
        await relay.discover()
        self.assertEqual(resumed, [])
        self.assertNotIn("rt1", relay.attached)

    async def test_chats_with_a_row_or_a_turn_are_mirrored(self) -> None:
        live = [{"id": "rt1", "session_key": "20261025_110000_aaaaaa", "status": "idle", "message_count": 0, "title": "Stored"},
                {"id": "rt2", "session_key": "20261025_120000_bbbbbb", "status": "running", "message_count": 0, "title": "First turn"},
                {"id": "rt3", "session_key": "20261025_130000_cccccc", "status": "idle", "message_count": 4, "title": "Talked"},
                {"id": "rt4", "session_key": "20261025_140000_dddddd", "status": "idle", "title": "Older gateway"}]
        relay, resumed = self.relay(live, stored_rows=["20261025_110000_aaaaaa"])
        await relay.discover()
        self.assertEqual(sorted(resumed), sorted(s["session_key"] for s in live))


if __name__ == "__main__":
    unittest.main()
