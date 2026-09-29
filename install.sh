#!/usr/bin/env bash
# Installs — and, run again, updates — the Supervisor → Lead → Peer room:
#   0. removes v1 (the orchestrate@my-orchestrate-skill plugin, its marketplace, watchdogs)
#   1. the /supervisor skill            → ~/.claude/skills/supervisor
#   2. a Claude runtime per seat — Supervisor, Lead, Peer (its role as an output style,
#      sharing your settings, skills, and one token) and the Codex launcher
#                                        → ~/.config/slp-room
#   3. the room's profiles and providers → ~/.paseo/config.json (backup kept alongside)
#   4. paseo daemon reload
# From a checkout: ./install.sh   Piped: curl -fsSL <raw>/install.sh | bash
# (Commands that could read stdin get </dev/null, so they never eat a piped script.)
# Options: --skill-only, --paseo-only, --no-reload, --token (ask for a new Claude token),
# --endpoint (ask for a custom Anthropic-compatible base URL + key instead of a token).
# Non-interactive endpoint: SLP_CLAUDE_BASE_URL, SLP_CLAUDE_API_KEY, and SLP_CLAUDE_AUTH_HEADER
# (bearer, the default → ANTHROPIC_AUTH_TOKEN; or x-api-key → ANTHROPIC_API_KEY).
# SLP_REF picks a branch or tag.
set -euo pipefail

REPO="yanmad27/paseo-slp"
TARBALL_URL="${SLP_TARBALL_URL:-https://codeload.github.com/$REPO/tar.gz/${SLP_REF:-main}}"
ROOM_HOME="${SLP_ROOM_HOME:-$HOME/.config/slp-room}"

DO_SKILL=1
DO_PASEO=1
RELOAD=1
ASK_TOKEN=0
ASK_ENDPOINT=0
for arg in "$@"; do
  case "$arg" in
    --skill-only) DO_PASEO=0 ;;
    --paseo-only) DO_SKILL=0 ;;
    --no-reload) RELOAD=0 ;;
    --token) ASK_TOKEN=1 ;;
    --endpoint) ASK_ENDPOINT=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done
if [ "$DO_SKILL" = 0 ] && [ "$DO_PASEO" = 0 ]; then
  echo "--skill-only and --paseo-only are mutually exclusive; pass at most one." >&2
  exit 1
fi

# Custom Anthropic-compatible endpoint, from the environment (never from an argument: it
# would land in shell history and ps). Validated here so a bad value stops before any change.
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
norm_url() {
  local u
  u="$(trim "$1")"
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  case "$u" in http://?*|https://?*) printf '%s' "$u" ;; *) return 1 ;; esac
}
EP_URL="${SLP_CLAUDE_BASE_URL:-}"
EP_KEY="$(trim "${SLP_CLAUDE_API_KEY:-}")"
EP_HDR="${SLP_CLAUDE_AUTH_HEADER:-}"
if [ -n "$EP_URL" ]; then
  EP_URL="$(norm_url "$EP_URL")" || { echo "SLP_CLAUDE_BASE_URL must start with http:// or https://." >&2; exit 1; }
fi
case "$EP_KEY" in *[[:space:]]*) echo "SLP_CLAUDE_API_KEY must not contain whitespace." >&2; exit 1 ;; esac
case "$EP_HDR" in ""|bearer|x-api-key) ;; *) echo "SLP_CLAUDE_AUTH_HEADER must be bearer or x-api-key." >&2; exit 1 ;; esac
if { [ -n "${SLP_CLAUDE_OAUTH_TOKEN:-}" ] || [ "$ASK_TOKEN" = 1 ]; } \
  && { [ -n "$EP_URL$EP_KEY$EP_HDR" ] || [ "$ASK_ENDPOINT" = 1 ]; }; then
  echo "Choose one auth mode: a setup-token (--token, SLP_CLAUDE_OAUTH_TOKEN) or a custom endpoint" >&2
  echo "  (--endpoint, SLP_CLAUDE_BASE_URL / SLP_CLAUDE_API_KEY / SLP_CLAUDE_AUTH_HEADER), not both." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Source: this checkout, or the repository tarball when piped.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] \
  && [ -d "$(dirname "${BASH_SOURCE[0]}")/skills/supervisor" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  command -v curl >/dev/null 2>&1 || { echo "curl is required to download $REPO." >&2; exit 1; }
  curl -fsSL "$TARBALL_URL" | tar -xz -C "$WORK" || { echo "Failed to download $TARBALL_URL" >&2; exit 1; }
  SRC="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -1)"
fi
VERSION="$(tr -d '[:space:]' < "$SRC/version.txt")"

# --- 0. v1 cleanup ------------------------------------------------------------------
# v1 shipped as orchestrate@my-orchestrate-skill; its /orchestrate skill would compete with
# the Supervisor. Remove the user-scope plugin and its marketplace, and stop any v1 watchdog.
# Project-scope installs live in other repositories' settings, so they are only reported.

LEGACY_PLUGIN="orchestrate@my-orchestrate-skill"
LEGACY_MARKETPLACE="my-orchestrate-skill"
if command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  LEGACY_SCOPES="$(claude plugin list --json </dev/null 2>/dev/null \
    | jq -r --arg id "$LEGACY_PLUGIN" '.[]? | select(.id == $id) | .scope // "user"' 2>/dev/null || true)"
  for scope in $LEGACY_SCOPES; do
    if [ "$scope" != user ]; then
      echo "NOTE: $LEGACY_PLUGIN is also installed at $scope scope; remove it from that project with: claude plugin uninstall $LEGACY_PLUGIN --scope $scope" >&2
    elif claude plugin uninstall "$LEGACY_PLUGIN" --scope user </dev/null >/dev/null 2>&1; then
      echo "Removed v1 plugin: $LEGACY_PLUGIN"
    else
      echo "WARNING: could not uninstall $LEGACY_PLUGIN; run: claude plugin uninstall $LEGACY_PLUGIN" >&2
    fi
  done
  if claude plugin marketplace list --json </dev/null 2>/dev/null \
    | jq -e --arg name "$LEGACY_MARKETPLACE" '.[]? | select(.name == $name)' >/dev/null 2>&1; then
    if claude plugin marketplace remove "$LEGACY_MARKETPLACE" </dev/null >/dev/null 2>&1; then
      echo "Removed v1 marketplace: $LEGACY_MARKETPLACE"
    else
      echo "WARNING: could not remove marketplace $LEGACY_MARKETPLACE; run: claude plugin marketplace remove $LEGACY_MARKETPLACE" >&2
    fi
  fi
fi
if command -v pkill >/dev/null 2>&1 && pkill -f 'skills/orchestrate/watchdog.mjs run' 2>/dev/null; then
  echo "Stopped v1 watchdog pollers"
fi
rm -f "${TMPDIR:-/tmp}"/orchestrate-watchdog-* 2>/dev/null || true

# --- 1. skill -------------------------------------------------------------------

if [ "$DO_SKILL" = 1 ]; then
  SKILLS="$HOME/.claude/skills"
  mkdir -p "$SKILLS"
  rm -rf "$SKILLS/supervisor"
  cp -R "$SRC/skills/supervisor" "$SKILLS/supervisor"
  echo "Installed skill: $SKILLS/supervisor"
  # v1 installed the same role as "orchestrate"; leaving it would compete with /supervisor.
  if [ -f "$SKILLS/orchestrate/SKILL.md" ] && grep -q '^name: orchestrate$' "$SKILLS/orchestrate/SKILL.md"; then
    rm -rf "$SKILLS/orchestrate"
    echo "Removed legacy skill: $SKILLS/orchestrate"
  fi
fi

if [ "$DO_PASEO" = 1 ]; then
  command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed. Install jq and re-run." >&2; exit 1; }

  # --- 2. role prompts, Claude runtimes, Codex launcher ---------------------------
  # Paseo has no per-agent system prompt. Each Claude seat (Supervisor, Lead, Peer) gets
  # its own Claude Code runtime (CLAUDE_CONFIG_DIR) whose output style carries protocol +
  # role, sharing the user's settings, skills, plugins, and CLAUDE.md, and one auth token.
  # Codex gets the Peer prompt as developer instructions through a launcher.

  CLAUDE_HOME="$HOME/.claude"
  ROOM_FILES="$ROOM_HOME/room"
  mkdir -p "$ROOM_HOME/bin" "$ROOM_FILES/roles"
  # A stable copy of the room files: every seat's ROOM_DIR, however the skill was installed.
  cp "$SRC/skills/supervisor/PROTOCOL.md" "$ROOM_FILES/PROTOCOL.md"
  cp "$SRC/skills/supervisor/roles/lead.md" "$SRC/skills/supervisor/roles/peer.md" "$ROOM_FILES/roles/"
  # The room's one blocking wait, at an absolute path the Supervisor prompt names: its
  # @@SLP_WAIT@@ token is replaced with it. Only the Supervisor waits; Leads and Peers are denied.
  cp "$SRC/paseo/bin/slp-wait" "$ROOM_HOME/bin/slp-wait"
  chmod 755 "$ROOM_HOME/bin/slp-wait"
  SLP_WAIT_SED="$(printf '%s' "$ROOM_HOME/bin/slp-wait" | sed 's/[\\&|]/\\&/g')"

  HEADER="<!-- Generated by install.sh (paseo-slp $VERSION). Re-run it to update; do not edit. -->"
  for role in lead peer; do
    {
      printf '%s\n\n' "$HEADER"
      cat "$ROOM_FILES/PROTOCOL.md"
      printf '\n---\n\n'
      cat "$ROOM_FILES/roles/$role.md"
    } > "$ROOM_HOME/$role.md"
  done
  {
    printf '%s\n\n' "$HEADER"
    printf '# Room role: Supervisor\n\n'
    printf 'This session is the Supervisor of a Paseo Supervisor → Lead → Peer room, and every user\n'
    printf 'message comes from Human. ROOM_DIR=%s. The room protocol follows, then the\n' "$ROOM_FILES"
    printf 'Supervisor role; where the role mentions /supervisor, $ARGUMENTS, or reading PROTOCOL.md,\n'
    printf 'this system prompt already covers it.\n\n'
    cat "$ROOM_FILES/PROTOCOL.md"
    printf '\n---\n\n'
    awk 'n >= 2 { print; next } /^---$/ { n++ }' "$SRC/skills/supervisor/SKILL.md" \
      | sed "s|@@SLP_WAIT@@|$SLP_WAIT_SED|g"  # drop the frontmatter
  } > "$ROOM_HOME/supervisor.md"

  for role in supervisor lead peer; do
    RUNTIME="$ROOM_HOME/claude-$role"
    mkdir -p "$RUNTIME/output-styles" "$RUNTIME/skills"
    {
      printf -- '---\nname: slp-%s\ndescription: Supervisor → Lead → Peer room, %s seat\nkeep-coding-instructions: true\n---\n\n' "$role" "$role"
      cat "$ROOM_HOME/$role.md"
    } > "$RUNTIME/output-styles/slp-$role.md"

    # The user's settings, with the seat's output style, and without this plugin: no seat
    # loads the /supervisor skill on top of its own role.
    USER_SETTINGS='{}'
    if [ -f "$CLAUDE_HOME/settings.json" ]; then
      if jq -e 'type == "object"' "$CLAUDE_HOME/settings.json" >/dev/null 2>&1; then
        USER_SETTINGS="$(cat "$CLAUDE_HOME/settings.json")"
      else
        echo "WARNING: $CLAUDE_HOME/settings.json is not a JSON object; the $role runtime starts from empty settings." >&2
      fi
    fi
    printf '%s' "$USER_SETTINGS" | jq --arg style "slp-$role" '
      .outputStyle = $style
      | .enabledPlugins = ((.enabledPlugins // {})
          | with_entries(if (.key | test("^(paseo-slp|orchestrate)@")) then .value = false else . end))
    ' > "$RUNTIME/settings.json"

    for shared in plugins agents commands CLAUDE.md; do
      if [ -e "$CLAUDE_HOME/$shared" ] && { [ -L "$RUNTIME/$shared" ] || [ ! -e "$RUNTIME/$shared" ]; }; then
        ln -sfn "$CLAUDE_HOME/$shared" "$RUNTIME/$shared"
      fi
    done
    find "$RUNTIME/skills" -mindepth 1 -maxdepth 1 -type l -exec rm -f {} +
    if [ -d "$CLAUDE_HOME/skills" ]; then
      for skill in "$CLAUDE_HOME/skills"/*; do
        case "$(basename "$skill")" in supervisor|orchestrate) continue ;; esac
        [ -e "$skill" ] && ln -sfn "$skill" "$RUNTIME/skills/$(basename "$skill")"
      done
    fi
  done
  rm -f "$ROOM_HOME/bin/claude-lead" "$ROOM_HOME/bin/claude-peer"  # launchers of an earlier version

  # Shared auth for every Claude seat, in one of two modes remembered in $ROOM_HOME/auth-mode:
  #   token     one `claude setup-token` token, kept in $ROOM_HOME/oauth-token (mode 600)
  #   endpoint  any Anthropic-compatible proxy or gateway: a base URL and a key, kept in
  #             $ROOM_HOME/anthropic-{base-url,api-key,auth-header} (mode 600)
  # Which mode applies: the SLP_CLAUDE_* variables and --token / --endpoint beat the saved
  # mode (default: token), and choosing one saves it; the two kinds together are an error
  # (checked up front). Missing or asked-for input is read on /dev/tty, which still works
  # when piped.
  TOKEN_FILE="$ROOM_HOME/oauth-token"
  MODE_FILE="$ROOM_HOME/auth-mode"
  URL_FILE="$ROOM_HOME/anthropic-base-url"
  KEY_FILE="$ROOM_HOME/anthropic-api-key"
  HDR_FILE="$ROOM_HOME/anthropic-auth-header"
  save_private() { (umask 077 && printf '%s\n' "$2" > "$1"); chmod 600 "$1"; }
  saved() { if [ -f "$1" ]; then tr -d '[:space:]' < "$1"; fi; }
  OAUTH_TOKEN="${SLP_CLAUDE_OAUTH_TOKEN:-}"
  HAS_TTY=0
  if [ -t 2 ] && { : < /dev/tty; } 2>/dev/null; then HAS_TTY=1; fi
  if [ "$ASK_TOKEN" = 1 ] && [ "$HAS_TTY" = 0 ]; then
    echo "WARNING: --token needs a terminal to ask on; keeping the saved token." >&2
    ASK_TOKEN=0
  fi
  if [ "$ASK_ENDPOINT" = 1 ] && [ "$HAS_TTY" = 0 ]; then
    echo "WARNING: --endpoint needs a terminal to ask on; keeping the saved settings." >&2
    ASK_ENDPOINT=0
  fi
  if [ -n "$EP_URL$EP_KEY$EP_HDR" ] || [ "$ASK_ENDPOINT" = 1 ]; then MODE=endpoint
  elif [ -n "$OAUTH_TOKEN" ] || [ "$ASK_TOKEN" = 1 ]; then MODE=token
  elif [ "$(saved "$MODE_FILE")" = endpoint ]; then MODE=endpoint
  else MODE=token
  fi

  if [ "$MODE" = token ]; then
    if [ -z "$OAUTH_TOKEN" ] && [ "$ASK_TOKEN" = 0 ] && [ -f "$TOKEN_FILE" ]; then
      OAUTH_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    fi
    if [ -z "$OAUTH_TOKEN" ] && [ "$ASK_TOKEN" = 0 ] && [ "$HAS_TTY" = 1 ]; then
      {
        echo
        echo "How should the room's Claude seats sign in?"
        echo "  1) a 'claude setup-token' token (default)"
        echo "  2) a custom Anthropic-compatible endpoint (base URL + key)"
        printf 'Choose 1 or 2: '
      } > /dev/tty
      IFS= read -r CHOICE < /dev/tty || CHOICE=""
      case "$(printf '%s' "$CHOICE" | tr -d '[:space:]')" in
        2) MODE=endpoint; ASK_ENDPOINT=1 ;;
      esac
    fi
  fi

  if [ "$MODE" = token ]; then
    if [ -z "$OAUTH_TOKEN" ] && [ "$HAS_TTY" = 1 ]; then
      {
        echo
        echo "The room's Claude seats share one token. In another terminal run 'claude setup-token',"
        echo "then paste the sk-ant-oat01-… line it prints (input hidden; Enter skips)."
        printf 'Token: '
      } > /dev/tty
      IFS= read -rs PASTED < /dev/tty || PASTED=""
      echo > /dev/tty
      PASTED="$(printf '%s' "$PASTED" | tr -d '[:space:]')"
      case "$PASTED" in
        "") ;;
        sk-ant-oat*)
          save_private "$TOKEN_FILE" "$PASTED"
          OAUTH_TOKEN="$PASTED"
          echo "Saved the token to $TOKEN_FILE"
          ;;
        *) echo "WARNING: that is not a 'claude setup-token' token (sk-ant-oat…); not saved." >&2 ;;
      esac
      PASTED=""
      # Skipping the prompt (or a bad paste) keeps the token that was already saved.
      if [ -z "$OAUTH_TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
        OAUTH_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
        [ -z "$OAUTH_TOKEN" ] || echo "Kept the saved token in $TOKEN_FILE"
      fi
    fi
    if [ -z "$OAUTH_TOKEN" ]; then
      echo "WARNING: no Claude token for the room runtimes. Run 'claude setup-token', then re-run" >&2
      echo "  install.sh with --token and paste it — or log in once per runtime:" >&2
      echo "  CLAUDE_CONFIG_DIR=$ROOM_HOME/claude-<supervisor|lead|peer> claude" >&2
    elif [ -n "${SLP_CLAUDE_OAUTH_TOKEN:-}" ] || [ "$ASK_TOKEN" = 1 ]; then
      save_private "$MODE_FILE" token  # an explicit choice: a later plain re-run keeps it
    fi
  fi

  # Endpoint mode: explicit values (SLP_CLAUDE_*) beat prompts, which beat what is saved.
  # Only the URL scheme and a non-blank, whitespace-free key are checked; the header form
  # picks the variable: bearer → ANTHROPIC_AUTH_TOKEN, x-api-key → ANTHROPIC_API_KEY.
  ENDPOINT_KEY_VAR=""
  if [ "$MODE" = endpoint ]; then
    NEW_URL="$EP_URL"; NEW_KEY="$EP_KEY"; NEW_HDR="$EP_HDR"
    CUR_URL="$NEW_URL"; CUR_KEY="$NEW_KEY"; CUR_HDR="$NEW_HDR"
    [ -n "$CUR_URL" ] || CUR_URL="$(saved "$URL_FILE")"
    [ -n "$CUR_KEY" ] || CUR_KEY="$(saved "$KEY_FILE")"
    [ -n "$CUR_HDR" ] || CUR_HDR="$(saved "$HDR_FILE")"
    ASK_URL=0; ASK_KEY=0
    if [ "$HAS_TTY" = 1 ]; then
      if [ -z "$NEW_URL" ] && { [ "$ASK_ENDPOINT" = 1 ] || [ -z "$CUR_URL" ]; }; then ASK_URL=1; fi
      if [ -z "$NEW_KEY" ] && { [ "$ASK_ENDPOINT" = 1 ] || [ -z "$CUR_KEY" ]; }; then ASK_KEY=1; fi
    fi
    if [ "$ASK_URL" = 1 ] || [ "$ASK_KEY" = 1 ]; then
      {
        echo
        echo "Custom endpoint: any Anthropic-compatible proxy or gateway (e.g. 9router, LiteLLM)."
        echo "Enter keeps what is saved (or skips)."
      } > /dev/tty
    fi
    if [ "$ASK_URL" = 1 ]; then
      printf 'Base URL%s: ' "${CUR_URL:+ [$CUR_URL]}" > /dev/tty
      IFS= read -r PASTED < /dev/tty || PASTED=""
      if [ -n "$(trim "$PASTED")" ]; then
        if PASTED="$(norm_url "$PASTED")"; then CUR_URL="$PASTED"
        else echo "WARNING: the base URL must start with http:// or https://; not saved." >&2; fi
      fi
    fi
    if [ "$ASK_KEY" = 1 ]; then
      printf 'Key (input hidden): ' > /dev/tty
      IFS= read -rs PASTED < /dev/tty || PASTED=""
      echo > /dev/tty
      PASTED="$(trim "$PASTED")"
      case "$PASTED" in
        "") ;;
        *[[:space:]]*) echo "WARNING: the key must not contain whitespace; not saved." >&2 ;;
        *) CUR_KEY="$PASTED" ;;
      esac
      PASTED=""
    fi
    if { [ "$ASK_URL" = 1 ] || [ "$ASK_KEY" = 1 ]; } && [ -z "$NEW_HDR" ]; then
      {
        echo "Send the key as:"
        echo "  1) 'Authorization: Bearer' (default; most proxies)"
        echo "  2) 'x-api-key'"
        printf 'Choose 1 or 2%s: ' "${CUR_HDR:+ [current: $CUR_HDR]}"
      } > /dev/tty
      IFS= read -r CHOICE < /dev/tty || CHOICE=""
      case "$(printf '%s' "$CHOICE" | tr -d '[:space:]')" in
        1) CUR_HDR=bearer ;;
        2) CUR_HDR=x-api-key ;;
      esac
    fi
    case "$CUR_HDR" in bearer|x-api-key) ;; *) CUR_HDR=bearer ;; esac
    if [ -n "$CUR_URL" ] && [ -n "$CUR_KEY" ]; then
      if [ "$CUR_URL" != "$(saved "$URL_FILE")" ] || [ "$CUR_KEY" != "$(saved "$KEY_FILE")" ] \
        || [ "$CUR_HDR" != "$(saved "$HDR_FILE")" ]; then
        save_private "$URL_FILE" "$CUR_URL"
        save_private "$KEY_FILE" "$CUR_KEY"
        save_private "$HDR_FILE" "$CUR_HDR"
        echo "Saved the endpoint to $ROOM_HOME/anthropic-{base-url,api-key,auth-header}"
      fi
      save_private "$MODE_FILE" endpoint
      BASE_URL="$CUR_URL"; API_KEY="$CUR_KEY"
      if [ "$CUR_HDR" = bearer ]; then ENDPOINT_KEY_VAR=ANTHROPIC_AUTH_TOKEN; else ENDPOINT_KEY_VAR=ANTHROPIC_API_KEY; fi
    elif [ -n "$EP_URL$EP_KEY$EP_HDR" ]; then
      echo "SLP_CLAUDE_BASE_URL and SLP_CLAUDE_API_KEY must both be set (or already saved by an earlier run)." >&2
      exit 1
    else
      echo "WARNING: no complete custom endpoint (base URL + key) for the room runtimes. Re-run" >&2
      echo "  install.sh with --endpoint, or with --token to use a 'claude setup-token' token instead." >&2
    fi
  fi

  # Every copy of the agent-spawning CLIs on PATH (and their symlink targets): Claude seats
  # deny them by name and path (step 3); the Codex runtime forbids them in its rules.
  SPAWNERS=()
  for cli in paseo claude codex; do
    while IFS= read -r found; do
      [ -n "$found" ] || continue
      SPAWNERS+=("$found")
      target="$(readlink -f "$found" 2>/dev/null || true)"
      [ -z "$target" ] || SPAWNERS+=("$target")
    done < <(type -ap "$cli" 2>/dev/null || true)
  done
  rm -rf "$ROOM_HOME/guard"  # PATH stubs of an earlier version: login shells reorder PATH past them

  # The Codex Peer runtime (CODEX_HOME), as codex-room-setup does it: shared auth, a copy of
  # the user's config, their AGENTS.md/skills/plugins, and rules that forbid spawning agents.
  CODEX_USER_HOME="${CODEX_HOME:-$HOME/.codex}"
  CODEX_RT="$ROOM_HOME/codex-peer"
  mkdir -p "$CODEX_RT/rules"
  if [ -f "$CODEX_USER_HOME/config.toml" ]; then
    cp "$CODEX_USER_HOME/config.toml" "$CODEX_RT/config.toml"
  fi
  for shared in auth.json AGENTS.md skills plugins; do
    if [ -e "$CODEX_USER_HOME/$shared" ] && { [ -L "$CODEX_RT/$shared" ] || [ ! -e "$CODEX_RT/$shared" ]; }; then
      ln -sfn "$CODEX_USER_HOME/$shared" "$CODEX_RT/$shared"
    fi
  done
  [ -e "$CODEX_RT/auth.json" ] || echo "WARNING: no $CODEX_USER_HOME/auth.json to share; run 'codex login' (file credentials) and re-run install.sh." >&2
  CODEX_FORBIDDEN="$(jq -rn '["paseo", "claude", "codex", "slp-wait"] + $ARGS.positional | unique | map(@json) | join(", ")' \
    --args ${SPAWNERS[@]+"${SPAWNERS[@]}"} "$ROOM_HOME/bin/slp-wait")"
  cat > "$CODEX_RT/rules/room.rules" <<RULES
# Generated by install.sh: a room seat never starts agents outside create_agent.
prefix_rule(
    pattern = [[$CODEX_FORBIDDEN]],
    decision = "forbidden",
    justification = "not allowed in a room seat: only the Supervisor and Leads create agents, via create_agent",
)
RULES

  CODEX_BIN="$(command -v codex || true)"
  if [ -z "$CODEX_BIN" ]; then
    echo "WARNING: codex is not on PATH; the codex-peer launcher will look it up each time it runs." >&2
    CODEX_BIN=codex
  fi
  # Codex takes the prompt as a TOML literal string, which cannot contain '''.
  if grep -qF "'''" "$ROOM_HOME/peer.md"; then
    echo "roles/peer.md or PROTOCOL.md contains ''' and cannot be passed to Codex; remove it and re-run." >&2
    exit 1
  fi
  # No native Codex sub-agents either (multi_agent_v2 is a table in some configs, a flag in others).
  V2_OFF="features.multi_agent_v2=false"
  if grep -q '^\[features\.multi_agent_v2\]' "$CODEX_RT/config.toml" 2>/dev/null; then
    V2_OFF="features.multi_agent_v2.enabled=false"
  fi
  cat > "$ROOM_HOME/bin/codex-peer" <<LAUNCHER
#!/bin/sh
# Generated by install.sh: Codex in the room's Peer runtime — the Peer role as developer
# instructions, native sub-agents off, and rules that forbid paseo/claude/codex.
CODEX_HOME="$CODEX_RT" exec "$CODEX_BIN" -c agents.enabled=false -c features.multi_agent=false -c $V2_OFF \\
  -c "developer_instructions='''\$(cat "$ROOM_HOME/peer.md")'''" "\$@"
LAUNCHER
  chmod +x "$ROOM_HOME/bin/codex-peer"
  echo "Rendered room runtimes and prompts: $ROOM_HOME"

  # --- 3. Paseo config ------------------------------------------------------------

  # Deny every copy of the spawners by absolute path too, so calling
  # /opt/homebrew/bin/claude is no way around the by-name rules.
  LEAD_ABS=()
  SUP_ABS=()
  for path in ${SPAWNERS[@]+"${SPAWNERS[@]}"}; do
    LEAD_ABS+=("Bash($path:*)")
    case "$(basename "$path")" in
      paseo) SUP_ABS+=("Bash($path run:*)" "Bash($path send:*)" "Bash($path import:*)") ;;
      *) SUP_ABS+=("Bash($path:*)") ;;
    esac
  done
  LEAD_ABS_JSON="$(jq -cn '$ARGS.positional | unique' --args ${LEAD_ABS[@]+"${LEAD_ABS[@]}"})"
  SUP_ABS_JSON="$(jq -cn '$ARGS.positional | unique' --args ${SUP_ABS[@]+"${SUP_ABS[@]}"})"
  # Only the Supervisor waits with slp-wait; Leads and Peers never do.
  NOWAIT_JSON="$(jq -cn --arg p "Bash($ROOM_HOME/bin/slp-wait:*)" '[$p]')"

  # With no token the env key is dropped, so a per-runtime login keeps working. In endpoint
  # mode the token key is replaced by the endpoint's base URL and key (the header form picks
  # which variable), so a provider never carries both modes' variables.
  jq --arg dir "$ROOM_HOME" --arg token "$OAUTH_TOKEN" \
    --arg baseUrl "${BASE_URL:-}" --arg apiKey "${API_KEY:-}" --arg keyVar "$ENDPOINT_KEY_VAR" \
    --argjson leadAbs "$LEAD_ABS_JSON" --argjson supAbs "$SUP_ABS_JSON" \
    --argjson noWait "$NOWAIT_JSON" '
    walk(if type == "string" then gsub("@@ROOM_HOME@@"; $dir) else . end)
    | .agents.providers |= map_values(
        if .env.CLAUDE_CODE_OAUTH_TOKEN == "@@CLAUDE_OAUTH_TOKEN@@" then
          (if $keyVar != "" then
             del(.env.CLAUDE_CODE_OAUTH_TOKEN) | .env.ANTHROPIC_BASE_URL = $baseUrl | .env[$keyVar] = $apiKey
           elif $token == "" then del(.env.CLAUDE_CODE_OAUTH_TOKEN) else .env.CLAUDE_CODE_OAUTH_TOKEN = $token end)
        else . end)
    | .agents.providers["claude-lead"].disallowedTools += $leadAbs + $noWait
    | .agents.providers["claude-peer"].disallowedTools += $leadAbs + $noWait
    | .agents.providers["claude-supervisor"].disallowedTools += $supAbs
  ' "$SRC/paseo/config.snippet.json" > "$WORK/snippet.json"

  PASEO_DIR="$HOME/.paseo"
  CONFIG="$PASEO_DIR/config.json"
  mkdir -p "$PASEO_DIR"
  # The config and its backups may hold the Claude token: keep them private.
  umask 077
  [ -f "$CONFIG" ] || echo '{"version":1}' > "$CONFIG"
  chmod 600 "$CONFIG"
  cp "$CONFIG" "$CONFIG.bak-$(date +%Y%m%d%H%M%S)"

  # The snippet's profiles (matched by id, or by name when an old install left no id) and
  # providers are owned by this script: each run replaces them with the snippet's version.
  # v1 profiles and the v1 claude-worker provider are removed. Everything else is kept.
  MERGE='
    ($snip[0].daemon.agentProfiles) as $new
    | ["agent_profile_orchestrate_cheap_worker", "agent_profile_orchestrate_worker",
       "agent_profile_orchestrate_expensive_worker", "agent_profile_orchestrate_reviewer",
       "agent_profile_orchestrate_codex_advisor"] as $legacyIds
    | ["Cheap worker", "Worker", "Expensive worker", "Reviewer", "Codex advisor"] as $legacyNames
    | (($new | map(.id)) + $legacyIds) as $ownedIds
    | (($new | map(.name)) + $legacyNames) as $ownedNames
    | def owned: if .id == null then (.name as $n | $ownedNames | index($n)) != null
                 else (.id as $i | $ownedIds | index($i)) != null end;
    .daemon.agentProfiles = (((.daemon.agentProfiles // []) | map(select(owned | not))) + $new)
    | (.daemon.agentProfiles | map(.provider)) as $used
    | .agents.providers = ((.agents.providers // {}) + $snip[0].agents.providers)
    | if (.agents.providers["claude-worker"].description // "") == "Delegated worker — cannot spawn or control other agents"
         and ($used | index("claude-worker")) == null
      then del(.agents.providers["claude-worker"]) else . end
  '
  TMP="$(mktemp "$CONFIG.XXXXXX")"
  jq --slurpfile snip "$WORK/snippet.json" "$MERGE" "$CONFIG" > "$TMP"
  REMOVED="$(jq -r --slurpfile after "$TMP" '
    [.daemon.agentProfiles[]?.name] - [$after[0].daemon.agentProfiles[].name] | join(", ")' "$CONFIG")"
  mv "$TMP" "$CONFIG"
  echo "Updated Paseo config: $CONFIG (backup saved alongside it)"
  echo "  Room profiles: $(jq -r '[.daemon.agentProfiles[].name] | join(", ")' "$WORK/snippet.json")"
  echo "  Room providers: $(jq -r '.agents.providers | keys | join(", ")' "$WORK/snippet.json")"
  [ -z "$OAUTH_TOKEN" ] || echo "  Claude runtimes share the token from $ROOM_HOME/oauth-token"
  [ -z "$ENDPOINT_KEY_VAR" ] || echo "  Claude runtimes use the endpoint $BASE_URL (key in $ROOM_HOME/anthropic-api-key, sent via $ENDPOINT_KEY_VAR)"
  [ -z "$REMOVED" ] || echo "  Removed v1 profiles: $REMOVED"
  DUPES="$(jq -r '[.daemon.agentProfiles[].name] | group_by(.) | map(select(length > 1)[0]) | join(", ")' "$CONFIG")"
  [ -z "$DUPES" ] || echo "WARNING: you also have your own profile(s) named $DUPES; rename yours so the room picks the right one." >&2

  if [ "$(jq -r '.daemon.mcp.injectIntoAgents // false' "$CONFIG")" != "true" ]; then
    echo "WARNING: daemon.mcp.injectIntoAgents is not enabled in $CONFIG" >&2
    echo "The Supervisor and Lead agents will not have the create_agent tool without it." >&2
    echo "Enable it by setting daemon.mcp.enabled: true and daemon.mcp.injectIntoAgents: true" >&2
  fi

  # --- 4. reload --------------------------------------------------------------------

  if [ "$RELOAD" = 0 ]; then
    echo "Run 'paseo daemon reload' to load the updated profiles and providers."
  elif command -v paseo >/dev/null 2>&1 && paseo daemon reload </dev/null; then
    :
  else
    echo "WARNING: could not run 'paseo daemon reload'; run it (or restart Paseo) yourself." >&2
  fi
fi

echo "paseo-slp $VERSION installed."
