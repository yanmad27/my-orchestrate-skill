# orchestrate

A Claude Code plugin for a three-seat room in Paseo — **S**upervisor →
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

[![License: MIT](https://img.shields.io/github/license/yanmad27/my-orchestrate-skill)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/yanmad27/my-orchestrate-skill)](https://github.com/yanmad27/my-orchestrate-skill/releases)
[![Works with Paseo](https://img.shields.io/badge/works%20with-Paseo-2b6cb0)](https://paseo.sh)

## Contents

- [Room model](#room-model)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Install](#install)
- [Paseo configuration](#paseo-configuration)
- [Restart & verify](#restart--verify)
- [Upgrade](#upgrade)
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
agent by interrupting its turn, a Peer only sends when its Lead is idle, and
the Lead's short answer lets the Peer resume where it was.

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

- Claude Code (with a subscription, for `claude setup-token`), and the Codex CLI for the Codex Peers
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

1. Create one Claude token for the Lead/Peer runtimes and save it (it never
   needs to go anywhere else):

   ```sh
   claude setup-token        # log in in the browser, paste the code back here
   # copy the printed sk-ant-oat01-… line, then:
   mkdir -p ~/.config/slp-room && pbpaste | tr -d '[:space:]' > ~/.config/slp-room/oauth-token && chmod 600 ~/.config/slp-room/oauth-token
   ```

2. Install everything — the `/supervisor` skill, the Lead/Peer runtimes and
   role prompts, and the Paseo profiles — and reload the Paseo daemon:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/yanmad27/my-orchestrate-skill/main/install.sh | bash
   ```

3. Open an agent on the **Supervisor** profile in Paseo and describe the goal — no `/supervisor` needed.

Run the same command again whenever you want the latest version.

## Install

`install.sh` is the one script for installing and updating. Each run:

1. copies the `/supervisor` skill to `~/.claude/skills/supervisor` (and
   removes a v1 `~/.claude/skills/orchestrate` copy);
2. builds a Claude runtime for the Lead and for the Peers, and the Codex
   launcher, in `~/.config/slp-room` (see [Role prompts](#role-prompts));
3. writes the room's profiles and providers into `~/.paseo/config.json`,
   backing up the old file as `config.json.bak-<timestamp>`;
4. runs `paseo daemon reload`.

Piped, it downloads the repository from GitHub; from a clone
(`git clone https://github.com/yanmad27/my-orchestrate-skill.git && cd my-orchestrate-skill && ./install.sh`)
it uses the checkout.

| Option | Effect |
|---|---|
| `--skill-only` | Only step 1 |
| `--paseo-only` | Only steps 2-4 — e.g. when the skill comes from the plugin marketplace |
| `--no-reload` | Skip `paseo daemon reload` |
| `SLP_REF=<branch or tag>` | Install that version instead of `main` (piped runs) |
| `SLP_ROOM_HOME=<dir>` | Build the runtimes somewhere other than `~/.config/slp-room` |
| `SLP_CLAUDE_OAUTH_TOKEN=<token>` | Use this token instead of `~/.config/slp-room/oauth-token` |

> [!NOTE]
> Plugin marketplace alternative: `/plugin marketplace add yanmad27/my-orchestrate-skill`, then (in a separate turn) `/plugin install orchestrate@my-orchestrate-skill`, then run `install.sh --paseo-only`. Don't combine the plugin with a full `install.sh` run, or you get the skill twice.

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
| **Supervisor** | `claude-supervisor` | `claude-opus-5-5` (thinking: xhigh) | `bypassPermissions` | The seat you talk to; the Supervisor role is its system prompt. Extra-high thinking for judging drift; every 2-minute heartbeat tick is a turn at that level. |
| **Lead** | `claude-lead` | `claude-opus-5-5` (thinking: high) | `bypassPermissions` | Launched by the Supervisor: owns one project's technical outcome, dispatches Peers, accepts or rejects candidates |
| **Cheap peer** | `claude-peer` | `claude-haiku-4-5` (thinking: medium) | `bypassPermissions` | Extraction, formatting, log triage, mechanical refactors — the down-tier target |
| **Peer** | `claude-peer` | `claude-sonnet-5` (thinking: medium) | `bypassPermissions` | Default tier for implementation, debugging, and research |
| **Expensive peer** | `claude-peer` | `claude-opus-5-5` (thinking: medium) | `bypassPermissions` | Hard problems only: architecture decisions, cross-module refactors with invariants, subtle concurrency/data bugs — chosen by Jev routing or escalation, never by default |
| **Review peer** | `claude-peer` | `claude-opus-5-5` (thinking: high) | `bypassPermissions` | Read-only Peer: reviews Codex-written candidates (and security-sensitive ones with `security-review`), architecture questions, committee member |
| **Codex peer** | `codex-peer` | `gpt-5.6-sol` (thinking: medium) | `full-access` | Writable Peer from another model family — only when you ask for Codex, or to retry a task a Claude Peer already failed. Not a tier. |
| **Codex review peer** | `codex-peer` | `gpt-5.6-sol` (thinking: high) | `full-access` | Read-only cross-family reviewer of Claude-written candidates, plan reviewer, committee member, debate tie-breaker |

| Provider | Extends | Agent tools |
|---|---|---|
| `claude-supervisor` | `claude` | Every Paseo tool: launching Leads, heartbeats, recovery |
| `claude-lead` | `claude` | Everything a Lead needs to launch and steer Peers; no heartbeat/schedule control (monitoring is the Supervisor's) |
| `claude-peer`, `codex-peer` | `claude`, `codex` | `send_agent_prompt` (to talk back to the Lead) and the read-only status tools; no `create_agent`, `cancel_agent`, `kill_agent`, `archive_agent`, `update_agent`, `set_agent_mode`, workspace creation, schedule/heartbeat control, or `respond_to_permission` |

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
- **Auth** is shared through one token: `install.sh` puts the contents of
  `~/.config/slp-room/oauth-token` (from `claude setup-token`) into both
  providers as `CLAUDE_CODE_OAUTH_TOKEN`, and keeps `~/.paseo/config.json`
  and its backups at mode `600`. Without the file it leaves the variable out;
  then log in once per runtime instead:
  `CLAUDE_CONFIG_DIR=~/.config/slp-room/claude-lead claude` → `/login` (same
  for `claude-peer`).
- **`codex-peer`** launches `codex -c developer_instructions='''<peer prompt>'''`
  through `~/.config/slp-room/bin/codex-peer`, which holds the `codex` path
  from install time.

Briefs still name the room files, so a seat launched without its prompt
reads them instead.

### What the installer owns

Each run resets the room's profiles (matched by `id`, or by name for
profiles an old installer left without one), the `claude-lead`/`claude-peer`/
`codex-peer` providers, `~/.claude/skills/supervisor`, and the generated
files in `~/.config/slp-room` to this version (your `oauth-token` and each
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
`claude plugin update orchestrate@my-orchestrate-skill` (then
`/reload-plugins` in an open session) and `install.sh --paseo-only`.

**From v1 (`/orchestrate`):** the same command migrates you — it removes the
v1 skill copy, the **Cheap worker**, **Worker**, **Expensive worker**,
**Reviewer**, and **Codex advisor** profiles, and the `claude-worker`
provider. The command is now `/supervisor`.

**Check version:** the last line of `install.sh` output, or the header of
`~/.config/slp-room/lead.md`. Compare with the
[releases page](https://github.com/yanmad27/my-orchestrate-skill/releases).

## Troubleshooting

| Symptom | Fix |
|---|---|
| The Supervisor replies *"This chat's provider has create_agent disabled"* | Your agent's provider isn't `claude-supervisor` or `claude` (e.g. it's `claude-peer`, which strips `create_agent`), or `daemon.mcp.injectIntoAgents` isn't `true` in `~/.paseo/config.json`. Check the config against [Requirements](#requirements). |
| A Lead ends with `BLOCKED: create_agent unavailable` | The Lead was launched on a provider without agent tools. Check the **Lead** profile uses provider `claude-lead`. |
| A Lead or Peer answers *"Not logged in · Please run /login"* | Its runtime has no auth: the token file is missing or the token expired. Run `claude setup-token`, save the new line to `~/.config/slp-room/oauth-token`, re-run `install.sh`. |
| A Lead or Peer doesn't follow its role, or its first action is reading `PROTOCOL.md` | It launched without its role prompt. Re-run `install.sh`; check `~/.config/slp-room/claude-{lead,peer}/output-styles/` and that the providers' `CLAUDE_CONFIG_DIR` points there. |
| A Lead or Peer lacks a skill or setting you added to `~/.claude` | Runtimes copy your settings at install time. Re-run `install.sh` after changing `~/.claude/settings.json` or adding skills. |
| A `codex-peer` agent fails to start after moving or reinstalling Codex | The launcher holds the `codex` path from install time. Re-run `install.sh`. |
| The Supervisor posts a `no change` line every 2 minutes | That is its heartbeat (`*/2 * * * *`) checking the room. It deletes the heartbeat when every Lead is done; ask it to stop supervising to remove it sooner. If a Supervisor session was closed mid-run, delete its leftover heartbeat from Paseo's schedules. |
| `/supervisor` is not found after a plugin install | Plugin skills are namespaced: try `/orchestrate:supervisor`, or just ask in plain language ("supervisor: …", "delegate this …"). |
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
   2-minute Paseo heartbeat, and checks each Lead's plan against your intent
   as soon as the Lead reports it.
3. Each Lead plans, picks a Peer tier per task (Jev or the manual rule), gets
   a plan review for larger plans, and dispatches Peers with a brief that
   names their write scope and acceptance evidence.
4. Peers either deliver a `CANDIDATE` or challenge the brief; the Lead
   concedes or holds with evidence (max two rounds). Implementation work gets
   a read-only review from the other model family — Codex reviews Claude's
   work, Claude reviews Codex's — before the Lead `ACCEPT`s it.
5. On each heartbeat the Supervisor checks what changed — in agent activity
   and in the repo — for drift: wrong target, scope creep, rabbit holes,
   unauthorized actions, acceptance without evidence, open loops, stalls. It
   asks the Lead an evidence-based question only when there is a concrete
   gap, brings drift that changes what you get to you, and pulls an
   emergency brake on unauthorized external or destructive actions.
   Otherwise it stays quiet.
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
- **No polling:** no seat `sleep`-loops on CI or on each other; the heartbeat is the only periodic wake. If you see a permission prompt containing `sleep … done`, deny it — it's a brief bug.
