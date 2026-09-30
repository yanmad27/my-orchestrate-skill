#!/usr/bin/env bash
# Sandbox tests for install.sh's slp-gc install: plist, config opt-ins, --gc-only, activation.
# Every run uses HOME=$tmp/home, a stub launchctl (SLP_LAUNCHCTL, also first on PATH) that logs
# argv, and stub paseo/claude/pkill. The real launchctl and real HOME are never used; the test
# checks that at the end. EVIDENCE_DIR=<dir> keeps the transcript, plist and listings.
set -uo pipefail
cd "$(dirname "$0")/../../.."
REPO="$PWD"
FAILED=0
ok()   { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }

REAL_HOME="${HOME:-/nonexistent}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stubs="$tmp/stubs"; mkdir -p "$stubs" "$tmp/tmp"
cat > "$stubs/launchctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/launchctl.log"
exit 0
STUB
cat > "$stubs/paseo" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/paseo.log"
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$stubs/claude"
printf '#!/bin/sh\nexit 1\n' > "$stubs/pkill"
chmod +x "$stubs"/*

# What install.sh would write in the real HOME. The seats' Claude runtimes (claude-*/) hold live
# session transcripts (and codex-peer/ a live Codex state), so only the room's own files are compared.
snap_real() {
  {
    find "$REAL_HOME/.config/slp-room" -maxdepth 1 -type f -ls
    find "$REAL_HOME/.config/slp-room/bin" "$REAL_HOME/.config/slp-room/room" \
      "$REAL_HOME/Library/LaunchAgents" "$REAL_HOME/Library/Logs/slp-gc" "$REAL_HOME/.claude/skills/supervisor" -type f -ls
    find "$REAL_HOME/.paseo" -maxdepth 1 -name 'config.json*' -type f -ls
  } 2>/dev/null | sort
}
REAL_BEFORE="$(snap_real)"

UID_N="$(id -u)"
LABEL=com.paseo-slp.slp-gc
# run <name> <args...>: install.sh in the sandbox; output to $tmp/<name>.out, status in RC.
run() {
  local name="$1"; shift
  RC=0
  env -u SLP_CLAUDE_OAUTH_TOKEN -u SLP_CLAUDE_BASE_URL -u SLP_CLAUDE_AUTH_TOKEN -u SLP_CLAUDE_API_KEY \
    -u SLP_CLAUDE_AUTH_HEADER -u SLP_ROOM_HOME -u SLP_GC_STATE_DIR -u SLP_GC_CONFIG -u CODEX_HOME \
    HOME="$tmp/home" TMPDIR="$tmp/tmp" PATH="$stubs:$PATH" SLP_LAUNCHCTL="$stubs/launchctl" \
    bash "$REPO/install.sh" "$@" > "$tmp/$name.out" 2>&1 < /dev/null || RC=$?
}
H="$tmp/home"
CONF="$H/.config/slp-room/slp-gc.conf"
PLIST="$H/Library/LaunchAgents/$LABEL.plist"
BIN="$H/.config/slp-room/bin/slp-gc"
conf_val() { awk -F= -v k="$1" '$1 == k { v = substr($0, length(k) + 2) } END { print v }' "$CONF"; }
flags() { printf '%s%s%s' "$(conf_val SLP_GC_APPLY)" "$(conf_val SLP_GC_KILL_STALE)" "$(conf_val SLP_GC_KILL_MEMORY)"; }
files() { (cd "$H" && find . -type f | sort | tr '\n' ' '); }

# --- static -----------------------------------------------------------------------------------
check "install.sh and the plist template are well-formed" bash -n install.sh
check "install.sh never calls launchctl directly" bash -c '! grep -nE "^[[:space:]]*(command )?launchctl[[:space:]]" install.sh'
check "the plist template has no --apply" bash -c '! grep -q -- "--apply" paseo/launchd/slp-gc.plist.in'

# --- 1. --gc-only -------------------------------------------------------------------------------
mkdir -p "$H"
run gc-only-1 --gc-only
[ -n "${EVIDENCE_DIR:-}" ] && { mkdir -p "$EVIDENCE_DIR"; (cd "$H" && find . | sort) > "$EVIDENCE_DIR/home-before-install.txt"; }
check "--gc-only exits 0" test "$RC" = 0
check "slp-gc installed executable next to slp-wait's dir" test -x "$BIN"
check "installed slp-gc is a copy of paseo/bin/slp-gc" cmp -s "$BIN" paseo/bin/slp-gc
check "slp-gc mode is 0755" test "$(stat -c %a "$BIN" 2>/dev/null || stat -f %Lp "$BIN")" = 755
check "the installed slp-gc runs (--help)" bash -c 'bash "$0" --help >/dev/null' "$BIN"
check "the plist is in place" test -f "$PLIST"
check "the plist has no --apply, ever" bash -c '! grep -q -- "--apply" "$0"' "$PLIST"
check "the plist runs /bin/bash <slp-gc> tick" bash -c 'grep -A3 "<key>ProgramArguments" "$0" | grep -q "/bin/bash" && grep -q "<string>'"$BIN"'</string>" "$0" && grep -q "<string>tick</string>" "$0"' "$PLIST"
check "the plist has StartInterval 60, RunAtLoad, Nice 10, Background, LowPriorityIO" bash -c \
  'tr -d " \n\t" < "$0" | grep -q "<key>StartInterval</key><integer>60</integer>" && tr -d " \n\t" < "$0" | grep -q "<key>RunAtLoad</key><true/>" && tr -d " \n\t" < "$0" | grep -q "<key>Nice</key><integer>10</integer>" && tr -d " \n\t" < "$0" | grep -q "<key>ProcessType</key><string>Background</string>" && tr -d " \n\t" < "$0" | grep -q "<key>LowPriorityIO</key><true/>"' "$PLIST"
check "the plist sets PATH (with homebrew), HOME and SLP_GC_CONFIG only" bash -c \
  'grep -q "/opt/homebrew/bin:/usr/local/bin" "$0" && grep -q "<string>'"$H"'</string>" "$0" && grep -q "<string>'"$CONF"'</string>" "$0" && [ "$(grep -c "SLP_GC_" "$0")" = 1 ]' "$PLIST"
check "the plist logs under the state dir" grep -q "<string>$H/Library/Logs/slp-gc/launchd.log</string>" "$PLIST"
check "no unrendered @@ placeholder remains" bash -c '! grep -q "@@" "$0"' "$PLIST"
if command -v plutil >/dev/null 2>&1; then
  check "plutil -lint accepts the plist" plutil -lint "$PLIST"
else
  ok "plutil not available, skipping plist lint"
fi
check "default config exists and is report-only" test "$(flags)" = 000
check "default config is private (0600)" test "$(stat -c %a "$CONF" 2>/dev/null || stat -f %Lp "$CONF")" = 600
check "--gc-only touches only slp-gc, its config, plist and state dir" \
  test "$(files)" = "./.config/slp-room/bin/slp-gc ./.config/slp-room/slp-gc.conf ./Library/LaunchAgents/$LABEL.plist "
check "--gc-only made no Paseo config, seats or skill" test ! -e "$H/.paseo" -a ! -e "$H/.claude" -a ! -e "$H/.config/slp-room/claude-peer"
check "launchctl: bootout then bootstrap, only the stub" test "$(cat "$tmp/launchctl.log")" = "bootout gui/$UID_N/$LABEL
bootstrap gui/$UID_N $PLIST"
check "the summary says report-only and how to run slp-gc" bash -c 'grep -q "report-only" "$0" && grep -q "bin/slp-gc report" "$0"' "$tmp/gc-only-1.out"
[ -n "${EVIDENCE_DIR:-}" ] && { cp "$tmp/gc-only-1.out" "$EVIDENCE_DIR/install-transcript-gc-only.txt"; cp "$PLIST" "$EVIDENCE_DIR/slp-gc.plist"; cp "$CONF" "$EVIDENCE_DIR/slp-gc.conf.default"; (cd "$H" && find . | sort) > "$EVIDENCE_DIR/home-after-install.txt"; }

# --- 2. opt-ins persist and edit only their keys ---------------------------------------------------
printf 'SLP_GC_MEM_WARN_MB=2048\n' >> "$CONF"
run gc-apply --gc-only --gc-apply
check "--gc-apply sets only APPLY=1" test "$RC" = 0 -a "$(flags)" = 100
check "--gc-apply keeps the other lines" test "$(conf_val SLP_GC_MEM_WARN_MB)" = 2048
check "--gc-apply is announced in the summary" grep -q "opt-ins ON: apply" "$tmp/gc-apply.out"
run gc-rerun --gc-only
check "a re-run without flags keeps the opt-in" test "$RC" = 0 -a "$(flags)" = 100 -a "$(conf_val SLP_GC_MEM_WARN_MB)" = 2048
check "the re-run does not duplicate keys" test "$(grep -c '^SLP_GC_APPLY=' "$CONF")" = 1
run gc-kill-alone --gc-only --gc-kill
check "--gc-kill without --gc-apply errors" test "$RC" -ne 0
check "--gc-kill error names --gc-apply" grep -q -- "--gc-apply" "$tmp/gc-kill-alone.out"
check "the failed --gc-kill changed nothing" test "$(flags)" = 100
run gc-kill --gc-only --gc-apply --gc-kill
check "--gc-apply --gc-kill sets all three" test "$RC" = 0 -a "$(flags)" = 111
check "the summary lists the kill opt-ins" grep -q "kill stale processes, kill over-memory" "$tmp/gc-kill.out"
check "the plist still has no --apply with every opt-in on" bash -c '! grep -q -- "--apply" "$0"' "$PLIST"
run gc-both --gc-only --gc-report-only --gc-apply
check "--gc-report-only with --gc-apply is refused" test "$RC" -ne 0 -a "$(flags)" = 111
run gc-reset --gc-only --gc-report-only
check "--gc-report-only resets all three" test "$RC" = 0 -a "$(flags)" = 000
check "--gc-report-only keeps the other lines" test "$(conf_val SLP_GC_MEM_WARN_MB)" = 2048
run gc-skill --gc-only --skill-only
check "--gc-only + --skill-only is refused" test "$RC" -ne 0

# --- 3. --no-gc-launchd, --no-gc --------------------------------------------------------------------
: > "$tmp/launchctl.log"; rm -f "$PLIST"
run nolaunchd --gc-only --no-gc-launchd
check "--no-gc-launchd writes no plist and calls no launchctl" test "$RC" = 0 -a ! -e "$PLIST" -a ! -s "$tmp/launchctl.log"
run nogc --gc-only --no-gc
check "--gc-only --no-gc is refused" test "$RC" -ne 0

# --- 4. default install (whole room) in the sandbox -------------------------------------------------
: > "$tmp/launchctl.log"; : > "$tmp/paseo.log"
run default --no-reload
[ -n "${EVIDENCE_DIR:-}" ] && cp "$tmp/default.out" "$EVIDENCE_DIR/install-transcript-default.txt"
check "the default install exits 0" test "$RC" = 0
check "the default install puts slp-gc next to slp-wait" test -x "$H/.config/slp-room/bin/slp-gc" -a -x "$H/.config/slp-room/bin/slp-wait"
check "the default install writes the plist" test -f "$PLIST"
check "the default install keeps the existing config's report-only flags" test "$(flags)" = 000
check "the default install still writes the Paseo config" test -f "$H/.paseo/config.json"
check "the default install called only the stub launchctl, twice" test "$(wc -l < "$tmp/launchctl.log" | tr -d ' ')" = 2
check "--no-reload made no paseo call" test ! -s "$tmp/paseo.log"
run noskill --skill-only
check "--skill-only installs no slp-gc" test "$RC" = 0 && ! grep -q "Installed slp-gc" "$tmp/noskill.out"
run nogc-default --paseo-only --no-reload --no-gc
check "--no-gc skips every slp-gc step" test "$RC" = 0 && ! grep -q "slp-gc" "$tmp/nogc-default.out"
rm -f "$H/.config/slp-room/slp-gc.conf"
run fresh-default --paseo-only --no-reload
check "a missing config is re-created report-only" test "$RC" = 0 -a "$(flags)" = 000

# --- 4b. a sandbox HOME without SLP_LAUNCHCTL never reaches launchctl ------------------------------
cp "$tmp/launchctl.log" "$tmp/launchctl.stubbed.log"; : > "$tmp/launchctl.log"
RC=0
env -u SLP_LAUNCHCTL -u SLP_ROOM_HOME -u SLP_GC_STATE_DIR HOME="$tmp/home" PATH="$stubs:$PATH" \
  bash "$REPO/install.sh" --gc-only > "$tmp/no-override.out" 2>&1 < /dev/null || RC=$?
check "without SLP_LAUNCHCTL a sandbox HOME skips launchd (nothing reaches launchctl, PATH stub included)" \
  test "$RC" = 0 -a ! -s "$tmp/launchctl.log"
check "...and says so" grep -q "not loaded into launchd" "$tmp/no-override.out"

# --- 5. nothing real was touched ----------------------------------------------------------------------
[ -n "${EVIDENCE_DIR:-}" ] && { cp "$tmp/launchctl.stubbed.log" "$EVIDENCE_DIR/stub-launchctl.log"; (cd "$H" && find . | sort) > "$EVIDENCE_DIR/home-after-default-install.txt"; }
check "launchctl was only ever the stub (it logged, and PATH's real one was never used)" test -s "$tmp/launchctl.stubbed.log"
check "the stub log holds only bootout/bootstrap of the agent" bash -c '! grep -vE "^(bootout gui/[0-9]+/'$LABEL'|bootstrap gui/[0-9]+ .*/'$LABEL'.plist)$" "$0"' "$tmp/launchctl.stubbed.log"
REAL_AFTER="$(snap_real)"
[ "$REAL_AFTER" = "$REAL_BEFORE" ] || diff <(printf '%s\n' "$REAL_BEFORE") <(printf '%s\n' "$REAL_AFTER") | head -10
check "the real HOME's slp-room, LaunchAgents, slp-gc logs and Paseo config are unchanged" test "$REAL_AFTER" = "$REAL_BEFORE"

if [ "$FAILED" -ne 0 ]; then echo "slp-gc-install tests: FAILED"; exit 1; fi
echo "slp-gc-install tests: all checks passed"
