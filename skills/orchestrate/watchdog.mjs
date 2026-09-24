#!/usr/bin/env node
// Token-free stand-in for a heartbeat watchdog. `start` detaches a poller that survives the
// lead's process and wakes the lead (PASEO_AGENT_ID) with `paseo send` only when a worker
// needs attention. Usage: watchdog.mjs start | stop | run
import { execFileSync, spawn } from 'node:child_process';
import { openSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const lead = process.env.PASEO_AGENT_ID;
const paseo = process.env.PASEO_CLI || 'paseo';
const sec = (name, dflt) => Number(process.env[name] || dflt) * 1000;
const STALL_MS = sec('WATCHDOG_STALL_SEC', 360);
const REPEAT_MS = sec('WATCHDOG_REPEAT_SEC', 180);
const POLL_MS = sec('WATCHDOG_POLL_SEC', 60);
const QUIET_EXIT_MS = sec('WATCHDOG_QUIET_EXIT_SEC', 7200);

if (!lead) {
  console.error('watchdog: PASEO_AGENT_ID is not set; run inside a Paseo agent');
  process.exit(2);
}

const base = join(tmpdir(), `orchestrate-watchdog-${lead}`);
const pidFile = `${base}.pid`;
const taskFile = `${base}.task`; // task start time; outlives a crashed poller so a restart keeps it
const cli = (...args) => JSON.parse(execFileSync(paseo, [...args, '--json'], { encoding: 'utf8' }));
const inspect = (id) => {
  try {
    return cli('inspect', id);
  } catch {
    return null;
  }
};
const minutesSince = (t) => Math.round((Date.now() - t) / 60000);
const inTurn = (a) => a.Status === 'running' || a.Status === 'initializing';

function runningPid() {
  try {
    const pid = readFileSync(pidFile, 'utf8').trim();
    // A stale pid file may point at a recycled pid; only trust our own poller.
    const cmd = execFileSync('ps', ['-p', pid, '-o', 'command='], { encoding: 'utf8' });
    return cmd.includes('watchdog.mjs') ? Number(pid) : 0;
  } catch {
    return 0;
  }
}

function stop() {
  const pid = runningPid();
  if (pid) process.kill(pid);
  rmSync(pidFile, { force: true });
  rmSync(taskFile, { force: true });
}

// Idempotent: keeps a live poller, replaces a dead one, and never resets the task start.
function start() {
  const pid = runningPid();
  if (pid) return console.log(`watchdog already running: pid ${pid}`);
  try {
    writeFileSync(taskFile, String(Date.now()), { flag: 'wx' });
  } catch {}
  const log = openSync(`${base}.log`, 'a');
  const child = spawn(process.execPath, [fileURLToPath(import.meta.url), 'run'], {
    detached: true,
    stdio: ['ignore', log, log],
  });
  writeFileSync(pidFile, String(child.pid));
  child.unref();
  console.log(`watchdog started: pid ${child.pid}, log ${base}.log`);
}

async function run() {
  let taskStartedAt = Date.now();
  try {
    taskStartedAt = Number(readFileSync(taskFile, 'utf8')) || taskStartedAt;
  } catch {}
  const workers = new Map(); // id -> { status, updatedAt, reportedAt, endedAt, active }
  const alerts = new Map(); // id -> line, held until the lead has no turn in flight
  let remindedFor;
  // Exit only after QUIET_EXIT_MS with nothing to watch and nothing owed to the lead.
  let lastNeededAt = Date.now();

  while (Date.now() - lastNeededAt < QUIET_EXIT_MS) {
    try {
      const me = inspect(lead);
      if (!me || me.Archived) break;

      const listed = cli('ls', '-g', '--label', `paseo.parent-agent-id=${lead}`);
      const live = new Set(listed.map((a) => a.id));
      for (const id of workers.keys()) {
        if (!live.has(id)) {
          workers.delete(id); // archived by the lead
          alerts.delete(id);
        }
      }

      for (const { id, status } of listed) {
        const prev = workers.get(id);
        if (status !== 'running' && prev?.status === status) continue;
        const a = inspect(id);
        if (!a) continue;
        const updatedAt = Date.parse(a.UpdatedAt);
        const rec = {
          status,
          updatedAt,
          endedAt: prev?.endedAt,
          // Created before this task started and not running now = an earlier task's worker.
          active: prev?.active || status === 'running' || Date.parse(a.CreatedAt) >= taskStartedAt,
        };
        if (prev?.updatedAt === updatedAt) rec.reportedAt = prev.reportedAt;
        else alerts.delete(id);

        if (status === 'running') {
          rec.endedAt = undefined;
          const due = !rec.reportedAt || Date.now() - rec.reportedAt >= REPEAT_MS;
          if (!a.PendingPermissions?.length && Date.now() - updatedAt >= STALL_MS && due) {
            alerts.set(id, `STALLED ${id} "${a.Name}": no activity for ${minutesSince(updatedAt)} min`);
            rec.reportedAt = Date.now();
          }
        } else if (status !== 'initializing') {
          const justEnded = prev?.status === 'running' || (!prev && rec.active);
          if (justEnded) rec.endedAt = updatedAt;
        }
        workers.set(id, rec);
      }

      // Fast path for a lost finish notification: the worker ended and the lead has not acted
      // since. Report it after REPEAT_MS, or sooner when another alert wakes the lead anyway.
      const leadActiveAt = Date.parse(me.UpdatedAt);
      for (const w of workers.values()) if (w.endedAt && leadActiveAt >= w.endedAt) w.endedAt = undefined;
      const reportLost = (graceMs) => {
        for (const [id, w] of workers) {
          if (w.endedAt && Date.now() - w.endedAt >= graceMs) {
            alerts.set(id, `UNREPORTED ${id}: ended (${w.status}) ${minutesSince(w.endedAt)} min ago, you have not acted since`);
            w.endedAt = undefined;
          }
        }
      };
      reportLost(REPEAT_MS);

      // Backstop, so no ended worker goes unmentioned even if the lead was woken by something
      // else: once every worker has ended and the lead sits idle, list them all. Once per set.
      const all = [...workers];
      const ended = all.filter(([, w]) => w.active && w.status !== 'running' && w.status !== 'initializing');
      const busy = all.some(([, w]) => w.status === 'running' || w.status === 'initializing');
      const key = ended.map(([id, w]) => id + w.updatedAt).join();
      const owed = !busy && ended.length > 0 && key !== remindedFor;
      if (owed && !inTurn(me) && Date.now() - leadActiveAt >= REPEAT_MS) {
        const list = ended.map(([id, w]) => `${id} (${w.status})`).join(', ');
        alerts.set('all', `ALL ENDED ${list}; you have been idle ${minutesSince(leadActiveAt)} min. Handle any result you have not read; if the task is done, stop the watchdog.`);
        remindedFor = key;
      }
      if (busy) alerts.delete('all');

      // Like a heartbeat tick, never deliver into a turn in flight: `paseo send` would interrupt it.
      // Undelivered alerts stay queued and retry every poll.
      // ponytail: turn check and send are not atomic; a turn starting in that ~1s gap gets interrupted.
      const now = alerts.size ? inspect(lead) : null;
      if (now && !inTurn(now) && !now.PendingPermissions?.length) {
        reportLost(30000);
        const body = [...alerts.values()].join('\n');
        execFileSync(paseo, ['send', lead, '--no-wait', '--prompt', `[orchestrate-watchdog]\n${body}`]);
        console.log(new Date().toISOString(), `sent:\n${body}`);
        alerts.clear();
      }

      if (busy || owed || alerts.size) lastNeededAt = Date.now();
    } catch (e) {
      console.error(new Date().toISOString(), e.message);
      lastNeededAt = Date.now(); // daemon unreachable: keep watching until it is back
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
  console.log(new Date().toISOString(), 'exiting: lead gone or nothing to watch');
  try {
    if (readFileSync(pidFile, 'utf8').trim() === String(process.pid)) rmSync(pidFile);
  } catch {}
}

const cmd = process.argv[2];
if (cmd === 'start') start();
else if (cmd === 'stop') stop();
else if (cmd === 'run') await run();
else {
  console.error('usage: watchdog.mjs start | stop | run');
  process.exit(2);
}
