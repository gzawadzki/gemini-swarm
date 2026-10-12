#!/usr/bin/env node
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Use the same TypeScript loader as the installed Pi; no separate npm install.
export async function loadProvider(piBin) {
  const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
  const providerDir = resolve(process.env.HERDR_SWARM_ANTIGRAVITY_DIR ||
    join(agentDir, "npm", "node_modules", "pi-antigravity"));
  const realPiBin = realpathSync(piBin);
  const binDir = dirname(realPiBin);
  const anchors = [
    join(binDir, "node_modules", "@earendil-works", "pi-coding-agent", "package.json"),
    realPiBin,
    piBin,
  ];
  let createJiti;
  for (const anchor of anchors) {
    try { ({ createJiti } = createRequire(anchor)("jiti")); break; } catch { /* try next installation layout */ }
  }
  if (!createJiti) throw new Error("Cannot locate Pi's jiti loader");
  const jiti = createJiti(join(providerDir, "package.json"));
  const [auth, usage, quota, models] = await Promise.all([
    jiti.import(join(providerDir, "src", "auth", "index.ts")),
    jiti.import(join(providerDir, "src", "usage", "usage.ts")),
    jiti.import(join(providerDir, "src", "usage", "quota.ts")),
    jiti.import(join(providerDir, "src", "models", "models.ts")),
  ]);
  if (typeof auth.resolveProcessAccountApiKey !== "function") {
    throw new Error("Installed Antigravity provider lacks process-local account routing");
  }
  return { ...auth, ...usage, ...quota, ...models, jiti, providerDir };
}

function runtimeModelFor(task, provider) {
  let model = task.model || "gemini-3.8-flash-high";
  if (model.includes("/")) {
    const [name, ...rest] = model.split("/");
    if (name !== "antigravity") return undefined;
    model = rest.join("/");
  }
  let thinking = task.effort || "off";
  if (/^gemini-.*-(low|medium|high)$/.test(model)) {
    if (!task.effort) thinking = model.split("-").at(-1);
    model = model.replace(/-(low|medium|high)$/, "");
  } else if (/^claude-.*-thinking$/.test(model)) {
    if (!task.effort) thinking = "high";
    model = model.replace(/-thinking$/, "");
  } else if (/^gpt-oss-.*-medium$/.test(model)) {
    if (!task.effort) thinking = "medium";
    model = model.replace(/-medium$/, "");
  }
  return process.env.ANTIGRAVITY_RUNTIME_MODEL || process.env.PI_ANTIGRAVITY_RUNTIME_MODEL ||
    provider.getAntigravityRequestModelId(model, thinking);
}

export async function makeQuotaPlan(tasks, provider, options = {}) {
  const store = provider.loadAccountStore();
  const accounts = Object.values(store.accounts).sort((a, b) =>
    a.addedAt - b.addedAt || a.accountId.localeCompare(b.accountId));
  const snapshots = await Promise.all(accounts.map(async (account, index) => {
    let timer;
    try {
      const usage = await Promise.race([
        (async () => {
          const key = await provider.resolveAccountApiKey(account.accountId);
          if (!key) throw new Error("Account credentials unavailable");
          return provider.fetchAccountUsage(JSON.stringify(key));
        })(),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error("Quota lookup timed out")), options.timeoutMs ?? 10000);
        }),
      ]);
      return { accountId: account.accountId, account: index < 2 ? ["a", "b"][index] : String(index + 1), usage };
    } catch {
      // Never serialize provider errors: they may contain credential-bearing diagnostics.
      return { accountId: account.accountId, account: index < 2 ? ["a", "b"][index] : String(index + 1) };
    } finally { clearTimeout(timer); }
  }));
  const cursors = new Map();
  return tasks.map((task) => {
    if (task.kind !== "pi") return { status: "not-applicable" };
    const runtimeModel = runtimeModelFor(task, provider);
    if (!runtimeModel) return { status: "not-applicable" };
    // Extra CLI args must not silently override the model checked by preflight.
    if ((task.args || []).some((arg) => /^--(model|provider|thinking)(=|$)/.test(arg))) {
      return { status: "blocked", reason: "Use task model/effort instead of model/provider/thinking overrides in args" };
    }
    const quota = snapshots.map((snapshot) => ({
      account: snapshot.account,
      accountId: snapshot.accountId,
      ...(snapshot.usage ? provider.assessModelQuota(snapshot.usage, runtimeModel) :
        { status: "unknown", reason: "Quota lookup failed or timed out" }),
    }));
    const requested = task.account && !["auto", "round-robin"].includes(task.account) ? task.account : undefined;
    let eligible = quota.filter((row) => row.status === "available");
    if (requested) {
      const id = provider.findAccountId(store, requested);
      eligible = eligible.filter((row) => row.accountId === id);
    }
    if (!eligible.length) {
      const selected = requested ? quota.filter((row) =>
        row.accountId === provider.findAccountId(store, requested)) : quota;
      const reason = selected.length ? selected.map((row) =>
        `${row.account}: ${row.reason}${row.resetTime ? `; reset ${row.resetTime}` : ""}`).join(" | ") :
        requested ? `Account not found: ${requested}` : "No linked accounts";
      return { status: "blocked", runtimeModel, reason, quota };
    }
    const roundRobin = task.account === "auto" || task.account === "round-robin" || options.roundRobin;
    const cursor = cursors.get(runtimeModel) || 0;
    const selected = requested ? eligible[0] : roundRobin ? eligible[cursor % eligible.length] :
      eligible.find((row) => row.accountId === store.activeAccountId) || eligible[0];
    if (!requested && roundRobin) cursors.set(runtimeModel, cursor + 1);
    return { status: "ready", runtimeModel, account: selected.account, accountId: selected.accountId, quota };
  });
}

async function main() {
  const [tasksFile, piBin] = process.argv.slice(2);
  if (!tasksFile || !piBin || !existsSync(tasksFile)) throw new Error("Usage: quota-preflight.mjs <tasks.json> <pi executable>");
  const { tasks } = JSON.parse(readFileSync(tasksFile, "utf8"));
  const provider = await loadProvider(piBin);
  const roundRobin = process.env.HERDR_SWARM_ROUND_ROBIN === "1" ||
    (tasks.length > 1 && process.env.HERDR_SWARM_NO_ROUND_ROBIN !== "1");
  const plan = await makeQuotaPlan(tasks, provider, { roundRobin });
  process.stdout.write(`${JSON.stringify({ fetchedAt: Date.now(), tasks: plan })}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const watchdog = setTimeout(() => { console.error("Quota preflight timed out"); process.exit(1); }, 20000);
  main().then(() => { clearTimeout(watchdog); process.exit(0); }, () => {
    console.error("Quota preflight unavailable; Pi workers must not start");
    process.exit(1);
  });
}
