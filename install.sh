#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/yanmad27/my-orchestrate-skill/main"

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

DO_SKILL=1
DO_PASEO=1
for arg in "$@"; do
  case "$arg" in
    --skill-only) DO_PASEO=0 ;;
    --paseo-only) DO_SKILL=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ "$DO_SKILL" = 0 ] && [ "$DO_PASEO" = 0 ]; then
  echo "--skill-only and --paseo-only are mutually exclusive; pass at most one." >&2
  exit 1
fi

if [ "$DO_SKILL" = 1 ]; then
  if [ -z "$SCRIPT_DIR" ]; then
    echo "skill copy requires a local checkout; use --paseo-only or clone the repo" >&2
    exit 1
  fi
  mkdir -p "$HOME/.claude/skills"
  rm -rf "$HOME/.claude/skills/orchestrate"
  cp -R "$SCRIPT_DIR/skills/orchestrate" "$HOME/.claude/skills/orchestrate"
  echo "Installed skill: $HOME/.claude/skills/orchestrate"
fi

if [ "$DO_PASEO" = 1 ]; then
  command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed. Install jq and re-run." >&2; exit 1; }

  PASEO_DIR="$HOME/.paseo"
  CONFIG="$PASEO_DIR/config.json"

  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/paseo/config.snippet.json" ]; then
    SNIPPET="$SCRIPT_DIR/paseo/config.snippet.json"
  else
    command -v curl >/dev/null 2>&1 || { echo "curl is required to download the Paseo config snippet." >&2; exit 1; }
    SNIPPET="$(mktemp)"
    trap 'rm -f "$SNIPPET"' EXIT
    curl -fsSL "$RAW_BASE/paseo/config.snippet.json" -o "$SNIPPET" || { echo "Failed to download $RAW_BASE/paseo/config.snippet.json" >&2; exit 1; }
  fi

  mkdir -p "$PASEO_DIR"
  if [ ! -f "$CONFIG" ]; then
    echo '{"version":1}' > "$CONFIG"
  fi

  cp "$CONFIG" "$CONFIG.bak-$(date +%Y%m%d%H%M%S)"

  MERGED="$(jq --slurpfile snip "$SNIPPET" '
    (.daemon.agentProfiles // []) as $existing
    | ($snip[0].daemon.agentProfiles) as $newProfiles
    | ($newProfiles | map(select(.id != null)) | map({key: .name, value: .id}) | from_entries) as $idsByName
    | ($existing | map(.name)) as $existingNames
    | ($newProfiles | map(select((.name as $n | $existingNames | index($n)) | not))) as $toAdd
    | ($existing | map(
        if (.id == null) and ($idsByName[.name] != null)
        then . + {id: $idsByName[.name]}
        else . end
      )) as $healed
    | .daemon.agentProfiles = ($healed + $toAdd)
    | (.agents.providers // {}) as $existingProviders
    | ($snip[0].agents.providers) as $newProviders
    | .agents.providers = ($existingProviders + ($newProviders | with_entries(select((.key as $k | $existingProviders | has($k)) | not))))
  ' "$CONFIG")"

  TMP="$(mktemp "$CONFIG.XXXXXX")"
  printf '%s\n' "$MERGED" > "$TMP"
  mv "$TMP" "$CONFIG"
  echo "Merged Paseo config: $CONFIG (backup saved alongside it)"

  INJECT_INTO_AGENTS="$(jq -r '.daemon.mcp.injectIntoAgents // false' "$CONFIG")"
  if [ "$INJECT_INTO_AGENTS" != "true" ]; then
    echo "WARNING: daemon.mcp.injectIntoAgents is not enabled in $CONFIG" >&2
    echo "The Lead agent will not have the create_agent tool without it." >&2
    echo "Enable it by setting daemon.mcp.enabled: true and daemon.mcp.injectIntoAgents: true" >&2
  fi

  echo "Run 'paseo daemon reload' to load the new profiles and provider."
fi
