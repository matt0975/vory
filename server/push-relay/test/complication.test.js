// The Watch's complication refresh push (#499): whatever the gateway's Companion puts in the request,
// the relay sends Apple only {"aps":{"content-available":1}}, no chat data. Apple's endpoint is a
// stand-in (globalThis.fetch), and the APNs key is one made for the test.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

async function testKeyPEM() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  return "-----BEGIN PRIVATE KEY-----\n" + btoa(String.fromCharCode(...der)) + "\n-----END PRIVATE KEY-----";
}

function fakeKV() {
  const data = new Map();
  return {
    async get(key) { return data.get(key) ?? null; },
    async put(key, value) { data.set(key, value); },
    async delete(key) { data.delete(key); },
  };
}

const watch = {
  install_id: "f1e2d3c4-b5a6-4978-8a9b-0c1d2e3f4a5b",
  secret: "w".repeat(64),
  device_token: "ef".repeat(32),
  platform: "watchos",
  bundle_id: "com.vorantx.vory.watchkitapp",
  environment: "production",
};

test("a complication push carries no chat data to Apple, whatever the request holds", async () => {
  const env = { DEVICES: fakeKV(), APNS_KEY_P8: await testKeyPEM(), APNS_KEY_ID: "TESTKEY123", APNS_TEAM_ID: "TESTTEAM12" };
  const reg = await worker.fetch(new Request("https://relay.test/v1/register", { method: "POST", body: JSON.stringify(watch) }), env);
  assert.equal(reg.status, 200);
  const sent = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => { sent.push({ url: String(url), init }); return new Response("", { status: 200 }); };
  try {
    const body = {
      install_id: watch.install_id, secret: watch.secret, push_type: "complication",
      // Everything a careless sender might add: none of it may reach Apple.
      alert: { title: "Rewrite the nightly export job", body: "The export finished" }, content_state: { goal: "Rewriting the export" },
      attributes: { sessionTitle: "Rewrite the nightly export job", botName: "Hermes" }, enc: "abc", thread_id: "20260921_093355_d4e5f6",
    };
    const res = await worker.fetch(new Request("https://relay.test/v1/push", { method: "POST", body: JSON.stringify(body) }), env);
    assert.equal(res.status, 200);
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(sent.length, 1);
  assert.match(sent[0].url, /\/3\/device\/(ef)+$/);
  assert.deepEqual(JSON.parse(sent[0].init.body), { aps: { "content-available": 1 } });
  assert.equal(sent[0].init.headers["apns-topic"], watch.bundle_id + ".complication");
  for (const word of ["nightly", "export", "Hermes", "goal", "20260921"]) assert.ok(!sent[0].init.body.includes(word), `"${word}" reached Apple`);
});

test("a complication push for a phone is refused", async () => {
  const env = { DEVICES: fakeKV(), APNS_KEY_P8: await testKeyPEM(), APNS_KEY_ID: "TESTKEY123", APNS_TEAM_ID: "TESTTEAM12" };
  const phone = { ...watch, install_id: "a9b8c7d6-e5f4-4321-8765-4321fedcba98", platform: "ios", bundle_id: "com.vorantx.vory" };
  await worker.fetch(new Request("https://relay.test/v1/register", { method: "POST", body: JSON.stringify(phone) }), env);
  const res = await worker.fetch(new Request("https://relay.test/v1/push", { method: "POST",
    body: JSON.stringify({ install_id: phone.install_id, secret: phone.secret, push_type: "complication" }) }), env);
  assert.equal(res.status, 400);
});
