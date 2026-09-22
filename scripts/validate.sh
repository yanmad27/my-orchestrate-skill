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

SKILL_MD="skills/orchestrate/SKILL.md"

cat > "$TMP/check_frontmatter.py" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()

m = re.match(r'^---\n(.*?\n)---\n', text, re.DOTALL)
if not m:
    print("FAIL: SKILL.md missing YAML frontmatter delimiters")
    sys.exit(1)
fm_text = m.group(1)

failed = False
try:
    import yaml
    fm = yaml.safe_load(fm_text)
    print("ok: SKILL.md frontmatter parses as YAML")
except Exception as e:
    print(f"FAIL: SKILL.md frontmatter failed to parse as YAML: {e}")
    sys.exit(1)

if isinstance(fm, dict) and set(fm.keys()) == {"name", "description"}:
    print("ok: SKILL.md frontmatter has exactly keys name, description")
else:
    keys = sorted(fm.keys()) if isinstance(fm, dict) else fm
    print(f"FAIL: SKILL.md frontmatter keys are {keys!r}, expected exactly [name, description]")
    failed = True

name = fm.get("name") if isinstance(fm, dict) else None
if name == "orchestrate":
    print('ok: SKILL.md frontmatter name == "orchestrate"')
else:
    print(f'FAIL: SKILL.md frontmatter name is {name!r}, expected "orchestrate"')
    failed = True

desc = fm.get("description") if isinstance(fm, dict) else None
required = ["create_agent", "orchestrate", "delegate"]
if isinstance(desc, str) and "\n" not in desc and all(p in desc for p in required):
    print("ok: SKILL.md frontmatter description is one line and mentions create_agent/orchestrate/delegate")
else:
    print("FAIL: SKILL.md frontmatter description is not a single line containing create_agent, orchestrate, and delegate")
    failed = True

sys.exit(1 if failed else 0)
PY

python3 "$TMP/check_frontmatter.py" "$SKILL_MD" || FAILED=1

# --- SKILL.md body invariant phrases --------------------------------------

BODY_PHRASES=(
  "create_agent"
  'Never delegate with the built-in `Agent` tool'
  "list_profiles"
  "Never launch opus as a first attempt"
  "Reviewer"
  '$ARGUMENTS'
)
for phrase in "${BODY_PHRASES[@]}"; do
  if grep -qF -- "$phrase" "$SKILL_MD"; then
    ok "SKILL.md body contains '$phrase'"
  else
    fail "SKILL.md body missing required phrase '$phrase'"
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

if [ "$(jq -r '.name' "$PLUGIN_JSON")" = "orchestrate" ]; then
  ok 'plugin.json .name == "orchestrate"'
else
  fail 'plugin.json .name != "orchestrate"'
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

EXPECTED_PROFILES="Cheap worker,Lead,Reviewer,Worker"
ACTUAL_PROFILES="$(jq -r '[.daemon.agentProfiles[].name] | sort | join(",")' "$SNIPPET")"
if [ "$ACTUAL_PROFILES" = "$EXPECTED_PROFILES" ]; then
  ok "config.snippet.json profile names are exactly Lead, Cheap worker, Worker, Reviewer"
else
  fail "config.snippet.json profile names are [$ACTUAL_PROFILES], expected [$EXPECTED_PROFILES]"
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

REVIEWER_MODE="$(jq -r '.daemon.agentProfiles[] | select(.name == "Reviewer") | .modeId' "$SNIPPET")"
if [ "$REVIEWER_MODE" = "plan" ]; then
  ok 'Reviewer profile modeId == "plan"'
else
  fail "Reviewer profile modeId is '$REVIEWER_MODE', expected 'plan'"
fi

if jq -e '.agents.providers["claude-worker"] != null' "$SNIPPET" >/dev/null; then
  ok 'agents.providers["claude-worker"] exists'
else
  fail 'agents.providers["claude-worker"] is missing'
fi

# --- install.sh syntax and lint --------------------------------------------

if bash -n install.sh; then
  ok "install.sh has valid bash syntax"
else
  fail "install.sh has a bash syntax error"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning install.sh; then
    ok "install.sh passes shellcheck -S warning"
  else
    fail "install.sh has shellcheck warnings"
  fi
else
  ok "shellcheck not installed, skipping lint"
fi

# --- install.sh functional tests -------------------------------------------

LOCAL_HOME="$TMP/home-local"
mkdir -p "$LOCAL_HOME"
if HOME="$LOCAL_HOME" "$REPO_ROOT/install.sh" --paseo-only >/dev/null 2>&1; then
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
if HOME="$HEAL_HOME" "$REPO_ROOT/install.sh" --paseo-only >/dev/null 2>&1; then
  MISSING_IDS="$(jq -r '[.daemon.agentProfiles[] | select(has("id") | not)] | length' "$HEAL_HOME/.paseo/config.json")"
  if [ "$MISSING_IDS" = "0" ]; then
    ok "install.sh --paseo-only heals pre-existing profiles that are missing id"
  else
    fail "install.sh --paseo-only left $MISSING_IDS pre-existing profile(s) without id"
  fi
else
  fail "install.sh --paseo-only failed to run against a config with id-less profiles"
fi

PIPED_HOME="$TMP/home-piped"
mkdir -p "$PIPED_HOME"
if (cd /tmp && cat "$REPO_ROOT/install.sh" | HOME="$PIPED_HOME" bash -s -- --skill-only) >/dev/null 2>&1; then
  fail "piped install.sh --skill-only should fail without a local checkout, but exited 0"
else
  ok "piped install.sh --skill-only correctly fails without a local checkout"
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

if grep -qF -- "/orchestrate" "$README"; then
  ok "README.md mentions /orchestrate"
else
  fail "README.md does not mention /orchestrate"
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

if [ "$FAILED" -ne 0 ]; then
  echo "validate.sh: FAILED"
  exit 1
fi
echo "validate.sh: all checks passed"
