# orchestrate

A Claude Code skill that turns the current session into a lead orchestrator
inside [Paseo](https://paseo.sh): it delegates every unit of real work to
subagents via `create_agent`, routes each task to the cheapest capable model
tier, and gets an independent review before reporting back — it never edits
files or writes code itself.

[![License: MIT](https://img.shields.io/github/license/yanmad27/my-orchestrate-skill)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/yanmad27/my-orchestrate-skill)](https://github.com/yanmad27/my-orchestrate-skill/releases)
[![Works with Paseo](https://img.shields.io/badge/works%20with-Paseo-2b6cb0)](https://paseo.sh)

## Contents

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [Install](#install)
- [Paseo configuration](#paseo-configuration)
- [Restart & verify](#restart--verify)
- [Upgrade](#upgrade)
- [Troubleshooting](#troubleshooting)
- [Usage](#usage)

## Quick start

```
/plugin marketplace add yanmad27/my-orchestrate-skill
/plugin install orchestrate@my-orchestrate-skill
```

```sh
curl -fsSL https://raw.githubusercontent.com/yanmad27/my-orchestrate-skill/main/install.sh | bash -s -- --paseo-only
paseo daemon reload
```

Open any `claude` agent in Paseo and run `/orchestrate <task>`.

> [!NOTE]
> The two `/plugin` commands must run as separate turns in Claude Code.
> See [Install](#install) for the full walkthrough and the clone/manual paths.

## Requirements

- Claude Code
- Paseo, with the daemon config described below
- `jq` (only needed for the install script's config merge)
- Optional: the `ask-jev` Claude Code plugin — when installed, /orchestrate uses it to pick the worker tier and to gate escalation; without it, the manual routing rules apply.

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
> Without `injectIntoAgents: true`, the orchestrating agent will not have the `create_agent` tool.

## Install

### Paseo built-in skills

> [!NOTE]
> You do **not** need Paseo's built-in skills (Settings → Skills: `paseo`, `paseo-committee`, `paseo-advisor`, `paseo-handoff`, …). `/orchestrate` only needs the `create_agent` MCP tool, which comes from `daemon.mcp.injectIntoAgents`. Paseo's former `paseo-orchestrate` skill is deprecated and no longer shipped — this skill replaces it. Leave the built-ins uninstalled to avoid the Lead picking up a competing delegation workflow.

### Option A: plugin marketplace

Run these as two separate commands in Claude Code (they cannot be combined in one turn):

1. Add the marketplace:

   ```
   /plugin marketplace add yanmad27/my-orchestrate-skill
   ```

2. Install the plugin:

   ```
   /plugin install orchestrate@my-orchestrate-skill
   ```

3. Configure Paseo:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/yanmad27/my-orchestrate-skill/main/install.sh | bash -s -- --paseo-only
   ```

   This skips the skill copy (already installed via the plugin) and merges
   the Paseo config, downloading `paseo/config.snippet.json` on the fly. You
   can also merge it in by hand — see [Manual merge](#manual-merge).

### Option B: clone + script

```sh
git clone https://github.com/yanmad27/my-orchestrate-skill.git
cd my-orchestrate-skill
./install.sh
```

This copies `skills/orchestrate` to `~/.claude/skills/orchestrate` and merges
`paseo/config.snippet.json` into `~/.paseo/config.json` (backing up the
original first).

| Flag | Effect |
|---|---|
| `--skill-only` | Skip the Paseo config merge |
| `--paseo-only` | Skip the skill copy — e.g. if you installed via the plugin marketplace and only need the config |

## Paseo configuration

The skill assumes five agent profiles and one provider exist in
`~/.paseo/config.json` (`daemon.agentProfiles` and `agents.providers`):

| Profile | Provider | Model | Mode | Use for |
|---|---|---|---|---|
| **Lead** | `claude` | `claude-opus-4-8` | — | Orchestrator: has `create_agent`, delegates instead of implementing. Optional — any `claude`-provider agent can run `/orchestrate`; this is just a high-thinking preset. |
| **Cheap worker** | `claude-worker` | `claude-haiku-4-5` | — | Extraction, formatting, log triage, mechanical refactors — the default down-tier target |
| **Worker** | `claude-worker` | `claude-sonnet-5` | — | Default tier for implementation, debugging, and research |
| **Expensive worker** | `claude-worker` | `claude-opus-4-8` (thinking: high) | — | Hard problems only: architecture decisions, cross-module refactors with invariants, subtle concurrency/data bugs — chosen by Jev routing or escalation, never by default |
| **Reviewer** | `claude-worker` | `claude-sonnet-5` | `plan` | Read-only review of a worker's diff against the original acceptance criteria |

`claude-worker` (`agents.providers.claude-worker`) is a separate provider,
extending `claude`, with `create_agent`, `send_agent_prompt`, `cancel_agent`,
and other agent-control tools disabled. Workers must run under this provider
so a delegated subagent can't spawn or control further agents — only the
Lead profile (plain `claude` provider) can.

### Manual merge

If you'd rather not run `install.sh`, open `paseo/config.snippet.json` and
merge its `daemon.agentProfiles` entries and `agents.providers.claude-worker`
into `~/.paseo/config.json` by hand, then run `paseo daemon reload`.

## Restart & verify

After any install path, reload the Paseo daemon to load the new profiles and
provider:

```sh
paseo daemon reload
```

If profiles still don't appear, restart instead:

```sh
paseo daemon restart
```

Or quit the Paseo desktop app and restart it.

Then check the Paseo agent creation dialog — it should show five profiles:
**Lead**, **Cheap worker**, **Worker**, **Expensive worker**, and **Reviewer**.

## Upgrade

### Plugin (Option A)

```
/plugin marketplace update my-orchestrate-skill
```

Then, in a terminal (not inside a Claude Code session):

```sh
claude plugin update orchestrate@my-orchestrate-skill
```

If you have a session open, run `/reload-plugins` there afterward to load
the change. Auto-update is off by default for third-party marketplaces like
this one. To enable it: `/plugin` → **Marketplaces** → select
`my-orchestrate-skill` → **Enable auto-update** (Claude Code then checks in
the background after session start and prompts `/reload-plugins`). Re-run
the Paseo config step (`curl … --paseo-only`) only if a release's notes say
profiles changed.

### Clone (Option B)

```sh
cd my-orchestrate-skill && git pull && ./install.sh
```

Use `./install.sh --skill-only` to skip the Paseo config merge.

**Check version:** `/plugin` → **Installed** tab, or
`claude plugin details orchestrate@my-orchestrate-skill`. Compare with the
[releases page](https://github.com/yanmad27/my-orchestrate-skill/releases).

Run `paseo daemon reload` only if the Paseo config actually changed.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `/orchestrate` replies *"This chat's provider has create_agent disabled"* | Your agent's provider isn't `claude` (e.g. it's `claude-worker`, which strips `create_agent`), or `daemon.mcp.injectIntoAgents` isn't `true` in `~/.paseo/config.json`. Check the config against [Requirements](#requirements). |
| Profiles missing after install | The daemon wasn't reloaded, or `~/.paseo/config.json` has invalid JSON. Verify with `jq . ~/.paseo/config.json`, then run `paseo daemon reload`. |
| `daemon.agentProfiles.N.id: Invalid input: expected string, received undefined` | Your config has profiles from an older installer version that shipped without an `id`. Re-run `install.sh` (or the `--paseo-only` form) — it backfills a stable `id` onto any existing profile whose name matches one of this plugin's managed profiles, without touching profiles you added yourself. |

## Usage

### Start an orchestrating agent

- In Paseo, open any agent on provider `claude` (a normal Claude Code chat). It has `create_agent` as long as `daemon.mcp.injectIntoAgents` is on.
- Optional: pick the **Lead** profile for a preset with opus + high thinking — see [Paseo configuration](#paseo-configuration). Not required; `/orchestrate` works from any `claude` agent.

### Invoke

**Slash command:**
```
/orchestrate <task>
```

**Auto-trigger:** the skill activates when you ask for delegation in natural language:
- `orchestrate this bug fix`
- `giao cho worker fix cái bug này`
- `delegate the refactor across agents`
- `spawn subagents to investigate why CI fails`

### Examples

| Task | Routed to |
|---|---|
| `/orchestrate rename UserSvc to UserService across the repo` | **Cheap worker** (mechanical refactor) |
| `/orchestrate add rate limiting to the POST /login endpoint` | **Worker** → **Reviewer** (implementation + review) |
| `/orchestrate why does CI keep timing out on main?` | **Worker** (investigate) → **Worker** (fix) → **Reviewer** |
| `/orchestrate review PR #42 for security issues` | **Reviewer** only (read-only audit) |
| `/orchestrate find the race condition causing duplicate webhook deliveries` | **Expensive worker** (Jev-routed), then **Reviewer** |

### What happens

1. Lead agent receives the task; plans and decomposes it (≤3 tool calls to locate files/services).
2. For each unit of work, Lead chooses the lowest capable tier: Cheap worker, Worker, or Expensive worker (opus) — the last picked by Jev routing for genuinely hard tasks (architecture, cross-module invariants, subtle bugs) or reached via escalation if a same-tier retry fails for capability reasons.
3. Lead delegates via `create_agent` with a sharp spec, acceptance criteria, and output format; a worktree is created only if 2+ workers must edit files at the same time (sidebar tabs appear).
4. Lead surfaces any permission prompts to you; destructive actions never self-approve.
5. Implementation work gets an independent **Reviewer** pass (plan mode, read-only) before the Lead reports.
6. Lead reports outcome, files changed, and any unresolved findings.

### Tips

- **Give acceptance criteria:** "rename to snake_case and update all imports" beats "refactor this". The subagent sees none of this conversation.
- **Say "read-only"** if you want an audit, investigation, or code review without file changes.
- **Mention constraints:** if a file or area must not be touched, state it in the task.
- **Watch the sidebar:** if a task spawns multiple concurrent workers on files, worktree tabs appear — avoid switching tabs while they run.
- **Permission prompts are yours:** the Lead never auto-approves destructive actions; it surfaces them to you for confirmation.
