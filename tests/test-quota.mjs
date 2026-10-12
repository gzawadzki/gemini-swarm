import assert from "node:assert/strict";
import { after, test } from "node:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { loadProvider, makeQuotaPlan } from "../scripts/quota-preflight.mjs";

const provider = await loadProvider(process.env.HERDR_SWARM_PI_BIN);
const { streamAntigravity } = await provider.jiti.import(join(provider.providerDir, "src/stream/stream.ts"));
const scratch = mkdtempSync(join(tmpdir(), "swarm-quota-tests-"));
const originalDir = process.env.PI_CODING_AGENT_DIR;
const originalSelector = process.env.ANTIGRAVITY_ACCOUNT;
const originalFetch = globalThis.fetch;
process.env.PI_CODING_AGENT_DIR = scratch;
process.env.ANTIGRAVITY_NO_PREWARM = "1";
globalThis.fetch = async () => { throw new Error("Unexpected network call in quota test"); };
after(() => {
  globalThis.fetch = originalFetch;
  if (originalDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = originalDir;
  if (originalSelector === undefined) delete process.env.ANTIGRAVITY_ACCOUNT;
  else process.env.ANTIGRAVITY_ACCOUNT = originalSelector;
  rmSync(scratch, { recursive: true, force: true });
});

const runtimeModel = "gemini-3.8-flash-high";
function usage(remainingFraction = 0.5, groups = []) {
  return { models: [{ modelId: runtimeModel, remainingFraction }], groups, fetchedAt: Date.now() };
}
function pool(fiveHour, weekly = 0.8, displayName = "Gemini Models") {
  return { displayName, buckets: [
    { bucketId: "5h", remainingFraction: fiveHour, resetTime: "2030-01-01T05:00:00Z" },
    { bucketId: "weekly", remainingFraction: weekly, resetTime: "2030-01-07T00:00:00Z" },
  ] };
}
const task = { kind: "pi", model: runtimeModel };
function fixtureProvider(a, b, failures = []) {
  const accounts = {
    "account-a": { accountId: "account-a", addedAt: 1 },
    "account-b": { accountId: "account-b", addedAt: 2 },
  };
  const store = { activeAccountId: "account-a", accounts };
  let fetches = 0;
  return {
    ...provider,
    loadAccountStore: () => store,
    resolveAccountApiKey: async (accountId) => ({ token: accountId }),
    fetchAccountUsage: async (key) => {
      const { token } = JSON.parse(key);
      fetches++;
      if (failures.includes(token)) throw new Error("secret-token must not reach output");
      return token === "account-a" ? a : b;
    },
    fetchCount: () => fetches,
  };
}

test("quota checks the exact model and every window in its pool", () => {
  assert.equal(provider.assessModelQuota(usage(0.5, [pool(0)]), runtimeModel).status, "exhausted");
  assert.equal(provider.assessModelQuota(usage(0.5, [pool(0.5, 0)]), runtimeModel).status, "exhausted");
  assert.equal(provider.assessModelQuota(usage(0), runtimeModel).status, "exhausted");
  assert.equal(provider.assessModelQuota(usage(undefined), "missing-model").status, "unknown");
  assert.equal(provider.assessModelQuota(usage(0.5, [pool(undefined)]), runtimeModel).status, "unknown");
  assert.equal(provider.assessModelQuota(usage(0.5, [pool(0, 0, "Claude Models")]), runtimeModel).status, "available");
  assert.equal(provider.assessModelQuota(usage(0.001), runtimeModel).status, "available");
});

test("only subscription-gated aggregate errors permit per-model fallback", () => {
  assert.equal(provider.assessModelQuota({ ...usage(), quotaSummaryError: "SUBSCRIPTION_REQUIRED #3501" }, runtimeModel).status, "available");
  assert.equal(provider.assessModelQuota({ ...usage(), quotaSummaryError: "Network failure" }, runtimeModel).status, "unknown");
});

test("zero quota remains blocked even if its reported reset is in the past", () => {
  const data = usage(0);
  data.models[0].resetTime = "2000-01-01T00:00:00Z";
  assert.equal(provider.assessModelQuota(data, runtimeModel).status, "exhausted");
  assert.equal(provider.assessModelQuota(usage(0.5, [pool(0, 0)]), runtimeModel).resetTime, "2030-01-07T00:00:00Z");
});

test("both available: A/B/A/B; snapshot fetched only once per account", async () => {
  const p = fixtureProvider(usage(), usage());
  const plan = await makeQuotaPlan([task, task, task, task], p, { roundRobin: true });
  assert.deepEqual(plan.map((row) => row.account), ["a", "b", "a", "b"]);
  assert.equal(p.fetchCount(), 2);
});

test("one available: all automatic tasks use it, explicit exhausted account blocks", async () => {
  const p = fixtureProvider(usage(), usage(0));
  const plan = await makeQuotaPlan([task, task, { ...task, account: "b" }], p, { roundRobin: true });
  assert.deepEqual(plan.map((row) => row.status), ["ready", "ready", "blocked"]);
  assert.deepEqual(plan.slice(0, 2).map((row) => row.account), ["a", "a"]);
  assert.equal((await makeQuotaPlan([task, task], fixtureProvider(usage(0), usage()), { roundRobin: true }))[0].account, "b");
});

test("both exhausted or unknown: no automatic assignment; errors never leak", async () => {
  assert.equal((await makeQuotaPlan([task], fixtureProvider(usage(0), usage(0))))[0].status, "blocked");
  const plan = await makeQuotaPlan([task], fixtureProvider(usage(), usage(), ["account-a", "account-b"]));
  assert.equal(plan[0].status, "blocked");
  assert.ok(!JSON.stringify(plan).includes("secret-token"));
  const partial = await makeQuotaPlan([task], fixtureProvider(usage(), usage(), ["account-b"]));
  assert.equal(partial[0].account, "a");
});

test("explicit selectors resolve canonically and do not consume automatic slots", async () => {
  const p = fixtureProvider(usage(), usage());
  const plan = await makeQuotaPlan([task, { ...task, account: "2" }, task, { ...task, account: "missing" }], p, { roundRobin: true });
  assert.deepEqual(plan.slice(0, 3).map((row) => row.account), ["a", "b", "b"]);
  assert.equal(plan[3].status, "blocked");
});

test("model/effort normalization agrees with Pi; other providers are untouched", async () => {
  const p = fixtureProvider(usage(), usage());
  const plan = await makeQuotaPlan([
    { ...task, model: "antigravity/gemini-3.8-flash", effort: "high" },
    { kind: "codex" }, { kind: "pi", model: "openai/gpt-5" },
    { ...task, args: ["--model", "other-model"] },
  ], p);
  assert.equal(plan[0].runtimeModel, runtimeModel);
  assert.equal(plan[0].status, "ready");
  assert.equal(plan[1].status, "not-applicable");
  assert.equal(plan[2].status, "not-applicable");
  assert.equal(plan[3].status, "blocked");
});

test("timed-out quota is unknown, not zero or available", async () => {
  const p = fixtureProvider(usage(), usage());
  p.fetchAccountUsage = () => new Promise(() => {});
  const plan = await makeQuotaPlan([task], p, { timeoutMs: 5 });
  assert.equal(plan[0].status, "blocked");
  assert.ok(plan[0].quota.every((row) => row.status === "unknown"));
});

function seedAccounts(prefix) {
  const accounts = {};
  for (const [index, alias] of ["a", "b"].entries()) {
    const id = `${prefix}-${alias}`;
    accounts[id] = { accountId: id, email: `${id}@example.test`, addedAt: index + 1,
      access: `${id}-token`, refresh: `${id}-refresh`, expires: Date.now() + 3600000,
      projectId: "test-project", lastUsedAt: 1 };
  }
  writeFileSync(join(scratch, "antigravity-accounts.json"), JSON.stringify({ version: 1, accounts, activeAccountId: `${prefix}-a` }));
  writeFileSync(join(scratch, "auth.json"), JSON.stringify({ antigravity: { ...accounts[`${prefix}-a`], type: "oauth" }, unrelated: "keep" }));
  // Change the selector to reset the process-local preference between scenarios.
  process.env.ANTIGRAVITY_ACCOUNT = `${prefix}-b`;
  return { accounts, beforeStore: readFileSync(join(scratch, "antigravity-accounts.json"), "utf8"),
    beforeAuth: readFileSync(join(scratch, "auth.json"), "utf8") };
}
const model = { id: "gemini-3.8-flash", api: "antigravity-api", provider: "antigravity", name: "Test",
  reasoning: true, input: ["text"], contextWindow: 1000000, maxTokens: 100,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const context = { messages: [{ role: "user", content: "hello", timestamp: Date.now() }] };
function successResponse() {
  return new Response('data: {"response":{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}}\n\n',
    { status: 200, headers: { "Content-Type": "text/event-stream" } });
}

test("real stream: hard quota failover is sticky across turns and never switches global auth", async () => {
  const seeded = seedAccounts("sticky");
  const calls = [];
  globalThis.fetch = async (_url, init) => {
    const token = init.headers.Authorization;
    calls.push(token);
    if (token.includes("sticky-b-token")) return new Response('{"error":{"message":"Individual quota reached. Resets in 3h"}}', { status: 429 });
    return successResponse();
  };
  const options = { apiKey: JSON.stringify({ token: "sticky-b-token", projectId: "test-project" }), reasoning: "high" };
  const first = await streamAntigravity(model, context, options).result();
  assert.equal(first.stopReason, "stop");
  const second = await streamAntigravity(model, context, options).result();
  assert.equal(second.stopReason, "stop");
  assert.deepEqual(calls, ["Bearer sticky-b-token", "Bearer sticky-a-token", "Bearer sticky-a-token"]);
  assert.equal(JSON.parse(provider.getApiKey(seeded.accounts["sticky-b"])).token, "sticky-a-token");
  assert.equal(readFileSync(join(scratch, "auth.json"), "utf8"), seeded.beforeAuth);
  assert.equal(readFileSync(join(scratch, "antigravity-accounts.json"), "utf8"), seeded.beforeStore);
});

test("real stream: both exhausted terminate after one attempt per account", async () => {
  seedAccounts("empty");
  const calls = [];
  globalThis.fetch = async (_url, init) => {
    calls.push(init.headers.Authorization);
    return new Response('{"error":{"message":"Individual quota reached. Resets in 3h"}}', { status: 429 });
  };
  const result = await streamAntigravity(model, context, { apiKey: JSON.stringify({ token: "empty-b-token", projectId: "test-project" }) }).result();
  assert.equal(result.stopReason, "error");
  assert.deepEqual(calls, ["Bearer empty-b-token", "Bearer empty-a-token"]);
});

test("real stream: transient 429 retries the same account, not failover", async () => {
  seedAccounts("transient");
  const calls = [];
  globalThis.fetch = async (_url, init) => {
    calls.push(init.headers.Authorization);
    return calls.length === 1 ? new Response('{"error":{"message":"Rate limit exceeded"}}', { status: 429 }) : successResponse();
  };
  const result = await streamAntigravity(model, context, { apiKey: JSON.stringify({ token: "transient-b-token", projectId: "test-project" }) }).result();
  assert.equal(result.stopReason, "stop");
  assert.ok(calls.length > 1);
  assert.ok(calls.every((token) => token === "Bearer transient-b-token"));
});

test("real usage parser preserves missing remaining as unknown", async () => {
  globalThis.fetch = async (url) => {
    if (url.includes("retrieveUserQuotaSummary")) return Response.json({ groups: [{ displayName: "Gemini Models", buckets: [{ bucketId: "5h" }] }] });
    if (url.includes("fetchAvailableModels")) return Response.json({ models: { [runtimeModel]: { quotaInfo: { remainingFraction: 0.5 } } } });
    return Response.json({ projectId: "test-project" });
  };
  const data = await provider.fetchAccountUsage(JSON.stringify({ token: "usage-token", projectId: "test-project" }));
  assert.equal(data.groups[0].buckets[0].remainingFraction, undefined);
  assert.equal(provider.assessModelQuota(data, runtimeModel).status, "unknown");
});

test("concurrent credential refresh preserves both accounts and global auth", async () => {
  const seeded = seedAccounts("refresh");
  for (const account of Object.values(seeded.accounts)) account.expires = 0;
  writeFileSync(join(scratch, "antigravity-accounts.json"), JSON.stringify({ version: 1, accounts: seeded.accounts, activeAccountId: "refresh-a" }));
  const { MockAgent, getGlobalDispatcher, setGlobalDispatcher } = createRequire(join(provider.providerDir, "package.json"))("undici");
  const originalDispatcher = getGlobalDispatcher();
  const mock = new MockAgent();
  mock.disableNetConnect();
  const url = new URL(provider.TOKEN_URL);
  let refreshes = 0;
  mock.get(url.origin).intercept({ path: url.pathname, method: "POST" }).reply(200, (options) => {
    refreshes++;
    const id = new URLSearchParams(String(options.body)).get("refresh_token").replace(/-refresh$/, "");
    return { access_token: `${id}-new-token`, expires_in: 3600 };
  }).times(2);
  setGlobalDispatcher(mock);
  try {
    const [a1, a2, b] = await Promise.all([
      provider.resolveAccountApiKey("refresh-a"), provider.resolveAccountApiKey("refresh-a"),
      provider.resolveAccountApiKey("refresh-b"),
    ]);
    assert.equal(a1.token, "refresh-a-new-token");
    assert.equal(a2.token, a1.token);
    assert.equal(b.token, "refresh-b-new-token");
    assert.equal(refreshes, 2);
    const store = JSON.parse(readFileSync(join(scratch, "antigravity-accounts.json"), "utf8"));
    assert.equal(store.accounts["refresh-a"].access, a1.token);
    assert.equal(store.accounts["refresh-b"].access, b.token);
    assert.equal(store.activeAccountId, "refresh-a");
    assert.equal(readFileSync(join(scratch, "auth.json"), "utf8"), seeded.beforeAuth);
  } finally {
    setGlobalDispatcher(originalDispatcher);
    await mock.close();
  }
});

test("unknown explicit process selector never falls back to unrelated credentials", async () => {
  process.env.ANTIGRAVITY_ACCOUNT = "does-not-exist";
  assert.throws(() => provider.getApiKey({ access: "unrelated", refresh: "unrelated" }), /account not found/);
  await assert.rejects(provider.resolveProcessAccountApiKey(), /account not found/);
});
