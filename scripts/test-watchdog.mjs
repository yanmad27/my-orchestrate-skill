#!/usr/bin/env node
// Deterministic check of skills/orchestrate/watchdog.mjs against a fake `paseo` CLI.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { chmodSync, existsSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const WATCHDOG = join(dirname(fileURLToPath(import.meta.url)), '../skills/orchestrate/watchdog.mjs');
const LEAD = 'lead';
const dir = mkdtempSync(join(tmpdir(), 'watchdog-test-'));
const stateFile = join(dir, 'state.json');
const sendsFile = join(dir, 'sends.jsonl');
const pollsFile = join(dir, 'polls.log'); // one line per `ls` call = one started poll; n+2 => poll n+1 completed
const taskFile = join(dir, `orchestrate-watchdog-${LEAD}.task`);
const pidFile = join(dir, `orchestrate-watchdog-${LEAD}.pid`);
const fake = join(dir, 'paseo');

// Only the test writes state (atomically); the fake reads it and records sends.
writeFileSync(
  fake,
  `#!/usr/bin/env node
const fs = require('fs');
const [cmd, ...args] = process.argv.slice(2);
const { agents } = JSON.parse(fs.readFileSync(${JSON.stringify(stateFile)}, 'utf8'));
if (cmd === 'inspect') {
  const a = agents[args[0]];
  if (!a) process.exit(1);
  console.log(JSON.stringify({ Id: args[0], Name: args[0], Archived: false, PendingPermissions: [], ...a }));
} else if (cmd === 'ls') {
  fs.appendFileSync(${JSON.stringify(pollsFile)}, '1\\n');
  const parent = args[args.indexOf('--label') + 1].split('=')[1];
  const listed = Object.entries(agents).filter(([, a]) => a.parent === parent && !a.Archived);
  console.log(JSON.stringify(listed.map(([id, a]) => ({ id, status: a.Status }))));
} else if (cmd === 'send') {
  fs.appendFileSync(${JSON.stringify(sendsFile)}, JSON.stringify(args[args.indexOf('--prompt') + 1]) + '\\n');
}
`,
);
chmodSync(fake, 0o755);

const iso = (msAgo) => new Date(Date.now() - msAgo).toISOString();
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const within = (p, ms, msg) => {
  let t;
  const timeout = new Promise((_, reject) => (t = setTimeout(() => reject(new Error(msg)), ms)));
  return Promise.race([p, timeout]).finally(() => clearTimeout(t));
};
// Re-checks a condition instead of sleeping a fixed duration, so slow hosts (each poll here
// spawns several node processes) get as long as they need without slowing down fast ones.
const waitFor = async (check, ms = 20000) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (check()) return;
    await wait(100);
  }
  throw new Error(`waitFor timed out after ${ms} ms; sends=${JSON.stringify(sends())}`);
};
const env = (extra) => ({
  ...process.env,
  PASEO_AGENT_ID: LEAD,
  PASEO_CLI: fake,
  TMPDIR: dir,
  WATCHDOG_POLL_SEC: '0.1',
  WATCHDOG_STALL_SEC: '1',
  WATCHDOG_REPEAT_SEC: '1',
  ...extra,
});
const worker = (status, updatedMsAgo, extra = {}) => ({
  parent: LEAD,
  Status: status,
  UpdatedAt: iso(updatedMsAgo),
  CreatedAt: iso(20000), // after the task start written below
  ...extra,
});

let state;
const save = () => {
  writeFileSync(`${stateFile}.tmp`, JSON.stringify(state));
  renameSync(`${stateFile}.tmp`, stateFile);
};
const update = (id, fields) => {
  Object.assign(state.agents[id], fields);
  save();
};
const sends = () =>
  existsSync(sendsFile) ? readFileSync(sendsFile, 'utf8').split('\n').filter(Boolean).map(JSON.parse) : [];
const polls = () => (existsSync(pollsFile) ? readFileSync(pollsFile, 'utf8').split('\n').filter(Boolean).length : 0);
// Proof that the watchdog actually polled again after a precondition was set, so a negative
// assertion ("nothing was sent") can't pass vacuously just because no poll has run yet.
const waitForMorePolls = (n) => waitFor(() => polls() >= n + 2);

async function scenario(name, agents, body, extraEnv = {}, lead = {}) {
  rmSync(sendsFile, { force: true });
  rmSync(pollsFile, { force: true });
  writeFileSync(taskFile, String(Date.now() - 30000));
  state = { agents: { [LEAD]: { Status: 'idle', UpdatedAt: iso(60000), CreatedAt: iso(600000), ...lead }, ...agents } };
  save();
  const child = spawn(process.execPath, [WATCHDOG, 'run'], { env: env(extraEnv), stdio: 'ignore' });
  const exited = new Promise((r) => child.on('exit', r));
  try {
    await body(exited);
    console.log(`ok: watchdog ${name}`);
  } finally {
    child.kill();
  }
}

try {
  await scenario('reports a stalled worker and repeats while it stays silent', { w: worker('running', 5000) }, async () => {
    await waitFor(() => sends().filter((m) => m.includes('STALLED w')).length >= 2);
    const stalled = sends().filter((m) => m.includes('STALLED w'));
    assert.ok(stalled.length >= 2, `expected a repeated STALLED alert, got ${stalled.length}`);
  });

  await scenario(
    'gives [Committee]/[Advisor] agents a longer stall threshold',
    { w: worker('running', 5000), c: worker('running', 5000, { Name: '[Committee] x' }) },
    async () => {
      await waitFor(() => sends().some((m) => m.includes('STALLED w')));
      await wait(300); // one more poll interval before checking the negative
      assert.ok(sends().some((m) => m.includes('STALLED w')), 'normal worker should have stalled');
      assert.ok(!sends().some((m) => m.includes('STALLED c')), 'long-thinking agent alerted too early');
    },
    { WATCHDOG_LONG_STALL_SEC: '30' },
  );

  await scenario(
    'does not treat a pending permission as a stall',
    { w: worker('running', 5000, { PendingPermissions: [{}] }) },
    async () => {
      await waitForMorePolls(polls());
      assert.deepEqual(sends(), [], 'pending permission should have suppressed the stall alert');
    },
  );

  await scenario(
    'holds alerts while the lead has a turn in flight, then delivers them',
    { w: worker('running', 5000) },
    async () => {
      await waitForMorePolls(polls());
      assert.deepEqual(sends(), [], 'sent into a running turn');
      update(LEAD, { Status: 'idle' });
      await waitFor(() => sends().some((m) => m.includes('STALLED w')));
      assert.ok(sends().some((m) => m.includes('STALLED w')), 'held alert was dropped');
    },
    {},
    { Status: 'running', UpdatedAt: iso(0) },
  );

  await scenario(
    'reports a worker that ended while the lead stayed idle',
    { w: worker('running', 0), other: worker('running', 0) },
    async () => {
      await wait(300);
      update('w', { Status: 'idle', UpdatedAt: iso(0) });
      await waitFor(() => sends().some((m) => m.includes('UNREPORTED w')));
      assert.ok(sends().some((m) => m.includes('UNREPORTED w')), 'expected an UNREPORTED alert for the ended worker');
    },
    { WATCHDOG_STALL_SEC: '30' },
  );

  await scenario(
    'lists every ended worker once all end, even after the lead woke for something else',
    { a: worker('running', 0), b: worker('running', 0), old: { ...worker('idle', 600000), CreatedAt: iso(600000) } },
    async () => {
      await wait(300);
      update('b', { Status: 'idle', UpdatedAt: iso(0) });
      await wait(300);
      update(LEAD, { UpdatedAt: iso(0) });
      await wait(300);
      update('a', { Status: 'idle', UpdatedAt: iso(0) });
      await waitFor(() => sends().some((m) => m.includes('ALL ENDED')));
      await waitForMorePolls(polls()); // let a would-be duplicate ALL ENDED arrive if dedup is broken
      assert.ok(!sends().some((m) => m.includes('UNREPORTED b')), 'test setup: fast path should have cleared b');
      const allEnded = sends().filter((m) => m.includes('ALL ENDED'));
      assert.equal(allEnded.length, 1, 'expected exactly one ALL ENDED per set of ended workers');
      assert.match(allEnded[0], /a \(idle\)/);
      assert.match(allEnded[0], /b \(idle\)/);
      assert.doesNotMatch(allEnded[0], /old/, "an earlier task's worker was listed");
    },
    { WATCHDOG_STALL_SEC: '30' },
  );

  await scenario('stops reporting a worker once it is archived', { w: worker('running', 5000) }, async () => {
    await waitFor(() => sends().some((m) => m.includes('STALLED w')));
    assert.ok(sends().some((m) => m.includes('STALLED w')), 'worker should have stalled before being archived');
    update('w', { Archived: true });
    const before = sends().length;
    await waitForMorePolls(polls());
    assert.equal(sends().length, before, 'archived worker kept alerting');
  });

  await scenario('exits when the lead is archived', {}, async (exited) => {
    update(LEAD, { Archived: true });
    await within(exited, 20000, 'still running after the lead was archived');
  });

  await scenario(
    'exits after the quiet period when there is nothing to watch',
    {},
    (exited) => within(exited, 20000, 'did not exit when quiet'),
    { WATCHDOG_QUIET_EXIT_SEC: '1' },
  );

  await scenario(
    'keeps running past the quiet period while a worker is busy',
    { w: worker('running', 0) },
    async (exited) => {
      let dead = false;
      exited.then(() => (dead = true));
      await wait(1500); // past the 1 s quiet-exit window, so a broken `busy` check would already have exited
      const n = polls();
      const deadline = Date.now() + 20000;
      while (!dead && polls() < n + 2 && Date.now() < deadline) await wait(100);
      assert.ok(!dead, 'exited while a worker was running');
    },
    { WATCHDOG_QUIET_EXIT_SEC: '1', WATCHDOG_STALL_SEC: '30' },
  );

  {
    rmSync(taskFile, { force: true });
    const run = (cmd) => execFileSync(process.execPath, [WATCHDOG, cmd], { env: env({ WATCHDOG_STALL_SEC: '30' }), encoding: 'utf8' });
    const pid = Number(run('start').match(/pid (\d+)/)[1]);
    const task = readFileSync(taskFile, 'utf8');
    assert.match(run('start'), new RegExp(`already running: pid ${pid}`));
    assert.equal(readFileSync(taskFile, 'utf8'), task, 'second start reset the task start');
    run('stop');
    await wait(300);
    assert.throws(() => process.kill(pid, 0), 'poller still alive after stop');
    assert.ok(!existsSync(pidFile) && !existsSync(taskFile), 'stop left pid or task file behind');
    console.log('ok: watchdog start is idempotent and stop cleans up');
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}
