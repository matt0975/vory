// A push Apple accepts keeps the registration alive (#499): the same record written again with the 180
// days when its last write is over a week old, on any push type; never after a failed push; a dead token
// still deletes, but only the registration Apple refused; and a register that lands while a push waits
// on Apple is never put back to the old token. Apple is a stand-in (globalThis.fetch); the APNs key is
// made for the test.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const DAY = 24 * 3600 * 1000;
const TTL = 180 * 24 * 3600;

async function testKeyPEM() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  return "-----BEGIN PRIVATE KEY-----\n" + btoa(String.fromCharCode(...der)) + "\n-----END PRIVATE KEY-----";
}

function fakeKV() {
  const data = new Map();
  const puts = [];
  const deletes = [];
  return {
    data, puts, deletes,
    async get(key) { return data.has(key) ? data.get(key) : null; },
    async put(key, value, options = {}) { puts.push({ key, value, options }); data.set(key, value); },
    async delete(key) { deletes.push(key); data.delete(key); },
  };
}

const phone = {
  install_id: "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e",
  secret: "p".repeat(64),
  device_token: "12".repeat(32),
  platform: "ios",
  bundle_id: "com.vorantx.vory",
  environment: "production",
};
const watch = { ...phone, install_id: "c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f", platform: "watchos", bundle_id: "com.vorantx.vory.watchkitapp", device_token: "34".repeat(32) };

const KEY = (d) => "dev:" + d.install_id;

async function setup(device, ageDays) {
  const env = { DEVICES: fakeKV(), APNS_KEY_P8: await testKeyPEM(), APNS_KEY_ID: "TESTKEY123", APNS_TEAM_ID: "TESTTEAM12" };
  await worker.fetch(new Request("https://relay.test/v1/register", { method: "POST", body: JSON.stringify(device) }), env);
  const rec = JSON.parse(env.DEVICES.data.get(KEY(device)));
  rec.updated_at = Date.now() - ageDays * DAY;
  env.DEVICES.data.set(KEY(device), JSON.stringify(rec));
  env.DEVICES.puts.length = 0;
  return { env, before: rec };
}

async function push(env, device, body, apple) {
  const real = globalThis.fetch;
  globalThis.fetch = apple;
  try {
    return await worker.fetch(new Request("https://relay.test/v1/push", { method: "POST",
      body: JSON.stringify({ install_id: device.install_id, secret: device.secret, ...body }) }), env);
  } finally {
    globalThis.fetch = real;
  }
}

const ok = async () => new Response("", { status: 200 });
const alert = { push_type: "alert", enc: "ciphertext" };

test("a push accepted on day 8 writes the same record again, with the 180 days", async () => {
  const { env, before } = await setup(phone, 8);
  await push(env, phone, alert, ok);
  assert.equal(env.DEVICES.puts.length, 1);
  assert.equal(env.DEVICES.puts[0].options.expirationTtl, TTL);
  const after = JSON.parse(env.DEVICES.data.get(KEY(phone)));
  assert.ok(Date.now() - after.updated_at < 5000, "updated_at is now");
  const { updated_at: _a, ...restAfter } = after;
  const { updated_at: _b, ...restBefore } = before;
  assert.deepEqual(restAfter, restBefore, "nothing but updated_at changes");
});

test("a push accepted on day 3 writes nothing", async () => {
  const { env } = await setup(phone, 3);
  await push(env, phone, alert, ok);
  assert.equal(env.DEVICES.puts.length, 0);
});

test("a push Apple turns down writes nothing", async () => {
  const { env } = await setup(phone, 30);
  await push(env, phone, alert, async () => new Response("{\"reason\":\"InternalServerError\"}", { status: 500 }));
  assert.equal(env.DEVICES.puts.length, 0);
  assert.ok(env.DEVICES.data.has(KEY(phone)));
});

test("a complication push keeps the Watch's registration too", async () => {
  const { env } = await setup(watch, 20);
  await push(env, watch, { push_type: "complication" }, ok);
  assert.equal(env.DEVICES.puts.length, 1);
  assert.equal(env.DEVICES.puts[0].options.expirationTtl, TTL);
});

test("a dead token still deletes the registration", async () => {
  const { env } = await setup(phone, 2);
  await push(env, phone, alert, async () => new Response("{\"reason\":\"Unregistered\"}", { status: 410 }));
  assert.ok(!env.DEVICES.data.has(KEY(phone)));
});

test("a register landing while the push waits on Apple keeps its new token", async () => {
  const { env } = await setup(phone, 30);
  const fresh = { ...JSON.parse(env.DEVICES.data.get(KEY(phone))), device_token: "56".repeat(32), updated_at: Date.now() };
  await push(env, phone, alert, async () => {
    // A restored device registers its new token while Apple answers the old one.
    env.DEVICES.data.set(KEY(phone), JSON.stringify(fresh));
    return new Response("", { status: 200 });
  });
  const after = JSON.parse(env.DEVICES.data.get(KEY(phone)));
  assert.equal(after.device_token, fresh.device_token, "the old token was written back");
  assert.equal(env.DEVICES.puts.length, 0);
});

test("a dead old token doesn't delete a registration made since with a new one", async () => {
  const { env } = await setup(phone, 2);
  const fresh = { ...JSON.parse(env.DEVICES.data.get(KEY(phone))), device_token: "78".repeat(32), updated_at: Date.now() };
  await push(env, phone, alert, async () => {
    env.DEVICES.data.set(KEY(phone), JSON.stringify(fresh));
    return new Response("{\"reason\":\"Unregistered\"}", { status: 410 });
  });
  assert.ok(env.DEVICES.data.has(KEY(phone)), "the new registration was deleted");
  assert.equal(JSON.parse(env.DEVICES.data.get(KEY(phone))).device_token, fresh.device_token);
});
