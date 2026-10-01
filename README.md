# paseo-slp

A Claude Code plugin for a three-seat agent room in [Paseo](https://paseo.sh) — **S**upervisor →
**L**ead → **P**eers (SLP), modeled on
[hoangnb24/codex-room-setup](https://github.com/hoangnb24/codex-room-setup).
You talk only to the **Supervisor**. It pins down what you want, launches
**Lead** agents, and keeps them and their **Peers** on course — checking each
plan against your intent and watching the room for drift. Each Lead owns one
project's technical outcome and delegates to Claude Peers routed to the
cheapest capable model tier, with Codex Peers for cross-family review or on
request; Peers may push back on their Lead with evidence. Everything runs on
Claude except Peers, which can also be Codex. Nobody above Peer edits files
or writes code.

[![License: MIT](https://img.shields.io/github/license/yanmad27/paseo-slp)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/yanmad27/paseo-slp)](https://github.com/yanmad27/paseo-slp/releases)
[![Works with Paseo](https://img.shields.io/badge/works%20with-Paseo-2b6cb0)](https://paseo.sh)

## Contents

- [Room model](#room-model)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Install](#install)
- [Paseo configuration](#paseo-configuration)
- [Restart & verify](#restart--verify)
- [Upgrade](#upgrade)
- [slp-gc](#slp-gc)
- [Troubleshooting](#troubleshooting)
- [Usage](#usage)

## Room model

```text
You ⇄ Supervisor ⇄ Lead ⇄ Peers

Supervisor → Lead   instruction, open questions
Lead → Supervisor   reports (plan first, then status, decisions, done)
Lead → Peer         brief, dispositions, answers
Peer → Lead         signals at turn end, plus mid-work messages
```

| Seat | Owns | Never |
|---|---|---|
| **Supervisor** (the Supervisor profile, or `/supervisor`) | Your only point of contact. Pins down your intent (outcome, non-goals, authority, acceptance evidence), launches Leads, checks each Lead's plan against that intent, watches the room on a Paseo heartbeat for drift — wrong target, scope creep, rabbit holes, unauthorized actions, acceptance without evidence, open loops — questions the Lead with evidence, and brings product/cost/risk decisions back to you | Edits code, runs validation, accepts work, talks to Peers, or asks a healthy Lead for reports |
| **Lead** | One project's technical outcome inside the course the Supervisor set: plan, Peer tiering (Jev), plan review, committee, independent review, explicit `ACCEPT`/`REJECT` of each candidate | Implements, launches another Lead, or changes what you get without asking |
| **Peer** (Claude or Codex) | One bounded outcome in one write scope, with its own proof — or a read-only review. Talks with its Lead both ways | Spawns or coordinates agents, talks to anyone but its Lead, or accepts its own work |

**Lead ⇄ Peer.** A Peer reports at the end of its turn, and can also message
its Lead mid-work (`send_agent_prompt`; the brief names the Lead's agent ID)
with a question, a missing dependency, or an early challenge while it keeps
working on unaffected parts. Because Paseo delivers a message to a running
agent by interrupting its turn, a Peer only sends when its Lead is idle,
and the Lead's short answer lets the Peer resume where it was.

**Debate.** A Peer that finds the Lead's premise wrong answers with a signal
instead of complying: `REOPEN_REQUEST` (failed premise), `DEPENDENCY_REQUEST`
(unowned prerequisite), `BLOCKED`, or `QUESTION`, each with evidence. The Lead
must concede with a `REVISED BRIEF` or `HOLD` with counter-evidence; the Peer
may rebut once more with new evidence. After two rounds the Lead decides and
records the dissent (optionally after a tie-break from a read-only Peer or the
Codex review peer); product-level disputes go up to you as `DECISION_NEEDED`.

The shared contract lives in [`skills/supervisor/PROTOCOL.md`](skills/supervisor/PROTOCOL.md);
role instructions in [`roles/lead.md`](skills/supervisor/roles/lead.md) and
[`roles/peer.md`](skills/supervisor/roles/peer.md). They are adapted from the
Codex Room overlays in [hoangnb24/codex-room-setup](https://github.com/hoangnb24/codex-room-setup).
A target project can add local rules in its own `docs/WORKSPACE_PROTOCOL.md`.

## Requirements

- Claude Code with a subscription (for `claude setup-token`), and the Codex CLI for the Codex Peers
- Paseo, with the daemon config described below
- `jq` and `curl` (used by `install.sh`)
- Optional: the [`ask-jev`](https://github.com/yanmad27/ask-jev) Claude Code plugin — when installed, each Lead uses it to pick the Peer tier and to gate escalation; without it, the manual routing rules apply.

Enable Paseo MCP tool injection in `~/.paseo/config.json`:

```json
{
  "daemon": {
    "mcp": {
      "enabled": true,
      "injectIntoAgents": true
    }
  }
}
```

> [!IMPORTANT]
> Without `injectIntoAgents: true`, the Supervisor and Lead will not have the `create_agent` tool.

## Quick start

1. Get a Claude token for the room's seats — they all share it:

   ```sh
   claude setup-token
   ```

   Log in in the browser, paste the code it shows back into that terminal,
   and leave the printed `sk-ant-oat01-…` line on screen.

2. In another terminal, install everything — the `/supervisor` skill, the
   seat runtimes and role prompts, and the Paseo profiles — and reload the
   Paseo daemon:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/yanmad27/paseo-slp/main/install.sh | bash
   ```

   When it asks for the token, copy the `sk-ant-oat01-…` line from step 1 and
   paste it (input is hidden). It is saved to `~/.config/slp-room/oauth-token`
   (mode 600) and reused on every later run.

3. Open an agent on the **Supervisor** profile in Paseo and describe the goal — no `/supervisor` needed.

Run the same command again whenever you want the latest version; add
`-s -- --token` (`./install.sh --token` in a clone) to replace the token.

**No subscription token?** Point the seats at any Anthropic-compatible proxy or
gateway (9router, OmniRoute, CLIProxyAPI, LiteLLM, …) instead: at the prompt
choose *2*, or run with `--endpoint` (`-s -- --endpoint` when piped), then give
its base URL and key. See [Custom endpoint](#custom-endpoint-instead-of-a-token).
Or skip the prompts and pass both in one command — the variables go after the
pipe, on the `bash` side:

```sh
curl -fsSL https://raw.githubusercontent.com/yanmad27/paseo-slp/main/install.sh | SLP_CLAUDE_BASE_URL=https://gateway.example.com SLP_CLAUDE_AUTH_TOKEN=<key> bash
```

## Install

`install.sh` is the one script for installing and updating. Each run:

0. removes v1 if it is there — the `orchestrate@my-orchestrate-skill` plugin
   and marketplace (see [Upgrade](#upgrade));
1. copies the `/supervisor` skill to `~/.claude/skills/supervisor` (and
   removes a v1 `~/.claude/skills/orchestrate` copy);
2. builds the per-seat runtimes in `~/.config/slp-room` — Claude for the
   Supervisor, Lead, and Peers, Codex for the Codex Peers (see
   [Role prompts](#role-prompts));
3. writes the room's profiles and providers into `~/.paseo/config.json`,
   backing up the old file as `config.json.bak-<timestamp>`;
4. runs `paseo daemon reload`;
5. installs [slp-gc](#slp-gc) and its launchd agent — in the default and `--paseo-only` modes unless you pass `--no-gc`.

Piped, it downloads the repository from GitHub; from a clone
(`git clone https://github.com/yanmad27/paseo-slp.git && cd paseo-slp && ./install.sh`)
it uses the checkout.

| Option | Effect |
|---|---|
| `--skill-only` | Only steps 0-1 |
| `--paseo-only` | Only steps 0 and 2-5 — e.g. when the skill comes from the plugin marketplace |
| `--no-reload` | Skip `paseo daemon reload` |
| `--gc-only`, `--no-gc`, `--no-gc-launchd`, `--gc-apply`, `--gc-kill-stale`, `--gc-kill-memory`, `--gc-kill`, `--gc-report-only` | slp-gc install and opt-ins — see [slp-gc](#slp-gc) |
| `SLP_REF=<branch or tag>` | Install that version instead of `main` (piped runs) |
| `SLP_ROOM_HOME=<dir>` | Build the runtimes somewhere other than `~/.config/slp-room` |
| `--token` | Ask for a new Claude token and replace the saved one (e.g. to rotate it) |
| `SLP_CLAUDE_OAUTH_TOKEN=<token>` | Use this token instead of `~/.config/slp-room/oauth-token` (no prompt) |
| `--endpoint` | Ask for a custom Anthropic-compatible base URL and key (and how to send it) instead of a token |
| `SLP_CLAUDE_BASE_URL=<url>` `SLP_CLAUDE_AUTH_TOKEN=<key>` | Use this endpoint and key, saved for later runs (no prompt; the key is never taken as an argument). `SLP_CLAUDE_API_KEY` is still accepted as an older alias for `SLP_CLAUDE_AUTH_TOKEN`; if both are set and differ, the install stops before changing anything |
| `SLP_CLAUDE_AUTH_HEADER=bearer\|x-api-key` | How the key is sent; default `bearer` |

> [!NOTE]
> Plugin marketplace alternative: `/plugin marketplace add yanmad27/paseo-slp`, then (in a separate turn) `/plugin install paseo-slp@paseo-slp`, then run `install.sh --paseo-only`. Don't combine the plugin with a full `install.sh` run, or you get the skill twice.

> [!NOTE]
> You do **not** need Paseo's built-in skills (`paseo`, `paseo-committee`, `paseo-advisor`, `paseo-handoff`, …). Leads run their own committee and plan review using the Review peer and Codex review peer profiles. Leave the built-ins uninstalled to avoid a Lead picking up a competing delegation workflow.

## Paseo configuration

`install.sh` writes eight agent profiles and three providers into
`~/.paseo/config.json`. Every Lead and Peer seat runs with full permissions
(Claude `bypassPermissions`, Codex `full-access`); reviewers are read-only
because their brief says so. Thinking: Supervisor extra high, Lead high,
review peers high, every other Peer medium.

| Profile | Provider | Model | Mode | Use for |
|---|---|---|---|---|
| **Supervisor** | `claude-supervisor` | `claude-opus-5-5` (thinking: xhigh) | `bypassPermissions` | The seat you talk to; the Supervisor role is its system prompt. Extra-high thinking for judging drift; every inspection (each `slp-wait` timeout or heartbeat wake, about every 2 minutes) is a turn at that level. |
| **Lead** | `claude-lead` | `claude-opus-5-5` (thinking: high) | `bypassPermissions` | Launched by the Supervisor: owns one project's technical outcome, dispatches Peers, accepts or rejects candidates |
| **Cheap peer** | `claude-peer` | `claude-haiku-4-5` (thinking: medium) | `bypassPermissions` | Extraction, formatting, log triage, mechanical refactors — the down-tier target |
| **Peer** | `claude-peer` | `claude-sonnet-5-5` (thinking: medium) | `bypassPermissions` | Default tier for implementation, debugging, and research |
| **Expensive peer** | `claude-peer` | `claude-opus-5-5` (thinking: medium) | `bypassPermissions` | Hard problems only: architecture decisions, cross-module refactors with invariants, subtle concurrency/data bugs — chosen by Jev routing or escalation, never by default |
| **Review peer** | `claude-peer` | `claude-sonnet-5-5` (thinking: high) | `bypassPermissions` | Read-only Peer: reviews Codex-written candidates (and security-sensitive ones with `security-review`), architecture questions, committee member |
| **Codex peer** | `codex-peer` | `gpt-5.6-sol` (thinking: medium) | `full-access` | Writable Peer from another model family — only when you ask for Codex, or to retry a task a Claude Peer already failed. Not a tier. |
| **Codex review peer** | `codex-peer` | `gpt-5.6-sol` (thinking: high) | `full-access` | Read-only cross-family reviewer of Claude-written candidates, plan reviewer, committee member, debate tie-breaker |

| Provider | Extends | Agent tools |
|---|---|---|
| `claude-supervisor` | `claude` | Every Paseo tool: launching Leads, heartbeats, recovery. No `paseo run`/`send`/`import` from Bash — agents only come from `create_agent`. The only seat that runs `slp-wait` |
| `claude-lead` | `claude` | Everything a Lead needs to launch and steer Peers; no heartbeat/schedule control (monitoring is the Supervisor's); no `slp-wait` |
| `claude-peer`, `codex-peer` | `claude`, `codex` | `send_agent_prompt` (to talk back to the Lead) and the read-only status tools; no `create_agent`, `cancel_agent`, `kill_agent`, `archive_agent`, `update_agent`, `set_agent_mode`, workspace creation, schedule/heartbeat control, `respond_to_permission`, or `slp-wait` |

**Spawning is controlled.** Only `create_agent` creates agents, and only
the Supervisor (Leads) and Leads (Peers) have it. Every Claude seat also
loses the built-in `Agent`/`Task` sub-agent tool and cannot start nested
`claude`/`codex` runs from Bash — by name or by the absolute path of any copy
on your `PATH` (and its symlink target), found at install time; Leads and
Peers cannot use the `paseo` CLI at all (so no `paseo run` around the MCP
tools). The Supervisor's one extra is `slp-wait`, installed beside the room
files (`~/.config/slp-room/bin/slp-wait`), which blocks on a single agent and
only ever calls `paseo wait`; Leads and Peers are denied it by name and by
path. Codex Peers get the same through their runtime's execpolicy rules
(enforced even in full access, and through `zsh -lc` wrappers), plus
native sub-agents off (`agents.enabled`, `features.multi_agent`,
`features.multi_agent_v2`). What remains is prompt-level: a script that
calls one of them from a location the installer did not see.

### Role prompts

Paseo has no per-agent system prompt, so the role lives in the provider — the
way codex-room-setup does it with one `CODEX_HOME` per role:

- **`claude-supervisor`, `claude-lead`, `claude-peer`** each run in their own
  Claude Code runtime, `~/.config/slp-room/claude-{supervisor,lead,peer}`, via
  `CLAUDE_CONFIG_DIR`. The runtime's **output style** `slp-<seat>` is
  `PROTOCOL.md` + the seat's role with `keep-coding-instructions: true`, so
  the role is part of the system prompt and survives compaction. The runtime
  copies your `~/.claude/settings.json` (plus the output style), links your
  plugins, agents, commands, `CLAUDE.md`, and every skill **except
  `supervisor`** — no seat loads the `/supervisor` skill on top of its own
  role. Every seat's `ROOM_DIR` is the stable copy in
  `~/.config/slp-room/room`.
- **Auth** is shared through one `claude setup-token` token. `install.sh`
  asks for it on the terminal when it has none (or with `--token`), keeps it
  in `~/.config/slp-room/oauth-token` (mode 600), puts it into every Claude
  seat's provider as `CLAUDE_CODE_OAUTH_TOKEN`, and keeps
  `~/.paseo/config.json` and its backups at mode `600`. Without a token it
  leaves the variable out; then log in once per runtime instead:
  `CLAUDE_CONFIG_DIR=~/.config/slp-room/claude-<supervisor|lead|peer> claude`
  → `/login`. Instead of a token you can use a custom endpoint, below.
- **`codex-peer`** runs Codex in its own runtime too, `CODEX_HOME=~/.config/slp-room/codex-peer`
  (as codex-room-setup does): `auth.json` linked to yours, a copy of your
  `config.toml`, your `AGENTS.md`/skills/plugins, and `rules/room.rules`
  that forbids `paseo`/`claude`/`codex`. The launcher
  `~/.config/slp-room/bin/codex-peer` passes the Peer prompt as
  `-c developer_instructions='''…'''`.

Briefs still name the room files, so a seat launched without its prompt
reads them instead.

### Custom endpoint instead of a token

Any Anthropic-compatible proxy or gateway works (examples: 9router, OmniRoute,
CLIProxyAPI, LiteLLM); nothing about it is assumed beyond a base URL and a key,
and model names are not remapped. Every Claude seat's provider then gets
`ANTHROPIC_BASE_URL` plus exactly one key variable, and never
`CLAUDE_CODE_OAUTH_TOKEN`:

| Key sent as | Provider env | Pick with |
|---|---|---|
| `Authorization: Bearer <key>` (default) | `ANTHROPIC_AUTH_TOKEN` | `SLP_CLAUDE_AUTH_HEADER=bearer`, or option 1 at the prompt |
| `x-api-key: <key>` | `ANTHROPIC_API_KEY` | `SLP_CLAUDE_AUTH_HEADER=x-api-key`, or option 2 |

`x-api-key` renders `ANTHROPIC_API_KEY`, which Claude may ask to approve in an
interactive session; Bearer, the default, avoids that.

Interactive: choose *2* at the sign-in prompt, or run `install.sh --endpoint`
(base URL, then the key with hidden input, then the header form; Enter keeps
what is saved). Non-interactive:

```sh
curl -fsSL https://raw.githubusercontent.com/yanmad27/paseo-slp/main/install.sh | SLP_CLAUDE_BASE_URL=https://gateway.example.com SLP_CLAUDE_AUTH_TOKEN=<key> bash
```

The variables sit on the `bash` side of the pipe; placed before `curl` they
would never reach the script. Add `SLP_CLAUDE_AUTH_HEADER=x-api-key` there to
send the key as `x-api-key`. From a clone:
`SLP_CLAUDE_BASE_URL=https://gateway.example.com SLP_CLAUDE_AUTH_TOKEN=<key> ./install.sh`

The Claude CLI appends `/v1/messages` itself, so the base URL normally has no
`/v1`; check your proxy's docs for Anthropic clients. It must be an `http://`
or `https://` URL without whitespace (a trailing `/` is dropped; credentials in
it are kept but never printed). The key is opaque: surrounding whitespace,
including a trailing newline, is trimmed; the key may not be empty or contain
a line break inside it. Both
are saved in `~/.config/slp-room/anthropic-base-url` / `anthropic-api-key` /
`anthropic-auth-header` (mode 600), the mode in `auth-mode`. In this mode the
`CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_*` keys in your `~/.claude/settings.json`
`env` are left out of the runtimes' copies (with a warning naming the keys).

Which mode applies:

- `SLP_CLAUDE_*` and `--token` / `--endpoint` pick the mode; with none of them
  the saved mode is used (`token` when nothing is saved, so existing installs
  behave as before). Asking for both kinds at once (for example
  `SLP_CLAUDE_OAUTH_TOKEN` with `SLP_CLAUDE_BASE_URL`, or `--token` with
  `--endpoint`) is an error, reported before anything is changed.
- Without a terminal, `--token` keeps the saved token and `--endpoint` uses the
  saved endpoint (an error if none is complete).
- A token request that yields no token (Enter, a bad paste, nothing saved)
  keeps the saved endpoint when the saved mode is `endpoint`, and says so.
- `auth-mode` becomes `token` only when a token is saved in `oauth-token`
  (pasted, or `--token` with one already there). `SLP_CLAUDE_OAUTH_TOKEN` is
  used for that run only, as before, and changes nothing saved.
- The header form, in order: `SLP_CLAUDE_AUTH_HEADER` if set (which also skips
  the header prompt, like `SLP_CLAUDE_BASE_URL` and `SLP_CLAUDE_AUTH_TOKEN` skip
  theirs); otherwise the interactive choice, when the prompt runs (Enter keeps
  what the next rules give); otherwise `bearer` when `SLP_CLAUDE_BASE_URL` is
  set; otherwise the saved one; otherwise `bearer`. Rotating only
  `SLP_CLAUDE_AUTH_TOKEN` keeps the saved header.

### What the installer owns

Each run resets the room's profiles (matched by `id`, or by name for
profiles an old installer left without one), the `claude-lead`/`claude-peer`/
`codex-peer` providers, `~/.claude/skills/supervisor`, and the generated
files in `~/.config/slp-room` to this version (your `oauth-token`, saved endpoint files, and each
runtime's session history stay); removes the v1 profiles and the v1
`claude-worker` provider; and leaves every other profile and provider alone.
A model you change in the Paseo UI on a room profile is overwritten on the
next run — copy the profile under a new name for a personal variant.
`paseo/config.snippet.json` contains `@@ROOM_HOME@@` placeholders, so don't
merge it by hand.

## Restart & verify

`install.sh` reloads the daemon itself. If profiles still don't appear, run
`paseo daemon restart`, or quit and restart the Paseo desktop app.

Then check the Paseo agent creation dialog — it should show eight profiles:
**Supervisor**, **Lead**, **Cheap peer**, **Peer**, **Expensive peer**, **Review peer**, **Codex peer**, and **Codex review peer**.

## Upgrade

Re-run the install command — piped, or `git pull && ./install.sh` in a
clone. It updates the skill, the role prompts, and the Paseo profiles
together, then reloads the daemon. With the plugin marketplace instead, run
`claude plugin update paseo-slp@paseo-slp` (then
`/reload-plugins` in an open session) and `install.sh --paseo-only`.

**From v1 (`/orchestrate`, repo `my-orchestrate-skill`):** the project is now
`paseo-slp`, and the same install command removes v1 for you:

- the v1 plugin `orchestrate@my-orchestrate-skill` (user scope) and its
  `my-orchestrate-skill` marketplace — via `claude plugin uninstall` /
  `claude plugin marketplace remove`;
- a v1 skill copy in `~/.claude/skills/orchestrate`, and any v1 watchdog
  still polling;
- the **Cheap worker**, **Worker**, **Expensive worker**, **Reviewer**, and
  **Codex advisor** profiles and the `claude-worker` provider.

It only reports a v1 plugin installed at *project* scope, since that lives
in another repository's settings. To remove v1 by hand instead (one command
per turn in Claude Code):

```
/plugin uninstall orchestrate@my-orchestrate-skill
/plugin marketplace remove my-orchestrate-skill
```

Then install `paseo-slp` as in [Quick start](#quick-start) — or, if you
prefer the plugin, `/plugin marketplace add yanmad27/paseo-slp`,
`/plugin install paseo-slp@paseo-slp`, and `install.sh --paseo-only`.
`/orchestrate` is gone: open the Supervisor profile, or use `/supervisor`.

**Supervisor heartbeat name:** the Supervisor now keeps one heartbeat per
session under the fixed name `supervisor: room`. Heartbeats an older version
created under `supervisor: <free-form scope>` are not matched by it; they stop
when that Supervisor agent is archived.

**Check version:** the last line of `install.sh` output, or the header of
`~/.config/slp-room/lead.md`. Compare with the
[releases page](https://github.com/yanmad27/paseo-slp/releases).

## slp-gc

`slp-gc` is a standalone garbage collector and memory diagnostic for a Paseo
home. On a 16 GB Mac, test-runner `node` processes spawned by agents were
orphaned, showed up as Paseo, and grew to about 4.5 GB each; ten of them
froze the machine. `slp-gc` reports and alerts on this and, by default,
reclaims the *safe tier*: it deletes completed schedules and long-archived
agents through the `paseo` CLI and SIGTERMs proven orphaned processes.
SIGTERMing over-memory agent descendants (kill-memory) stays a separate opt-in.

**Install.** A normal `install.sh` run (and `--paseo-only`) also installs it,
unless you pass `--no-gc`. To install just slp-gc — no seats, no Paseo config,
no daemon reload — run `./install.sh --gc-only` (needs `jq`). It:

- copies `slp-gc` to `~/.config/slp-room/bin/slp-gc`, next to `slp-wait`;
- writes `~/Library/LaunchAgents/com.paseo-slp.slp-gc.plist` and loads it with
  `launchctl bootstrap`: `slp-gc tick` every 60 s, at low priority, independent
  of the Paseo daemon (no `--apply` in its arguments, ever: what it reclaims
  comes from `slp-gc.conf`). It checks that
  `jq` (and `paseo`, if found) resolve under the agent's minimal `PATH`
  (`/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`), adds their
  directory after those if they live elsewhere, and refuses to go on without `jq`;
- writes `~/.config/slp-room/slp-gc.conf` only if none exists, with the safe tier
  on (`SLP_GC_APPLY=1`, `SLP_GC_KILL_STALE=1`, `SLP_GC_KILL_MEMORY=0`) — a re-run
  never resets it. An existing config is never migrated, because an old untouched
  all-zero default and a deliberate `--gc-report-only` look identical. When a
  re-run without any `--gc-*` flag finds `SLP_GC_APPLY` not `1`, the summary prints
  a one-line notice with the command to opt in
  (`install.sh --gc-apply --gc-kill-stale`, plus `--gc-only` to touch nothing else).
  Without a readable config file `slp-gc tick` itself stays report-only.

`--no-gc` skips all of this; `--no-gc-launchd` installs the tool and config but
no agent. Either way, an agent from an earlier install is left running and the
summary says so, with how to remove it.

**Default: the safe tier.** Every tick records a memory sample, writes a report
hourly, alerts when memory climbs, deletes completed room schedules and
long-archived agents, and SIGTERMs proven orphaned processes (same eligibility
rules as ever; at most `SLP_GC_MAX_KILLS` per tick). It never kills an agent
descendant for memory unless you opt in to kill-memory. `install.sh --gc-report-only`
turns all reclaiming off: ticks then only sample, report and alert.

**By hand.**

```bash
~/.config/slp-room/bin/slp-gc report   # read-only snapshot: processes, agents, garbage candidates
~/.config/slp-room/bin/slp-gc report --json   # the same, machine-readable, with .candidates (action tokens)
~/.config/slp-room/bin/slp-gc record   # append one memory sample (delivers a real alert to a Supervisor)
~/.config/slp-room/bin/slp-gc test-alert   # send one marked TEST message to that Supervisor
~/.config/slp-room/bin/slp-gc tick     # what launchd runs
```

`slp-gc --help` lists every option. Tunables (in `slp-gc.conf`, all optional):
`SLP_GC_MEM_WARN_MB` (3072), `SLP_GC_MEM_KILL_MB` (4096), `SLP_GC_TREE_WARN_MB`
(50% of RAM), `SLP_GC_KILL_COMMS` (alias `SLP_GC_ORPHAN_COMMS`),
`SLP_GC_ORPHAN_MIN_AGE_MIN` (10), `SLP_GC_TEST_CONCURRENCY_WARN` (3),
`SLP_GC_MAX_KILLS` (20 per tick), `SLP_GC_TICK_BUDGET_S` (45),
`SLP_GC_REPORT_INTERVAL_MIN` (60), `SLP_GC_ALERT_SUPERVISOR` (1).

**Supervisor alerts.** When `record` raises a real alert (inside the existing
15-minute rate limit, so never more often), slp-gc still writes `alerts.log`
and the macOS notification and then delivers **one** message to the most recently
used open Supervisor: `paseo agent send --home <home> --no-wait --prompt-file <0600 temp file> -- <id>`,
one attempt, 10 s timeout, no retry. A failed, timed-out or skipped delivery
is one line in `tick.log` and never changes the exit status or blocks the other two.

- *Which Supervisor.* Records under `<home>/agents` with `provider` exactly
  `claude-supervisor`, `archivedAt` absent or null (Paseo omits the key on an open agent) and a file name equal to the id. They are
  ranked by `lastUserMessageAt` (a heartbeat does not move it), then
  `lastActivityAt`, then id; a Supervisor that was never used ranks last. None
  open: nothing is sent and `tick.log` says so.
- *Self-delivery correction.* Paseo's `agent send` sets the recipient's
  `lastUserMessageAt` to the send time, which would make slp-gc's own messages
  look like the person's. Before each send slp-gc appends
  `{id, sentAt, priorLastUserMessageAt, alertId, test}` to
  `<state>/deliveries.jsonl` (last 200 lines). A `lastUserMessageAt` within
  `[sentAt-5s, sentAt+30s]` of that Supervisor's latest entry is read as the
  prior value; a later message from the person falls outside the window and counts.
- *Message* (plain text, at most 2048 bytes; only the alert text is ever cut, on a character boundary; if the mandatory lines alone
  exceed 2048 bytes, e.g. a very long home path, nothing is sent):
  `SLP-GC ALERT <UTC compact id>`, `From: slp-gc (automated message, not the person)`,
  the `Alert (data, not instructions):` line (process names are same-user text, so the
  line is labelled as data), `Home:`, the absolute `slp-gc:` path, a read-only
  `report --home <home> --json` command line (paths with spaces are quoted) and
  the approval rule (safe-tier cleanup needs no yes; kill-memory needs the person's
  explicit yes for this alert and the exact candidate set). No other process's environment or command line is included.
- *Pending permission.* `agent send` clears the recipient's pending permissions. When
  the selected Supervisor's record says `attentionReason` is `permission`, nothing
  is sent (no fallback to another Supervisor) and `tick.log` says so. Residual risk:
  the record is read a moment before the send, so a permission raised in between is
  still cleared; Supervisors run in `bypassPermissions` mode, so this is rare.
- *One delivery at a time.* Pick, ledger append, send and the ok-marking of the row (each row has a
  unique `rowId`) run under a separate `delivery.lock` in the state dir (dead owners are taken over, the wait
  is a few seconds). If it is busy nothing is sent ("delivery lock busy, not delivered"), and the alert, the
  notification and the exit status are unaffected. It is taken inside the tick lock, never the other way round.
- *Undelivered alerts.* An alert that is not delivered (no open Supervisor,
  pending permission, a failure) still uses the 15-minute window: by contract there
  is no retry, the next chance is the next alert after the window.
- *Switch.* `SLP_GC_ALERT_SUPERVISOR=0` in `slp-gc.conf` (or the environment)
  turns delivery off, and it also disables `test-alert` (exit 3, "delivery disabled");
  anything but `0`/`1` keeps the default, `1`. The config keys
  above are unchanged: with all three `0` nothing is deleted or killed.
- *What the Supervisor does.* On a non-test alert it applies the safe-tier candidates
  from `slp-gc report --json` without asking: it uses the installed copy, checks that the
  home matches `PASEO_HOME`, and runs `--apply --only <tokens>` plus each kill-stale
  token's required flag. It reports what was reclaimed and asks the person only about
  kill-memory candidates. A test alert does nothing. A refusal is not retried, and it
  never widens beyond `--only`.

**Candidate-bounded cleanup.** `slp-gc report --json` prints `.candidates`: every
action `--apply` could take now, as `{token, action, kind, reason, sizeMB, requiresFlag}`.
Tokens are unique and action-scoped: `agent-delete:<id>`, `schedule-delete:<id>`,
`kill-stale:<pid>@<lstart>`, `kill-memory:<pid>@<lstart>`. `slp-gc report --apply --only <token>[,<token>...]`
(plus `--kill-stale-processes` / `--kill-over-memory` for `kill-*` tokens) first
checks **every** named token against the current candidates and the flags; if any
is unknown, of another action, has a changed pid start time or lacks its flag, it
exits 2 and does nothing. Otherwise it acts on the named tokens only, with the
usual per-action re-checks (an item that changed since is skipped and reported).
Without `--only` nothing changes. `slp-gc test-alert [--home <dir>]` sends one
message marked `SLP-GC ALERT (TEST)` and `TEST ONLY` to the same Supervisor
and writes only the delivery ledger (under the tick lock; no `alerts.log`, no rate-limit stamp, no
notification, no cleanup); it prints the Supervisor id and exits 0 delivered,
3 nothing sent on purpose (no open Supervisor, pending permission, delivery disabled), 1 not delivered (send failed, or the ledger row could not be written).


**Identification without an environment.** The Paseo app's own "Paseo Supervisor"
process rewrites its title, so `ps -E` shows no environment for it. When its
environment is unreadable, slp-gc accepts its home binding only if it holds
`<home>/daemon.log` open for writing (`lsof -F fan`) and no other home's
`daemon.log`; anything else (no entry, another home, both) still refuses
`--apply`. A readable environment is used as before. The report's
`identification:` line says which source proved it (`home via env|lsof`).

**Test mode.** With `SLP_GC_TEST=1` (fixtures only) an unset notifier, `paseo`
CLI or `kill` override falls back to an inert no-op — never `osascript`, `PATH`,
the ambient `PASEO_CLI`, the Paseo.app bundle, a real `kill` binary or a terminating
signal (a signal-0 liveness probe, which terminates nothing, is still allowed) — and `scripts/validate.sh` fails if a
fixture runs slp-gc outside the sandboxed wrappers.

**Output** lands in `~/Library/Logs/slp-gc` (`SLP_GC_STATE_DIR` overrides):
`memory.jsonl` (samples), `alerts.log`, `reports/`, `lineage.tsv` (the lineage
ledger that proves an orphan), `tick.log` (rotated), and `launchd.log` (only
alerts and errors; rotated by tick). The state dir must be a real directory you
own — a symlink is refused, and so is a symlinked or special-file config or log.

**When memory climbs,** run `slp-gc report` and look at the orphans and the
per-agent process trees: an orphan is a test runner whose agent is gone, a big
tree is an agent still running one. Stop the agent with `paseo agent stop`, or
opt in to kill-memory below.

**Opt in / out.** What slp-gc reclaims is set in `~/.config/slp-room/slp-gc.conf`
(`KEY=VALUE`, on only when exactly `1`), or with install flags, which edit only
those keys. A fresh install writes `SLP_GC_APPLY=1`, `SLP_GC_KILL_STALE=1`,
`SLP_GC_KILL_MEMORY=0`; kill-memory is the one opt-in. The kill flags need `--gc-apply`
on the same command line, and `--gc-report-only` cannot be combined with them. When
the agent is loaded with a flag on, the install summary names each active one.

| Flag | Config key | Effect |
|---|---|---|
| `--gc-apply` | `SLP_GC_APPLY=1` (fresh-install default) | Delete completed room schedules and long-archived agents via `paseo` |
| `--gc-kill-stale` | `SLP_GC_KILL_STALE=1` (fresh-install default) | SIGTERM proven orphaned processes |
| `--gc-kill-memory` | `SLP_GC_KILL_MEMORY=1` (off by default) | SIGTERM an agent descendant above `SLP_GC_MEM_KILL_MB` |
| `--gc-kill` | both kill keys | Shorthand for the two kill flags |
| `--gc-report-only` | all three `=0` | Back to report-only (all reclaiming off) |

The launchd agent is only loaded when `HOME` is your own login home; for any
other `HOME` the plist is written and the install warns that the agent is
**not loaded**. The summary also says when an older definition is still loaded
because a `launchctl` step failed.

**Uninstall.**

```bash
launchctl bootout gui/$(id -u)/com.paseo-slp.slp-gc
rm ~/Library/LaunchAgents/com.paseo-slp.slp-gc.plist
rm ~/.config/slp-room/bin/slp-gc ~/.config/slp-room/slp-gc.conf   # optional
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The Supervisor replies *"This chat's provider has create_agent disabled"* | Your agent's provider isn't `claude-supervisor` or `claude` (e.g. it's `claude-peer`, which strips `create_agent`), or `daemon.mcp.injectIntoAgents` isn't `true` in `~/.paseo/config.json`. Check the config against [Requirements](#requirements). |
| A Lead ends with `BLOCKED: create_agent unavailable` | The Lead was launched on a provider without agent tools. Check the **Lead** profile uses provider `claude-lead`. |
| A seat answers *"Not logged in · Please run /login"* | Its runtime has no auth: no token was given, or it expired. Run `claude setup-token`, then re-run the install command with `--token` and paste the new line. |
| A Lead or Peer doesn't follow its role, or its first action is reading `PROTOCOL.md` | It launched without its role prompt. Re-run `install.sh`; check `~/.config/slp-room/claude-{lead,peer}/output-styles/` and that the providers' `CLAUDE_CONFIG_DIR` points there. |
| A Lead or Peer lacks a skill or setting you added to `~/.claude` | Runtimes copy your settings at install time. Re-run `install.sh` after changing `~/.claude/settings.json` or adding skills. |
| A `codex-peer` agent fails to start after moving or reinstalling Codex | The launcher holds the `codex` path from install time. Re-run `install.sh`. |
| A Codex Peer is not logged in | Its runtime links `~/.codex/auth.json`. Run `codex login` (file credentials, not the keyring) and re-run `install.sh`. |
| The Supervisor tab keeps spinning, with a state like `🕒 Working` and one `🤖` row per Lead (its `🦾` Peers indented under it with `&emsp;&ensp;`) | Expected: it is waiting on a running room agent with `slp-wait` (110 s, then it inspects the room and waits again), so only the Supervisor tab spins. The Supervisor prints `🕒 Working` before each wait and ends a turn only with `✅ Done` or `❓ Waiting on you`, or on `🕒` if `slp-wait` failed or it just answered you. |
| The Supervisor tab stops spinning for a while after I send a message | Expected. A Supervisor that keeps spinning after a message answers only in hidden thinking, so it writes its answer and a `🕒 Working` block of `🤖` Lead rows as visible text and ends the turn; its heartbeat (every 2 minutes, only while it is idle) wakes it, inspects the room, and re-arms the wait. The gap is normally up to 2 minutes, rarely up to about 4 if Paseo skips a heartbeat slot; answer and state stay visible during it. This is a known Paseo-side limit: a slot that fires while the Supervisor is still finishing its turn is skipped, not queued (the next is 2 minutes later), and the scheduler can occasionally record a skipped slot twice, pushing the next fire one more slot. |
| A Supervisor heartbeat (`*/2 * * * *`, named `supervisor: room`) is left after the session closed | Archiving the Supervisor agent completes its heartbeats. A new Supervisor adopting the room checks the old one once and, if it is still active, asks you to archive it or close the new session; it never deletes another session's heartbeat. Heartbeats do not show in Paseo's schedule list. |
| A seat stops with "The user doesn't want to proceed with this tool use" on an `slp-wait` | That text means a message or notification arrived and cut the wait short — nothing was refused. The Supervisor handles the event and waits again. After a message from you its spinner pauses and the heartbeat resumes it: normally within 2 minutes, rarely up to about 4 if Paseo skips a heartbeat slot (the next slot usually resumes it; rarely the scheduler pushes it one more slot, about 4 minutes in all; any message to the Supervisor also resumes it). Known Paseo-side limit: a slot firing while the turn is still ending is skipped, not queued, and the scheduler can occasionally record a skipped slot twice, which pushes the next fire one more slot. Only a longer idle stretch while work runs is a fault (then tell it to resume). |
| `slp-wait` fails (exit 1, not found) | The Supervisor falls back to ending its turn and being woken by notifications and the heartbeat, and says so. Check `~/.config/slp-room/bin/slp-wait --self-test` and re-run `install.sh`. |
| `/supervisor` is not found after a plugin install | Plugin skills are namespaced: try `/paseo-slp:supervisor`, or just ask in plain language ("supervisor: …", "delegate this …"). |
| A room profile lost a model you set in the Paseo UI | Expected: the installer resets room profiles. Copy the profile under a new name for a personal variant. |
| Profiles missing after install | `paseo daemon reload` failed or was skipped, or `~/.paseo/config.json` has invalid JSON. Verify with `jq . ~/.paseo/config.json`, then run `paseo daemon reload`. |

## Usage

### Start

Open an agent on the **Supervisor** profile and just describe the goal — the
Supervisor role is that agent's system prompt, so there is nothing to type
first. You never need to open a Lead's tab; the Supervisor brings
everything that needs you back to this chat.

```
thêm validate cho parse_age trong app.py, có test; được commit local, không push
```

### From any other Claude agent

On a plain `claude` agent (it has `create_agent` as long as
`daemon.mcp.injectIntoAgents` is on), load the role as a skill:

```
/supervisor <task>
```

It also auto-triggers on supervision or delegation requests in natural
language, though the model decides when:
- `supervisor: add rate limiting to POST /login`
- `orchestrate this bug fix`
- `giao cho worker fix cái bug này`

To pick up Leads still running from an earlier Supervisor session, tell a
new Supervisor to supervise that workspace or Lead — it adopts them without
interrupting their work.

### Examples

| Task | Room |
|---|---|
| `/supervisor rename UserSvc to UserService across the repo` | 1 Lead → **Cheap peer** |
| `/supervisor add rate limiting to the POST /login endpoint` | 1 Lead → **Peer** → **Codex review peer** |
| `/supervisor why does CI keep timing out on main?` | 1 Lead → **Peer** (investigate) → **Peer** (fix) → **Codex review peer** |
| `/supervisor fix the flaky upload test — use Codex for this one` | 1 Lead → **Codex peer** → **Review peer** (Claude reviews Codex's work) |
| `/supervisor migrate the API to v2 and update the web client` | 2 Leads (API, web) in separate worktrees, the web Lead waiting on the API's accepted contract |
| `/supervisor find the race condition causing duplicate webhook deliveries` | 1 Lead → **Expensive peer** (Jev-routed) → **Codex review peer** + **Review peer** |

### What happens

1. The Supervisor reads the room protocol and pins down your intent —
   outcome, non-goals, authority, acceptance evidence — asking you only if a
   gap would let the room drift.
2. It splits the goal into Lead workstreams (usually one), launches each
   Lead with that intent as a self-contained project instruction, starts a
   2-minute Paseo heartbeat (`supervisor: room`, the fallback while it is
   idle), waits on the running room agent so its own tab shows the room
   running, and checks each Lead's plan against your intent as soon as the
   Lead reports it.
3. Each Lead plans, picks a Peer tier per task (Jev or the manual rule), gets
   a plan review for larger plans, and dispatches Peers with a brief that
   names their write scope and acceptance evidence.
4. Peers either deliver a `CANDIDATE` or challenge the brief; the Lead
   concedes or holds with evidence (max two rounds). Implementation work gets
   a read-only review from the other model family — Codex reviews Claude's
   work, Claude reviews Codex's — before the Lead `ACCEPT`s it.
5. After every `slp-wait` return (at most 110 s) and on each heartbeat wake,
   the Supervisor inspects the room — Leads, Peers, and the repo — for drift: wrong target, scope creep, rabbit holes,
   unauthorized actions, acceptance without evidence, open loops, stalls. It
   asks the Lead an evidence-based question only when there is a concrete
   gap, brings drift that changes what you get to you, and pulls an
   emergency brake on unauthorized external or destructive actions.
   Otherwise it stays quiet and ends with a room-state block.
6. Decisions that are yours (scope, cost, external effects, irreversible
   risk, destructive permissions) come back to you as a recommendation with
   its consequence.
7. The final report opens with one recap line per Lead and its Peers, then
   results against your intent — which acceptance evidence is met and which
   is not — any drift it caught, and anything unresolved.

### Tips

- **Give acceptance criteria:** "rename to snake_case and update all imports" beats "refactor this". Leads and Peers see none of this conversation.
- **State authority:** say whether the room may commit, push, open a PR, or deploy — technical acceptance never implies it.
- **Say "read-only"** if you want an audit, investigation, or code review without file changes.
- **Watch the sidebar:** parallel Leads or parallel writing Peers get worktree tabs — avoid switching tabs while they run.
- **Permission prompts are yours:** nobody in the room auto-approves destructive actions.
- **No polling:** no seat `sleep`-loops on CI or on each other. Only the Supervisor waits, with `slp-wait` (one blocking call on one agent, woken by any message); the heartbeat covers the times it is not waiting. Leads end their turn and are woken by notifications. If you see a permission prompt containing `sleep … done`, deny it — it's a brief bug.
- **A Lead reports `DONE` only when none of its Peers is still running** — otherwise `STATUS`, and the Supervisor sends a premature `DONE` back.
