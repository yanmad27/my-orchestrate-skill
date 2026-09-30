#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FAILED=0
ok()   { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- SKILL.md frontmatter -------------------------------------------------

SKILL_MD="skills/supervisor/SKILL.md"

cat > "$TMP/check_frontmatter.py" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()

m = re.match(r'^---\n(.*?\n)---\n', text, re.DOTALL)
if not m:
    print(f"FAIL: {path} missing YAML frontmatter delimiters")
    sys.exit(1)
fm_text = m.group(1)

failed = False
try:
    import yaml
    fm = yaml.safe_load(fm_text)
    print(f"ok: {path} frontmatter parses as YAML")
except Exception as e:
    print(f"FAIL: {path} frontmatter failed to parse as YAML: {e}")
    sys.exit(1)

if isinstance(fm, dict) and set(fm.keys()) == {"name", "description"}:
    print(f"ok: {path} frontmatter has exactly keys name, description")
else:
    keys = sorted(fm.keys()) if isinstance(fm, dict) else fm
    print(f"FAIL: {path} frontmatter keys are {keys!r}, expected exactly [name, description]")
    failed = True

expected_name = sys.argv[2]
name = fm.get("name") if isinstance(fm, dict) else None
if name == expected_name:
    print(f'ok: {path} frontmatter name == "{expected_name}"')
else:
    print(f'FAIL: {path} frontmatter name is {name!r}, expected "{expected_name}"')
    failed = True

desc = fm.get("description") if isinstance(fm, dict) else None
required = sys.argv[3].split(",")
if isinstance(desc, str) and "\n" not in desc and all(p in desc for p in required):
    print(f"ok: {path} frontmatter description is one line and mentions {'/'.join(required)}")
else:
    print(f"FAIL: {path} frontmatter description is not a single line containing {', '.join(required)}")
    failed = True

sys.exit(1 if failed else 0)
PY

python3 "$TMP/check_frontmatter.py" "$SKILL_MD" supervisor "create_agent,supervisor,orchestrate,delegate" || FAILED=1

# --- room files: invariant phrases ------------------------------------------

ROOM_DIR="skills/supervisor"
# Each entry is "<file relative to ROOM_DIR>|<phrase>".
ROOM_PHRASES=(
  "SKILL.md|create_agent"
  'SKILL.md|Never delegate with the built-in `Agent` tool'
  "SKILL.md|list_profiles"
  "SKILL.md|create_heartbeat"
  "SKILL.md|delete_heartbeat"
  'SKILL.md|$ARGUMENTS'
  "SKILL.md|Always open with a recap of what each subagent did"
  "SKILL.md|roles/lead.md"
  "SKILL.md|the path stated at the top of your system"
  "SKILL.md|INTENT RECORD"
  "SKILL.md|KEEPING THE ROOM ON COURSE"
  "SKILL.md|Emergency brake"
  "roles/lead.md|Your instruction's outcome, non-goals, authority, and acceptance evidence"
  "roles/lead.md|roles/peer.md"
  'roles/lead.md|Never delegate with the built-in `Agent` tool'
  "roles/lead.md|list_profiles"
  "roles/lead.md|Never launch Expensive peer (opus) on gut feeling"
  "roles/lead.md|Review peer"
  "roles/lead.md|Codex review peer"
  "roles/lead.md|from the other model family than the writer"
  "roles/lead.md|REVISED BRIEF"
  "roles/lead.md|DECISION_NEEDED"
  "roles/lead.md|RECAP:"
  "roles/peer.md|REOPEN_REQUEST"
  "roles/peer.md|Talking to your Lead"
  "roles/lead.md|PASEO_AGENT_ID"
  "PROTOCOL.md|Peer → Lead, two ways"
  "roles/peer.md|DEPENDENCY_REQUEST"
  "roles/peer.md|RECAP:"
  "roles/peer.md|Never poll."
  "PROTOCOL.md|REOPEN_REQUEST"
  "PROTOCOL.md|At most two exchange rounds per issue"
)
for entry in "${ROOM_PHRASES[@]}"; do
  file="$ROOM_DIR/${entry%%|*}"
  phrase="${entry#*|}"
  if [ ! -f "$file" ]; then
    fail "$file is missing"
  elif grep -qF -- "$phrase" "$file"; then
    ok "$file contains '$phrase'"
  else
    fail "$file missing required phrase '$phrase'"
  fi
done

# --- plugin.json / marketplace.json ---------------------------------------

PLUGIN_JSON=".claude-plugin/plugin.json"
MARKETPLACE_JSON=".claude-plugin/marketplace.json"

if jq empty "$PLUGIN_JSON" 2>/dev/null; then
  ok "plugin.json is valid JSON"
else
  fail "plugin.json is not valid JSON"
fi

if jq empty "$MARKETPLACE_JSON" 2>/dev/null; then
  ok "marketplace.json is valid JSON"
else
  fail "marketplace.json is not valid JSON"
fi

if [ "$(jq -r '.name' "$PLUGIN_JSON")" = "paseo-slp" ] && [ "$(jq -r '.name, .plugins[0].name' "$MARKETPLACE_JSON" | sort -u)" = "paseo-slp" ]; then
  ok 'plugin.json, marketplace.json, and its plugin are all named "paseo-slp"'
else
  fail 'plugin.json .name, marketplace.json .name, and .plugins[0].name must all be "paseo-slp"'
fi

PLUGIN_VERSION="$(jq -r '.version' "$PLUGIN_JSON")"
MARKETPLACE_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON")"

if [[ "$PLUGIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  ok "plugin.json .version ($PLUGIN_VERSION) matches semver pattern"
else
  fail "plugin.json .version ($PLUGIN_VERSION) does not match ^[0-9]+.[0-9]+.[0-9]+$"
fi

if [ "$PLUGIN_VERSION" = "$MARKETPLACE_VERSION" ]; then
  ok "plugin.json .version equals marketplace.json .plugins[0].version ($PLUGIN_VERSION)"
else
  fail "version mismatch: plugin.json=$PLUGIN_VERSION marketplace.json=$MARKETPLACE_VERSION"
fi

PLUGIN_DESC="$(jq -r '.description' "$PLUGIN_JSON")"
MARKETPLACE_DESC="$(jq -r '.plugins[0].description' "$MARKETPLACE_JSON")"

if [ "$PLUGIN_DESC" = "$MARKETPLACE_DESC" ]; then
  ok "plugin.json and marketplace.json descriptions match"
else
  fail "plugin.json and marketplace.json descriptions differ"
fi

# --- .release-please-manifest.json -----------------------------------------

MANIFEST_JSON=".release-please-manifest.json"

if jq empty "$MANIFEST_JSON" 2>/dev/null; then
  ok ".release-please-manifest.json is valid JSON"
else
  fail ".release-please-manifest.json is not valid JSON"
fi

MANIFEST_VERSION="$(jq -r '.["."]' "$MANIFEST_JSON")"
if [ "$MANIFEST_VERSION" = "$PLUGIN_VERSION" ]; then
  ok ".release-please-manifest.json .[\".\"] equals plugin.json .version ($PLUGIN_VERSION)"
else
  fail ".release-please-manifest.json .[\".\"] ($MANIFEST_VERSION) != plugin.json .version ($PLUGIN_VERSION)"
fi

# --- paseo/config.snippet.json --------------------------------------------

SNIPPET="paseo/config.snippet.json"

if jq empty "$SNIPPET" 2>/dev/null; then
  ok "paseo/config.snippet.json is valid JSON"
else
  fail "paseo/config.snippet.json is not valid JSON"
fi

EXPECTED_PROFILES="Cheap peer,Codex peer,Codex review peer,Expensive peer,Lead,Peer,Review peer,Supervisor"
ACTUAL_PROFILES="$(jq -r '[.daemon.agentProfiles[].name] | sort | join(",")' "$SNIPPET")"
if [ "$ACTUAL_PROFILES" = "$EXPECTED_PROFILES" ]; then
  ok "config.snippet.json profile names are exactly Supervisor, Lead, Cheap peer, Peer, Expensive peer, Review peer, Codex peer, Codex review peer"
else
  fail "config.snippet.json profile names are [$ACTUAL_PROFILES], expected [$EXPECTED_PROFILES]"
fi

EXPENSIVE_MODEL="$(jq -r '.daemon.agentProfiles[] | select(.name == "Expensive peer") | .model' "$SNIPPET")"
EXPENSIVE_PROVIDER="$(jq -r '.daemon.agentProfiles[] | select(.name == "Expensive peer") | .provider' "$SNIPPET")"
if [[ "$EXPENSIVE_MODEL" == claude-opus* ]] && [ "$EXPENSIVE_PROVIDER" = "claude-peer" ]; then
  ok "Expensive peer profile has model claude-opus* and provider claude-peer"
else
  fail "Expensive peer profile model/provider is '$EXPENSIVE_MODEL'/'$EXPENSIVE_PROVIDER', expected claude-opus*/claude-peer"
fi

# Supervisor and Lead launch agents, so they need a provider with agent tools; Peers must not.
if jq -e '[.daemon.agentProfiles[] | select(.name == "Supervisor" or .name == "Lead") | .provider] == ["claude-supervisor", "claude-lead"]' "$SNIPPET" >/dev/null; then
  ok 'Supervisor uses provider "claude-supervisor" and Lead uses "claude-lead"'
else
  fail 'Supervisor must use provider "claude-supervisor" and Lead "claude-lead"'
fi

if jq -e '[.daemon.agentProfiles[] | select(.name | test("[Pp]eer$")) | select(.name | startswith("Codex") | not) | .provider] | length == 4 and all(. == "claude-peer")' "$SNIPPET" >/dev/null; then
  ok 'all four Claude Peer profiles use provider "claude-peer"'
else
  fail 'every Claude Peer profile (Cheap peer, Peer, Expensive peer, Review peer) must use provider "claude-peer"'
fi

if jq -e '[.daemon.agentProfiles[] | select(.name | startswith("Codex")) | .provider] | length == 2 and all(. == "codex-peer")' "$SNIPPET" >/dev/null; then
  ok 'both Codex Peer profiles use provider "codex-peer"'
else
  fail 'every Codex profile (Codex peer, Codex review peer) must use provider "codex-peer"'
fi

if jq -e '.daemon.agentProfiles | all(has("provider") and has("model") and has("modeId"))' "$SNIPPET" >/dev/null; then
  ok "every agent profile has provider, model, modeId"
else
  fail "some agent profile is missing provider, model, or modeId"
fi

if jq -e '.daemon.agentProfiles | all(has("id") and (.id | type == "string") and (.id | length > 0))' "$SNIPPET" >/dev/null; then
  ok "every agent profile has a non-empty string id"
else
  fail "some agent profile is missing id, or id is not a non-empty string"
fi

if jq -e '[.daemon.agentProfiles[].id] | length == (unique | length)' "$SNIPPET" >/dev/null; then
  ok "agent profile ids are unique"
else
  fail "agent profile ids are not unique"
fi

# Every Lead and Peer seat runs with full permissions; read-only reviewers are read-only by brief.
if jq -e '[.daemon.agentProfiles[] | select(.name != "Supervisor")]
    | all(if .provider == "codex-peer" then .modeId == "full-access" else .modeId == "bypassPermissions" end)' "$SNIPPET" >/dev/null; then
  ok 'every Lead/Peer profile runs full access (Claude bypassPermissions, Codex full-access)'
else
  fail 'every Lead/Peer profile must run full access: Claude bypassPermissions, Codex full-access'
fi

# Claude seats run in their own runtime (CLAUDE_CONFIG_DIR) sharing one token; Codex through a launcher.
if jq -e '.agents.providers as $p
    | $p["claude-supervisor"].extends == "claude"
    and $p["claude-supervisor"].env == {"CLAUDE_CONFIG_DIR": "@@ROOM_HOME@@/claude-supervisor", "CLAUDE_CODE_OAUTH_TOKEN": "@@CLAUDE_OAUTH_TOKEN@@"}
    and ($p["claude-supervisor"] | has("paseoTools") | not)
    and $p["claude-lead"].extends == "claude"
    and $p["claude-lead"].env == {"CLAUDE_CONFIG_DIR": "@@ROOM_HOME@@/claude-lead", "CLAUDE_CODE_OAUTH_TOKEN": "@@CLAUDE_OAUTH_TOKEN@@"}
    and $p["claude-peer"].env == {"CLAUDE_CONFIG_DIR": "@@ROOM_HOME@@/claude-peer", "CLAUDE_CODE_OAUTH_TOKEN": "@@CLAUDE_OAUTH_TOKEN@@"}
    and ($p["claude-lead"] | has("command") | not) and ($p["claude-peer"] | has("command") | not)
    and ($p["claude-lead"].paseoTools.disabledTools | index("create_agent") == null and index("create_heartbeat") != null)
    and $p["codex-peer"].command == ["@@ROOM_HOME@@/bin/codex-peer"]' "$SNIPPET" >/dev/null; then
  ok "claude-supervisor/claude-lead/claude-peer use per-role runtimes with a shared token (Supervisor keeps every Paseo tool); codex-peer uses its launcher; claude-lead keeps create_agent but not heartbeats"
else
  fail "claude-supervisor/claude-lead/claude-peer must set env CLAUDE_CONFIG_DIR=@@ROOM_HOME@@/<provider> and CLAUDE_CODE_OAUTH_TOKEN=@@CLAUDE_OAUTH_TOKEN@@ (no command); codex-peer must launch through @@ROOM_HOME@@/bin/codex-peer"
fi

# Spawning is controlled: no Claude seat has the built-in Agent/Task tool or can start nested
# claude/codex runs from Bash; Leads and Peers cannot touch the paseo CLI, and the Supervisor
# keeps only its read-only commands.
if jq -e '.agents.providers as $p
    | (["claude-supervisor", "claude-lead", "claude-peer"]
        | all(. as $k | ["Agent", "Task", "Bash(claude:*)", "Bash(codex:*)"] - ($p[$k].disallowedTools // []) == []))
    and (["claude-lead", "claude-peer"] | all(. as $k | $p[$k].disallowedTools | index("Bash(paseo:*)") != null))
    and ($p["claude-supervisor"].disallowedTools | index("Bash(paseo run:*)") != null and index("Bash(paseo:*)") == null)' \
    "$SNIPPET" >/dev/null; then
  ok "Claude seats cannot spawn outside create_agent: no Agent/Task tool, no nested claude/codex or paseo run from Bash"
else
  fail "claude-supervisor/claude-lead/claude-peer must disallow Agent, Task, Bash(claude:*), Bash(codex:*); Lead/Peer also Bash(paseo:*), Supervisor Bash(paseo run:*)"
fi

# Peers talk back to their Lead (send_agent_prompt) but must not spawn or control agents.
for pair in claude-peer:claude codex-peer:codex; do
  prov="${pair%%:*}" base="${pair#*:}"
  if jq -e --arg p "$prov" --arg b "$base" '.agents.providers[$p] as $x
      | $x.extends == $b and ($x.paseoTools.enabled != false)
      and ($x.paseoTools.disabledTools | index("create_agent") != null and index("delete_schedule") != null and index("send_agent_prompt") == null)' \
      "$SNIPPET" >/dev/null; then
    ok "agents.providers[\"$prov\"] extends $base, keeps send_agent_prompt, disables create_agent and schedule control"
  else
    fail "agents.providers[\"$prov\"] must extend $base, keep send_agent_prompt, and disable create_agent and delete_schedule"
  fi
done

# --- install.sh syntax and lint --------------------------------------------

SCRIPTS=(install.sh)
for script in "${SCRIPTS[@]}"; do
  if bash -n "$script"; then
    ok "$script has valid bash syntax"
  else
    fail "$script has a bash syntax error"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "${SCRIPTS[@]}"; then
    ok "${SCRIPTS[*]} pass shellcheck -S warning"
  else
    fail "${SCRIPTS[*]} have shellcheck warnings"
  fi
else
  ok "shellcheck not installed, skipping lint"
fi

# --- install.sh functional tests -------------------------------------------

LOCAL_HOME="$TMP/home-local"
mkdir -p "$LOCAL_HOME"
if HOME="$LOCAL_HOME" "$REPO_ROOT/install.sh" --paseo-only --no-reload >/dev/null 2>&1; then
  ACTUAL="$(jq -r '[.daemon.agentProfiles[].name] | sort | join(",")' "$LOCAL_HOME/.paseo/config.json")"
  EXPECTED="$(jq -r '[.daemon.agentProfiles[].name] | sort | join(",")' "$SNIPPET")"
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    ok "install.sh --paseo-only writes matching profile names to \$HOME/.paseo/config.json"
  else
    fail "install.sh --paseo-only wrote profiles [$ACTUAL], expected [$EXPECTED]"
  fi
else
  fail "install.sh --paseo-only failed to run"
fi

HEAL_HOME="$TMP/home-heal"
mkdir -p "$HEAL_HOME/.paseo"
jq '.daemon.agentProfiles |= map(del(.id))' "$SNIPPET" | \
  jq '{version: 1, daemon: {agentProfiles: .daemon.agentProfiles}}' > "$HEAL_HOME/.paseo/config.json"
if HOME="$HEAL_HOME" "$REPO_ROOT/install.sh" --paseo-only --no-reload >/dev/null 2>&1; then
  MISSING_IDS="$(jq -r '[.daemon.agentProfiles[] | select(has("id") | not)] | length' "$HEAL_HOME/.paseo/config.json")"
  if [ "$MISSING_IDS" = "0" ]; then
    ok "install.sh --paseo-only heals pre-existing profiles that are missing id"
  else
    fail "install.sh --paseo-only left $MISSING_IDS pre-existing profile(s) without id"
  fi
else
  fail "install.sh --paseo-only failed to run against a config with id-less profiles"
fi

# v1 → v2: v1 profiles and claude-worker go, managed profiles/providers are reset to the
# snippet, and the user's own profiles and providers survive. A second run changes nothing.
MIGRATE_HOME="$TMP/home-migrate"
mkdir -p "$MIGRATE_HOME/.paseo"
cat > "$MIGRATE_HOME/.paseo/config.json" <<'JSON'
{"version": 1, "daemon": {"agentProfiles": [
  {"id": "agent_profile_orchestrate_lead", "name": "Lead", "provider": "claude", "model": "claude-opus-5", "modeId": "bypassPermissions"},
  {"id": "agent_profile_orchestrate_worker", "name": "Worker", "provider": "claude-worker", "model": "claude-sonnet-5", "modeId": "bypassPermissions"},
  {"name": "Reviewer", "provider": "claude-worker", "model": "claude-opus-5", "modeId": "plan"},
  {"id": "mine", "name": "Mine", "provider": "claude", "model": "x", "modeId": "plan"}]},
 "agents": {"providers": {
  "claude-worker": {"extends": "claude", "description": "Delegated worker — cannot spawn or control other agents"},
  "claude-peer": {"extends": "claude", "paseoTools": {"disabledTools": ["send_agent_prompt"]}},
  "mine-provider": {"extends": "claude"}}}}
JSON
if HOME="$MIGRATE_HOME" "$REPO_ROOT/install.sh" --paseo-only --no-reload >/dev/null 2>&1 \
  && HOME="$MIGRATE_HOME" "$REPO_ROOT/install.sh" --paseo-only --no-reload >/dev/null 2>&1; then
  if jq -e --slurpfile snip "$SNIPPET" '
      ([.daemon.agentProfiles[].name] | sort) == (["Mine"] + [$snip[0].daemon.agentProfiles[].name] | sort)
      and ([.daemon.agentProfiles[] | select(.name == "Lead") | .model] == ["claude-opus-5-5"])
      and (.agents.providers | keys | sort) == ["claude-lead", "claude-peer", "claude-supervisor", "codex-peer", "mine-provider"]
      and .agents.providers["claude-peer"].paseoTools == $snip[0].agents.providers["claude-peer"].paseoTools' \
      "$MIGRATE_HOME/.paseo/config.json" >/dev/null; then
    ok "install.sh --paseo-only migrates a v1 config, resets managed entries, and keeps the user's own"
  else
    fail "install.sh --paseo-only did not migrate a v1 config as expected: $(jq -c '[.daemon.agentProfiles[].name], (.agents.providers | keys)' "$MIGRATE_HOME/.paseo/config.json")"
  fi
else
  fail "install.sh --paseo-only failed to run against a v1 config"
fi

# install.sh renders one Claude runtime per seat (output style = role prompt, the user's
# settings and skills minus the Supervisor, shared token) and the Codex launcher, which
# puts the Peer prompt before Paseo's own `app-server` argument.
RENDER_HOME="$TMP/home-render"
mkdir -p "$RENDER_HOME/bin" "$RENDER_HOME/.claude/skills/supervisor" "$RENDER_HOME/.claude/skills/other" "$RENDER_HOME/.config/slp-room"
printf '{"theme": "dark", "enabledPlugins": {"paseo-slp@paseo-slp": true, "orchestrate@my-orchestrate-skill": true, "x@y": true}}\n' > "$RENDER_HOME/.claude/settings.json"
printf 'mine\n' > "$RENDER_HOME/.claude/CLAUDE.md"
printf 'sk-ant-oat01-test\n' > "$RENDER_HOME/.config/slp-room/oauth-token"
mkdir -p "$RENDER_HOME/.codex"
printf '{}\n' > "$RENDER_HOME/.codex/auth.json"
printf 'model = "x"\n' > "$RENDER_HOME/.codex/config.toml"
for cli in codex claude paseo; do
  printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done\n' > "$RENDER_HOME/bin/$cli"
  chmod +x "$RENDER_HOME/bin/$cli"
done
if PATH="$RENDER_HOME/bin:$PATH" HOME="$RENDER_HOME" env -u CODEX_HOME "$REPO_ROOT/install.sh" --paseo-only --no-reload >/dev/null 2>&1; then
  ROOM="$RENDER_HOME/.config/slp-room"
  CODEX_ARGS="$("$ROOM/bin/codex-peer" app-server 2>&1 || true)"
  if grep -q 'Room role: Lead' "$ROOM/claude-lead/output-styles/slp-lead.md" \
    && grep -q '^name: slp-supervisor$' "$ROOM/claude-supervisor/output-styles/slp-supervisor.md" \
    && grep -qF "ROOM_DIR=$ROOM/room." "$ROOM/claude-supervisor/output-styles/slp-supervisor.md" \
    && grep -q 'KEEPING THE ROOM ON COURSE' "$ROOM/claude-supervisor/output-styles/slp-supervisor.md" \
    && ! grep -q '^name: supervisor$' "$ROOM/claude-supervisor/output-styles/slp-supervisor.md" \
    && [ -f "$ROOM/room/PROTOCOL.md" ] && [ -f "$ROOM/room/roles/lead.md" ] && [ -f "$ROOM/room/roles/peer.md" ] \
    && [ ! -e "$ROOM/claude-supervisor/skills/supervisor" ] \
    && grep -q '^name: slp-lead$' "$ROOM/claude-lead/output-styles/slp-lead.md" \
    && grep -q '^keep-coding-instructions: true$' "$ROOM/claude-lead/output-styles/slp-lead.md" \
    && grep -q 'Room Protocol' "$ROOM/claude-peer/output-styles/slp-peer.md" \
    && grep -q 'Room role: Peer' "$ROOM/claude-peer/output-styles/slp-peer.md" \
    && jq -e '.outputStyle == "slp-lead" and .theme == "dark"
        and .enabledPlugins["paseo-slp@paseo-slp"] == false
        and .enabledPlugins["orchestrate@my-orchestrate-skill"] == false and .enabledPlugins["x@y"] == true' \
      "$ROOM/claude-lead/settings.json" >/dev/null \
    && [ -L "$ROOM/claude-peer/skills/other" ] && [ ! -e "$ROOM/claude-peer/skills/supervisor" ] \
    && [ "$(readlink "$ROOM/claude-lead/CLAUDE.md")" = "$RENDER_HOME/.claude/CLAUDE.md" ] \
    && [ "$(printf '%s\n' "$CODEX_ARGS" | head -6 | tr -d '\n')" = "[-c][agents.enabled=false][-c][features.multi_agent=false][-c][features.multi_agent_v2=false]" ] \
    && printf '%s\n' "$CODEX_ARGS" | grep -qF "[developer_instructions='''" \
    && printf '%s\n' "$CODEX_ARGS" | grep -q 'Room role: Peer' \
    && [ "$(printf '%s\n' "$CODEX_ARGS" | tail -1)" = "[app-server]" ] \
    && ! grep -q '@@' "$RENDER_HOME/.paseo/config.json" \
    && grep -qF "CODEX_HOME=\"$ROOM/codex-peer\" exec" "$ROOM/bin/codex-peer" \
    && [ "$(readlink "$ROOM/codex-peer/auth.json")" = "$RENDER_HOME/.codex/auth.json" ] \
    && grep -q '^model = "x"$' "$ROOM/codex-peer/config.toml" \
    && grep -q 'decision = "forbidden"' "$ROOM/codex-peer/rules/room.rules" \
    && grep -qF '"paseo"' "$ROOM/codex-peer/rules/room.rules" \
    && grep -qF "\"$RENDER_HOME/bin/claude\"" "$ROOM/codex-peer/rules/room.rules" \
    && [ ! -e "$ROOM/guard" ] \
    && jq -e --arg bin "$RENDER_HOME/bin" '.agents.providers as $p
        | ($p["claude-lead"].disallowedTools | index("Bash(" + $bin + "/claude:*)") != null)
        and ($p["claude-peer"].disallowedTools | index("Bash(" + $bin + "/paseo:*)") != null)
        and ($p["claude-supervisor"].disallowedTools | index("Bash(" + $bin + "/paseo run:*)") != null
             and index("Bash(" + $bin + "/paseo:*)") == null)' "$RENDER_HOME/.paseo/config.json" >/dev/null \
    && [ "$(stat -c %a "$RENDER_HOME/.paseo/config.json" 2>/dev/null || stat -f %Lp "$RENDER_HOME/.paseo/config.json")" = "600" ] \
    && jq -e --arg dir "$ROOM" '.agents.providers["claude-lead"].env
        == {"CLAUDE_CONFIG_DIR": ($dir + "/claude-lead"), "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-test"}' \
      "$RENDER_HOME/.paseo/config.json" >/dev/null; then
    ok "install.sh renders the Claude runtimes, the Codex launcher, and a private config with the shared token"
  else
    fail "install.sh did not render the Claude runtimes, Codex launcher, or provider env as expected"
  fi
else
  fail "install.sh --paseo-only failed to render the room"
fi

# --token without a terminal cannot ask, so it keeps the saved token instead of dropping it.
KEEP_HOME="$TMP/home-keep-token"
mkdir -p "$KEEP_HOME/.config/slp-room"
printf 'sk-ant-oat01-keep\n' > "$KEEP_HOME/.config/slp-room/oauth-token"
if HOME="$KEEP_HOME" "$REPO_ROOT/install.sh" --paseo-only --no-reload --token >/dev/null 2>&1 \
  && jq -e '.agents.providers["claude-lead"].env.CLAUDE_CODE_OAUTH_TOKEN == "sk-ant-oat01-keep"' \
    "$KEEP_HOME/.paseo/config.json" >/dev/null; then
  ok "install.sh --token without a terminal keeps the saved token"
else
  fail "install.sh --token without a terminal dropped the saved token"
fi

# Without a token file the env key is dropped, so per-runtime logins keep working.
NOTOKEN_HOME="$TMP/home-notoken"
mkdir -p "$NOTOKEN_HOME"
if HOME="$NOTOKEN_HOME" "$REPO_ROOT/install.sh" --paseo-only --no-reload >/dev/null 2>&1 \
  && jq -e '.agents.providers["claude-peer"].env | has("CLAUDE_CODE_OAUTH_TOKEN") | not' "$NOTOKEN_HOME/.paseo/config.json" >/dev/null \
  && ! grep -q '@@' "$NOTOKEN_HOME/.paseo/config.json"; then
  ok "install.sh without a token leaves CLAUDE_CODE_OAUTH_TOKEN out of the provider env"
else
  fail "install.sh without a token left a placeholder or an empty token in the provider env"
fi

# Custom endpoint: each header form renders ANTHROPIC_BASE_URL plus exactly one key variable on
# every Claude provider, never CLAUDE_CODE_OAUTH_TOKEN (and the token render never has ANTHROPIC_*).
EP_OK=1
for form in bearer x-api-key; do
  EP_HOME="$TMP/home-endpoint-$form"
  mkdir -p "$EP_HOME"
  if [ "$form" = bearer ]; then KEYVAR=ANTHROPIC_AUTH_TOKEN; else KEYVAR=ANTHROPIC_API_KEY; fi
  if HOME="$EP_HOME" SLP_CLAUDE_BASE_URL=https://gateway.example.com SLP_CLAUDE_AUTH_TOKEN="k e y" \
      SLP_CLAUDE_AUTH_HEADER="$form" "$REPO_ROOT/install.sh" --paseo-only --no-reload >/dev/null 2>&1 \
    && jq -e --arg kv "$KEYVAR" '[.agents.providers | to_entries[] | select(.key | startswith("claude-")) | .value.env
        | keys | sort == (["ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR", $kv] | sort)] | length == 3 and all' \
      "$EP_HOME/.paseo/config.json" >/dev/null; then :; else EP_OK=0; fi
done
# The older alias SLP_CLAUDE_API_KEY still renders the same key; both names set and different is refused.
ALIAS_HOME="$TMP/home-endpoint-alias"
mkdir -p "$ALIAS_HOME"
if HOME="$ALIAS_HOME" SLP_CLAUDE_BASE_URL=https://gateway.example.com SLP_CLAUDE_API_KEY="k e y" \
    "$REPO_ROOT/install.sh" --paseo-only --no-reload >/dev/null 2>&1 \
  && jq -e '[.agents.providers | to_entries[] | select(.key | startswith("claude-")) | .value.env
      | .ANTHROPIC_AUTH_TOKEN == "k e y"] | length == 3 and all' "$ALIAS_HOME/.paseo/config.json" >/dev/null \
  && ! HOME="$TMP/home-endpoint-both" SLP_CLAUDE_BASE_URL=https://gateway.example.com SLP_CLAUDE_API_KEY=a \
    SLP_CLAUDE_AUTH_TOKEN=b "$REPO_ROOT/install.sh" --paseo-only --no-reload >/dev/null 2>&1; then
  ok "install.sh still accepts SLP_CLAUDE_API_KEY as an alias and refuses two different keys"
else
  fail "install.sh's SLP_CLAUDE_API_KEY alias broke, or two different keys were accepted"
fi

if [ "$EP_OK" = 1 ] \
  && jq -e '[.agents.providers | to_entries[] | select(.key | startswith("claude-")) | .value.env
      | keys | map(select(startswith("ANTHROPIC_"))) | length] | all(. == 0)' "$TMP/home-render/.paseo/config.json" >/dev/null; then
  ok "install.sh's endpoint render gives Claude providers ANTHROPIC_BASE_URL + one key variable and no OAuth token; the token render has no ANTHROPIC_*"
else
  fail "install.sh's Claude provider env mixes OAuth-token and ANTHROPIC_* variables"
fi

# v1 cleanup: only the v1 plugin (user scope) and marketplace are removed; a project-scope
# install is only reported, and other plugins are left alone.
LEGACY_HOME="$TMP/home-legacy"
mkdir -p "$LEGACY_HOME/bin"
cat > "$LEGACY_HOME/bin/claude" <<'FAKE'
#!/bin/sh
case "$*" in
  "plugin list --json")
    echo '[{"id":"orchestrate@my-orchestrate-skill","scope":"user"},{"id":"orchestrate@my-orchestrate-skill","scope":"project"},{"id":"x@y","scope":"user"}]' ;;
  "plugin marketplace list --json") echo '[{"name":"my-orchestrate-skill"},{"name":"other"}]' ;;
  *) echo "$*" >> "$HOME/claude-calls.log" ;;
esac
FAKE
chmod +x "$LEGACY_HOME/bin/claude"
LEGACY_OUT="$(PATH="$LEGACY_HOME/bin:$PATH" HOME="$LEGACY_HOME" "$REPO_ROOT/install.sh" --skill-only 2>&1 || true)"
if [ "$(cat "$LEGACY_HOME/claude-calls.log" 2>/dev/null)" = "$(printf 'plugin uninstall orchestrate@my-orchestrate-skill --scope user\nplugin marketplace remove my-orchestrate-skill')" ] \
  && printf '%s\n' "$LEGACY_OUT" | grep -q 'installed at project scope'; then
  ok "install.sh removes the v1 plugin and marketplace, reports a project-scope install, and leaves other plugins alone"
else
  fail "install.sh v1 cleanup made unexpected claude calls: $(tr '\n' ';' < "$LEGACY_HOME/claude-calls.log" 2>/dev/null)"
fi

# --skill-only installs just the skill.
SKILL_HOME="$TMP/home-skill"
mkdir -p "$SKILL_HOME"
if HOME="$SKILL_HOME" "$REPO_ROOT/install.sh" --skill-only >/dev/null 2>&1 \
  && [ -f "$SKILL_HOME/.claude/skills/supervisor/SKILL.md" ] && [ -f "$SKILL_HOME/.claude/skills/supervisor/roles/peer.md" ] \
  && [ ! -e "$SKILL_HOME/.paseo" ]; then
  ok "install.sh --skill-only installs only the supervisor skill"
else
  fail "install.sh --skill-only did not install just skills/supervisor"
fi

# Piped (the update path): it downloads the repository tarball and installs both parts.
tar -czf "$TMP/repo.tgz" --exclude .git -C "$(dirname "$REPO_ROOT")" "$(basename "$REPO_ROOT")"
PIPED_HOME="$TMP/home-piped"
mkdir -p "$PIPED_HOME"
if (cd /tmp && cat "$REPO_ROOT/install.sh" | SLP_TARBALL_URL="file://$TMP/repo.tgz" HOME="$PIPED_HOME" bash -s -- --no-reload) >/dev/null 2>&1 \
  && [ -f "$PIPED_HOME/.claude/skills/supervisor/SKILL.md" ] \
  && [ -f "$PIPED_HOME/.config/slp-room/claude-peer/output-styles/slp-peer.md" ] && [ -f "$PIPED_HOME/.paseo/config.json" ]; then
  ok "piped install.sh downloads the repository and installs the skill and the Paseo room"
else
  fail "piped install.sh failed"
fi

# --- README.md --------------------------------------------------------------

README="README.md"
for heading in "## Install" "## Usage" "## Troubleshooting"; do
  if grep -qF -- "$heading" "$README"; then
    ok "README.md contains heading '$heading'"
  else
    fail "README.md missing heading '$heading'"
  fi
done

if grep -qF -- "/supervisor" "$README"; then
  ok "README.md mentions /supervisor"
else
  fail "README.md does not mention /supervisor"
fi

# --- version tag reminder (warning only) ------------------------------------

TAG="v$PLUGIN_VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  TAG_COMMIT="$(git rev-list -n1 "$TAG")"
  HEAD_COMMIT="$(git rev-parse HEAD)"
  if [ "$TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    printf 'WARN: tag %s exists but HEAD (%s) differs from it (%s) — bump the version?\n' \
      "$TAG" "$HEAD_COMMIT" "$TAG_COMMIT"
  fi
fi

# --- room helper: slp-wait ---------------------------------------------------

BIN="$RENDER_HOME/.config/slp-room/bin"
if [ -x "$BIN/slp-wait" ] \
  && [ "$(stat -c %a "$BIN/slp-wait" 2>/dev/null || stat -f %Lp "$BIN/slp-wait")" = "755" ] \
  && cmp -s paseo/bin/slp-wait "$BIN/slp-wait" \
  && jq -e --arg bin "$RENDER_HOME/bin" --arg room "$BIN" '.agents.providers as $p
      | ($p["claude-lead"].disallowedTools | index("Bash(paseo:*)") != null and index("Bash(" + $bin + "/paseo:*)") != null)
      and ($p["claude-lead"].disallowedTools | index("Bash(slp-wait:*)") != null
           and index("Bash(" + $room + "/slp-wait:*)") != null)
      and ($p["claude-lead"].disallowedTools | map(select(. != "Bash(slp-wait:*)" and . != "Bash(" + $room + "/slp-wait:*)")))
          == ($p["claude-peer"].disallowedTools | map(select(. != "Bash(slp-wait:*)" and . != "Bash(" + $room + "/slp-wait:*)")))
      and ($p["claude-peer"].disallowedTools | index("Bash(slp-wait:*)") != null
           and index("Bash(" + $room + "/slp-wait:*)") != null and index("Bash(paseo:*)") != null)
      and ($p["claude-supervisor"].disallowedTools | map(select(. == "Bash(slp-wait:*)" or . == "Bash(" + $room + "/slp-wait:*)")) == []
           and index("Bash(paseo:*)") == null)' \
    "$RENDER_HOME/.paseo/config.json" >/dev/null \
  && grep -qF '"slp-wait"' "$RENDER_HOME/.config/slp-room/codex-peer/rules/room.rules" \
  && grep -qF "\"$BIN/slp-wait\"" "$RENDER_HOME/.config/slp-room/codex-peer/rules/room.rules"; then
  ok "install.sh installs slp-wait (0755); Leads and Peers (Claude and Codex) may not run it; the Supervisor's denies are unchanged"
else
  fail "slp-wait not installed as expected, or Lead/Peer/Supervisor/Codex denies wrong"
fi

# slp-wait has exactly one CLI invocation, and it is `paseo wait`.
if [ "$(grep -v '^[[:space:]]*#' paseo/bin/slp-wait | grep -v 'command -v paseo' | grep -c 'paseo')" = 1 ] \
  && grep -v '^[[:space:]]*#' paseo/bin/slp-wait | grep -q 'paseo wait "\$@"'; then
  ok "slp-wait invokes only \`paseo wait\`"
else
  fail "slp-wait must contain exactly one paseo invocation: paseo wait"
fi

# Behaviour, with a stub paseo that logs its argv.
SW="$TMP/slpw"; mkdir -p "$SW/bin"
cat > "$SW/bin/paseo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SLPW_LOG"
[ "$2" = "--help" ] && exit 0
[ -n "${SLPW_FAIL:-}" ] && { echo "boom" >&2; exit 1; }
printf '{\n  "agentId": "x",\n  "status": "%s",\n  "message": "a \\"status\\": \\"error\\""\n}\n' "$SLPW_STATUS"
STUB
chmod +x "$SW/bin/paseo"
export SLPW_LOG="$SW/log"
WID=807f4913-fffe-4d62-b090-016f1fc6dd7f
sw() { : > "$SLPW_LOG"; PATH="$SW/bin:$PATH" "$BIN/slp-wait" "$@" 2>/dev/null; }
SW_OK=1
out="$(SLPW_STATUS=timeout sw "$WID" 60)" || SW_OK=0
[ "$out" = "slp-wait: $WID timeout" ] && [ "$(cat "$SLPW_LOG")" = "wait $WID --timeout 60 --json" ] || SW_OK=0
for st in idle permission; do
  out="$(SLPW_STATUS=$st sw "$WID" 120)" || SW_OK=0
  [ "$out" = "slp-wait: $WID $st" ] || SW_OK=0
done
SLPW_STATUS=error sw "$WID" 30 >/dev/null && SW_OK=0
SLPW_FAIL=1 sw "$WID" 30 >/dev/null && SW_OK=0
for bad in "x; paseo run|60" "abc|60" "$(printf '%s' "$WID" | tr a-f A-F)|60" "$WID|0" "$WID|29" "$WID|121" "$WID|570" "$WID|571" "$WID|0060" "$WID|1200" "$WID|abc" "$WID|" "|60" "|" "$WID|-5" "$WID|60.5"; do
  rc=0; SLPW_STATUS=idle sw "${bad%%|*}" "${bad#*|}" >/dev/null || rc=$?
  [ "$rc" = 2 ] && [ ! -s "$SLPW_LOG" ] || { SW_OK=0; echo "  not rejected: $bad"; }
done
# Embedded CR/LF must be rejected as a whole (no line-by-line pass), with nothing logged
# and no stray shell error on stderr.
NL='
'
for bad_id in "$WID${NL}x" "x${NL}$WID" "${WID}${NL}" "$(printf '%s\r' "$WID")"; do
  rc=0; err="$(: > "$SLPW_LOG"; PATH="$SW/bin:$PATH" SLPW_STATUS=idle "$BIN/slp-wait" "$bad_id" 60 2>&1 >/dev/null)" || rc=$?
  [ "$rc" = 2 ] && [ ! -s "$SLPW_LOG" ] && [ "$(printf '%s\n' "$err" | head -1 | cut -c1-6)" = "usage:" ] && [ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 1 ] \
    || { SW_OK=0; echo "  id with CR/LF not rejected cleanly"; }
done
for bad_secs in "60${NL}60" "${NL}60" "60${NL}" "$(printf '60\r')"; do
  rc=0; err="$(: > "$SLPW_LOG"; PATH="$SW/bin:$PATH" SLPW_STATUS=idle "$BIN/slp-wait" "$WID" "$bad_secs" 2>&1 >/dev/null)" || rc=$?
  [ "$rc" = 2 ] && [ ! -s "$SLPW_LOG" ] && [ "$(printf '%s\n' "$err" | head -1 | cut -c1-6)" = "usage:" ] && [ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 1 ] \
    || { SW_OK=0; echo "  seconds with CR/LF not rejected cleanly"; }
done
for args in "$WID 60 extra" "--foo" "$WID --foo" "$WID" "" "--self-test $WID"; do
  rc=0; SLPW_STATUS=idle sw $args >/dev/null || rc=$?
  [ "$rc" = 2 ] && [ ! -s "$SLPW_LOG" ] || { SW_OK=0; echo "  not rejected: $args"; }
done
sw --self-test >/dev/null && [ "$(cat "$SLPW_LOG")" = "wait --help" ] || SW_OK=0
rc=0; PATH="/usr/bin:/bin" "$BIN/slp-wait" --self-test >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || SW_OK=0
if [ "$SW_OK" = 1 ]; then
  ok "slp-wait runs exactly 'paseo wait <id> --timeout <s> --json', prints one status line, and rejects bad input with exit 2 before calling paseo"
else
  fail "slp-wait behaviour with a stub paseo is wrong"
fi

# --- room rules: Supervisor wait, room-state block, Lead DONE, heartbeat ------

# Static: the rules exist, and the old instructions are gone.
RULE_PHRASES=(
  'SKILL.md|⏳ Working:'
  'SKILL.md|↳ <Peer title> (running|permission pending)'
  'SKILL.md|✅ Done:'
  'SKILL.md|❓ Waiting on you:'
  'SKILL.md|`supervisor: room`'
  'SKILL.md|The name must stay exactly `supervisor: room`'
  'SKILL.md|paseo.parent-agent-id'
  'SKILL.md|schedule. Leave Leads unarchived'
  'SKILL.md|Never remove'
  'SKILL.md|not a refusal: an event arrived'
  'SKILL.md|never wrap `slp-wait` in a shell loop'
  'SKILL.md|Never end ✅ in that'
  'SKILL.md|turn that ends stops spinning, so it ends on `⏳` only in the two cases above'
  'SKILL.md|go to the person exception below, and do not re-arm'
  'SKILL.md|route or apply any instruction or decision'
  'SKILL.md|confirm your `supervisor: room` heartbeat exists'
  'SKILL.md|do NOT end the turn'
  'SKILL.md|LAST tool call before your'
  'SKILL.md|rarely up to about 4 if Paseo skips a heartbeat slot'
  'SKILL.md|or the call returns an error, do NOT end the turn'
  'SKILL.md|known Paseo-side limit'
  'SKILL.md|skipped, not queued'
  'SKILL.md|record a skipped slot twice (overlapping'
  'SKILL.md|thinking is not visible to the person'
  'PROTOCOL.md|visible assistant text'
  'PROTOCOL.md|the one exception'
  'PROTOCOL.md|heartbeat exists (its last tool call)'
  'PROTOCOL.md|rarely up to about 4 if Paseo skips a'
  'PROTOCOL.md|call errors, it does not end the turn'
  'PROTOCOL.md|a known Paseo-side limit'
  'PROTOCOL.md|ending is skipped, not queued'
  'PROTOCOL.md|can record a skipped slot'
  'SKILL.md|begins with `@@`'
  'SKILL.md|$PASEO_AGENT_ID'
  'PROTOCOL.md|never ends a turn'
  'PROTOCOL.md|slp-wait — the Supervisor'
  'PROTOCOL.md|never wrap `slp-wait` in a shell loop'
  'PROTOCOL.md|Leads and Peers never do'
  'PROTOCOL.md|is valid only when, at report time, no Peer'
  'roles/lead.md|no Peer of'
  'roles/peer.md|`slp-wait` is the Supervisor'
)
for entry in "${RULE_PHRASES[@]}"; do
  file="$ROOM_DIR/${entry%%|*}"
  phrase="${entry#*|}"
  if grep -qF -- "$phrase" "$file"; then
    ok "$file keeps the room rule '$phrase'"
  else
    fail "$file missing room rule '$phrase'"
  fi
done

if grep -qE '├─|└─|\|_ ' "$ROOM_DIR/SKILL.md"; then
  fail "$ROOM_DIR/SKILL.md still shows an old room-state connector (├─, └─, or |_)"
else
  ok "$ROOM_DIR/SKILL.md carries no old room-state connector (├─, └─, |_)"
fi

for phrase in 'skipped, not queued' 'record a skipped slot twice' 'the next slot usually resumes it'; do
  if grep -qF -- "$phrase" README.md; then
    ok "README.md states the heartbeat-restart limit: '$phrase'"
  else
    fail "README.md missing heartbeat-restart limit wording '$phrase'"
  fi
done

if ! grep -q 'no change' "$ROOM_DIR/SKILL.md" \
  && ! grep -qE 'list_schedules`? *and reuse|reuse a heartbeat' "$ROOM_DIR/SKILL.md" \
  && ! grep -q 'Do not wait on a Peer' "$ROOM_DIR/SKILL.md" \
  && ! grep -qE 'slp-wait|@@SLP_WAIT@@' "$ROOM_DIR/roles/lead.md" \
  && ! grep -rqiE 'in-flight `?slp-wait|sitting in its `?slp-wait|Leads? (may|can|must|should|will)? ?(run|use|wait with|waits? with|waits? through) `?slp-wait|(Supervisor|Peers?) and Leads? (run|wait|may run|may use)|seats wait through|Lead is idle or|Lead waits there|Peers? (run|runs|may run) `?slp-wait' \
       "$ROOM_DIR" README.md CONTRIBUTING.md evals; then
  ok "no bare no-change turn end, list_schedules reuse rule, Lead/Peer-side slp-wait, or idle-Lead Peer send exception survives in skills/, README, CONTRIBUTING, or evals/"
else
  fail "a superseded rule survives in skills/, README, CONTRIBUTING, or evals/: a bare no-change turn end, a list_schedules reuse, Lead/Peer-side slp-wait, or an idle-Lead Peer send exception"
fi

# The Supervisor's wait timeout keeps a room inspection at least every 2 minutes (<= 120 s).
WAIT_SECS="$(grep -oE 'SLP_WAIT <id> [0-9]+' "$ROOM_DIR/SKILL.md" | awk '{print $3}')"
if [ -n "$WAIT_SECS" ] && [ "$(printf '%s\n' "$WAIT_SECS" | awk '$1 > 120 || $1 < 30 { bad = 1 } END { print bad + 0 }')" = 0 ]; then
  ok "SKILL.md's slp-wait timeout ($(printf '%s' "$WAIT_SECS" | tr '\n' ' ')s) is within 30-120"
else
  fail "SKILL.md's slp-wait timeout must be present and within 30-120 s (got: '$WAIT_SECS')"
fi

# Rendered: the Supervisor prompt of the temp install names a slp-wait that exists there; the Lead
# and Peer prompts never name it (their providers deny it); no token is left in any rendered file.
ROOM="$RENDER_HOME/.config/slp-room"
WAIT_PATH="$ROOM/bin/slp-wait"
RENDER_OK=1
for f in "$ROOM/claude-supervisor/output-styles/slp-supervisor.md" "$ROOM/supervisor.md"; do
  grep -qF "$WAIT_PATH" "$f" || { RENDER_OK=0; echo "  $f does not name $WAIT_PATH"; }
done
for f in "$ROOM/claude-lead/output-styles/slp-lead.md" "$ROOM/lead.md" "$ROOM/room/roles/lead.md"; do
  if grep -qF "$WAIT_PATH" "$f" || grep -qF '@@SLP_WAIT@@' "$f"; then RENDER_OK=0; echo "  $f names slp-wait"; fi
done
cmp -s skills/supervisor/roles/lead.md "$ROOM/room/roles/lead.md" || { RENDER_OK=0; echo "  room/roles/lead.md is not a plain copy"; }
[ -x "$WAIT_PATH" ] || RENDER_OK=0
if grep -rq '@@SLP_WAIT@@' "$ROOM" --include='*.md'; then RENDER_OK=0; echo "  a rendered file still has @@SLP_WAIT@@"; fi
if [ "$RENDER_OK" = 1 ]; then
  ok "rendered Supervisor prompt names $WAIT_PATH (exists, executable); the Lead prompt does not; no token left"
else
  fail "rendered prompts wrong: the Supervisor must name an existing slp-wait, the Lead must not"
fi

# claude-lead's rendered denies are an exact set: main's baseline (Agent, Task, and the three
# spawners by name) plus Bash(<path>:*) for every spawner copy and symlink target install.sh
# discovers on the render's PATH (mirrored here), plus exactly slp-wait by basename and by the
# rendered absolute path. Compared as sorted arrays; mutations must fail.
EXPECT_PATHS=()
for cli in paseo claude codex; do
  while IFS= read -r found; do
    [ -n "$found" ] || continue
    EXPECT_PATHS+=("Bash($found:*)")
    target="$(readlink -f "$found" 2>/dev/null || true)"
    [ -z "$target" ] || EXPECT_PATHS+=("Bash($target:*)")
  done < <(PATH="$RENDER_HOME/bin:$PATH" type -ap "$cli" 2>/dev/null || true)
done
LEAD_DENIES="$(jq -c '.agents.providers["claude-lead"].disallowedTools' "$RENDER_HOME/.paseo/config.json")"
lead_denies_exact() {  # compare sorted arrays for equality
  local expected
  expected="$(jq -cn --arg wait "$WAIT_PATH" '["Agent", "Task", "Bash(claude:*)", "Bash(codex:*)", "Bash(paseo:*)",
     "Bash(slp-wait:*)", "Bash(" + $wait + ":*)"] + $ARGS.positional | unique' \
    --args ${EXPECT_PATHS[@]+"${EXPECT_PATHS[@]}"})"
  [ "$(printf '%s' "$1" | jq -c 'sort')" = "$expected" ]
}
DENY_OK=1
lead_denies_exact "$LEAD_DENIES" || { DENY_OK=0; echo "  claude-lead denies differ from the expected set"; }
lead_denies_exact "$(printf '%s' "$LEAD_DENIES" | jq -c '. + ["Bash(/tmp/paseo:*)"]')" \
  && { DENY_OK=0; echo "  an extra Bash(/tmp/paseo:*) was accepted"; }
[ "${#EXPECT_PATHS[@]}" -gt 0 ] || DENY_OK=0
lead_denies_exact "$(printf '%s' "$LEAD_DENIES" | jq -c --arg d "${EXPECT_PATHS[0]:-}" 'map(select(. != $d))')" \
  && { DENY_OK=0; echo "  a missing discovered path was accepted"; }
lead_denies_exact "$(printf '%s' "$LEAD_DENIES" | jq -c 'map(select(. != "Bash(slp-wait:*)"))')" \
  && { DENY_OK=0; echo "  a missing slp-wait entry was accepted"; }
[ "$(jq -c '.agents.providers["claude-peer"].disallowedTools | sort' "$RENDER_HOME/.paseo/config.json")" = "$(printf '%s' "$LEAD_DENIES" | jq -c 'sort')" ] \
  || { DENY_OK=0; echo "  claude-peer denies differ from claude-lead's"; }
if [ "$DENY_OK" = 1 ]; then
  ok "claude-lead's rendered denies equal the expected set (baseline + discovered spawner paths + the two slp-wait entries); extra/missing entries fail"
else
  fail "claude-lead's rendered denies must equal baseline + discovered spawner paths + slp-wait by basename and absolute path"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "validate.sh: FAILED"
  exit 1
fi
echo "validate.sh: all checks passed"
