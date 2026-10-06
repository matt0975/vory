#!/usr/bin/env python3
"""A stand-in for the Gemini Live API (ai.google.dev/gemini-api/docs/live-api), enough to run
Vory's Live conversation mode without a key or a network: the setup handshake, audio in, a
canned turn out (an ask_bot tool call, then the answer spoken as a tone with its transcript),
interruption when audio arrives while it talks, session resumption handles and goAway.

    python fake_gemini_live.py --port 9121 [--go-away 20] [--no-tool]

Point the app at it with the DEBUG launch argument `-vory-gemini-live-url ws://127.0.0.1:9121`.
Never put a real key anywhere near this file; it ignores the `key` query item.
"""
import argparse
import array
import asyncio
import base64
import json
import math
import time
import uuid

import websockets

INPUT_RATE = 16000
OUTPUT_RATE = 24000
HEARD = "What's filling up the disk on that host?"
SAID_BEFORE = "Let me check that for you."
SAID_AFTER = "Rotated logs, about four gigabytes. Shall I clear the ones older than ninety days?"


def tone(seconds: float, rate: int = OUTPUT_RATE) -> bytes:
    """Int16 mono with a speech-like cadence."""
    n = int(seconds * rate)
    out = array.array("h")
    for i in range(n):
        t = i / rate
        env = 0.5 * (1 + math.sin(2 * math.pi * 4 * t))
        fade = min(1.0, t / 0.05, (seconds - t) / 0.1)
        v = 0.35 * env * fade * (math.sin(2 * math.pi * 220 * t) + 0.4 * math.sin(2 * math.pi * 440 * t))
        out.append(int(max(-1.0, min(1.0, v)) * 32767))
    return out.tobytes()


def seconds_for(text: str) -> float:
    return min(10.0, 0.33 * max(1, len(text.split())) + 0.4)


class Conversation:
    def __init__(self, ws, args):
        self.ws = ws
        self.args = args
        self.heard_bytes = 0
        self.speaking = False
        self.interrupted = False
        self.turns = 0

    async def send(self, obj):
        await self.ws.send(json.dumps(obj))

    async def say(self, text: str) -> bool:
        """Speaks `text` as audio frames with its transcript; False when interrupted."""
        self.speaking = True
        self.interrupted = False
        await self.send({"serverContent": {"outputTranscription": {"text": text}}})
        pcm = tone(seconds_for(text))
        step = OUTPUT_RATE * 2 // 10  # 100 ms
        for i in range(0, len(pcm), step):
            if self.interrupted:
                self.speaking = False
                return False
            await self.send({"serverContent": {"modelTurn": {"parts": [{"inlineData": {
                "mimeType": f"audio/pcm;rate={OUTPUT_RATE}", "data": base64.b64encode(pcm[i:i + step]).decode("ascii")}}]}}})
            await asyncio.sleep(0.09)
        self.speaking = False
        return True

    async def turn(self):
        """What happens once the person has said something."""
        self.turns += 1
        await self.send({"serverContent": {"inputTranscription": {"text": HEARD}}})
        if self.args.no_tool:
            await self.say(SAID_AFTER)
            await self.send({"serverContent": {"turnComplete": True}})
            return
        call_id = f"call-{uuid.uuid4().hex[:8]}"
        await self.send({"toolCall": {"functionCalls": [{"id": call_id, "name": "ask_bot",
                                                         "args": {"request": HEARD, "context": ""}}]}})
        # Non-blocking: the model talks while the tool runs.
        await self.say(SAID_BEFORE)
        self.pending_call = call_id

    async def tool_answered(self, result: str):
        await self.say(SAID_AFTER if len(result) < 20 else result[:400])
        await self.send({"serverContent": {"turnComplete": True}})

    async def note_said(self, text: str):
        """A short model turn of its own (an acknowledgement), complete when said."""
        await self.say(text)
        await self.send({"serverContent": {"turnComplete": True}})

    async def run(self):
        setup = None
        self.pending_call = None
        go_away_at = time.time() + self.args.go_away if self.args.go_away else None
        async for raw in self.ws:
            if isinstance(raw, bytes):
                raw = raw.decode("utf-8", "replace")
            try:
                frame = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if "setup" in frame:
                setup = frame["setup"]
                handle = (setup.get("sessionResumption") or {}).get("handle")
                print(f"setup model={setup.get('model')} voice={(((setup.get('generationConfig') or {}).get('speechConfig') or {}).get('voiceConfig') or {}).get('prebuiltVoiceConfig', {}).get('voiceName')} "
                      f"tools={[d.get('name') for t in setup.get('tools', []) for d in t.get('functionDeclarations', [])]} resume={'yes' if handle else 'no'}", flush=True)
                await self.send({"setupComplete": {}})
                await self.send({"sessionResumptionUpdate": {"newHandle": handle or f"handle-{uuid.uuid4().hex[:8]}", "resumable": True}})
                continue
            if setup is None:
                continue
            if "realtimeInput" in frame:
                audio = (frame["realtimeInput"].get("audio") or {}).get("data")
                if audio:
                    n = len(audio) * 3 // 4
                    if self.speaking:
                        # Barge-in: the person talks over it.
                        self.heard_bytes += n
                        if self.heard_bytes > INPUT_RATE * 2 * 0.5:
                            self.interrupted = True
                            self.heard_bytes = 0
                            await self.send({"serverContent": {"interrupted": True}})
                        continue
                    self.heard_bytes += n
                    # About 1.2 s of audio counts as something said.
                    if self.heard_bytes >= INPUT_RATE * 2 * 1.2 and self.pending_call is None:
                        self.heard_bytes = 0
                        asyncio.create_task(self.turn())
                if frame["realtimeInput"].get("audioStreamEnd"):
                    self.heard_bytes = 0
            if "toolResponse" in frame:
                for r in frame["toolResponse"].get("functionResponses", []):
                    print(f"toolResponse id={r.get('id')} scheduling={(r.get('response') or {}).get('scheduling')} "
                          f"result={str((r.get('response') or {}).get('result'))[:60]!r}", flush=True)
                    if r.get("id") == self.pending_call:
                        self.pending_call = None
                        asyncio.create_task(self.tool_answered(str((r.get("response") or {}).get("result") or "")))
            if "clientContent" in frame:
                text = " ".join(p.get("text", "") for t in frame["clientContent"].get("turns", []) for p in t.get("parts", []))
                print(f"clientContent {text[:80]!r}", flush=True)
                asyncio.create_task(self.note_said("Okay. Please approve that on your screen; I'll go on once you have."
                                                   if "approval" in text.lower() else "Noted."))
            if go_away_at and time.time() > go_away_at:
                go_away_at = None
                await self.send({"goAway": {"timeLeft": "5s"}})
                await asyncio.sleep(2)
                await self.ws.close()
                return


async def handler(ws):
    print("connection", flush=True)
    try:
        await Conversation(ws, HANDLER_ARGS).run()
    except websockets.exceptions.ConnectionClosed:
        pass
    print("closed", flush=True)


HANDLER_ARGS = None


async def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=9121)
    p.add_argument("--go-away", type=float, default=0, help="send goAway and close after this many seconds")
    p.add_argument("--no-tool", action="store_true", help="answer without calling ask_bot")
    global HANDLER_ARGS
    HANDLER_ARGS = p.parse_args()
    async with websockets.serve(handler, "127.0.0.1", HANDLER_ARGS.port, max_size=16 * 1024 * 1024):
        print(f"fake Gemini Live on ws://127.0.0.1:{HANDLER_ARGS.port}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
