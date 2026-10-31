// The relay's registration store (#499): every write lasts 180 days, an app in use refreshes it at
// least daily, and unregister removes it. Run with `node --test server/push-relay/test` (no
// wrangler, no network): the Worker's fetch handler against an in-memory stand-in for its KV.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const TTL_DAYS = 180 * 24 * 3600;

function fakeKV() {
  const data = new Map();
  const puts = [];
  return {
    data, puts,
    async get(key) { return data.has(key) ? data.get(key).value : null; },
    async put(key, value, options = {}) { puts.push({ key, options }); data.set(key, { value, options }); },
    async delete(key) { data.delete(key); },
  };
}

const device = {
  install_id: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
  secret: "s".repeat(64),
  device_token: "ab".repeat(32),
  platform: "watchos",
  bundle_id: "com.vorantx.vory.watchkitapp",
  environment: "production",
};

const call = (env, method, body) =>
  worker.fetch(new Request("https://relay.test/v1/register", { method, body: JSON.stringify(body) }), env);

test("a registration is written to last 180 days", async () => {
  const env = { DEVICES: fakeKV() };
  const res = await call(env, "POST", device);
  assert.equal(res.status, 200);
  assert.equal(env.DEVICES.puts.length, 1);
  assert.equal(env.DEVICES.puts[0].key, "dev:" + device.install_id);
  assert.equal(env.DEVICES.puts[0].options.expirationTtl, TTL_DAYS);
});

test("the same registration within the day costs no write", async () => {
  const env = { DEVICES: fakeKV() };
  await call(env, "POST", device);
  const res = await call(env, "POST", device);
  assert.deepEqual(await res.json(), { ok: true, unchanged: true });
  assert.equal(env.DEVICES.puts.length, 1);
});

test("the daily re-register writes again, refreshing the 180 days", async () => {
  const env = { DEVICES: fakeKV() };
  await call(env, "POST", device);
  const key = "dev:" + device.install_id;
  const stored = JSON.parse(env.DEVICES.data.get(key).value);
  stored.updated_at = Date.now() - 25 * 3600 * 1000;
  env.DEVICES.data.set(key, { value: JSON.stringify(stored), options: {} });
  const res = await call(env, "POST", device);
  assert.deepEqual(await res.json(), { ok: true });
  assert.equal(env.DEVICES.puts.length, 2);
  assert.equal(env.DEVICES.puts[1].options.expirationTtl, TTL_DAYS);
});

test("a new device token writes at once, with the 180 days", async () => {
  const env = { DEVICES: fakeKV() };
  await call(env, "POST", device);
  await call(env, "POST", { ...device, device_token: "cd".repeat(32) });
  assert.equal(env.DEVICES.puts.length, 2);
  assert.equal(env.DEVICES.puts[1].options.expirationTtl, TTL_DAYS);
});

test("unregister removes the registration, and only with its secret", async () => {
  const env = { DEVICES: fakeKV() };
  await call(env, "POST", device);
  const wrong = await call(env, "DELETE", { install_id: device.install_id, secret: "t".repeat(64) });
  assert.equal(wrong.status, 403);
  assert.ok(env.DEVICES.data.has("dev:" + device.install_id));
  const res = await call(env, "DELETE", { install_id: device.install_id, secret: device.secret });
  assert.equal(res.status, 200);
  assert.ok(!env.DEVICES.data.has("dev:" + device.install_id));
});
