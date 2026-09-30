#!/usr/bin/env bash
# Sandbox tests for install.sh's slp-gc install: plist, config opt-ins, --gc-only, activation.
# Every run uses HOME=$tmp/home, a stub launchctl (SLP_LAUNCHCTL=<absolute stub>, also first on
# PATH) that logs argv, a stub dscl that reports the sandbox as the login home (so the installer's
# login-home guard lets the stub load), and stub paseo/claude/pkill. The real launchctl and real
# HOME are never used; the test checks that at the end. EVIDENCE_DIR=<dir> keeps the transcript, plist and listings.
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
printf '#!/bin/sh\nprintf "NFSHomeDirectory: %%s\\n" "$HOME"\n' > "$stubs/dscl"
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
check "the plist PATH lists the system dirs before homebrew" grep -q "<string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>" "$PLIST"
check "the plist sets PATH, HOME and SLP_GC_CONFIG only" bash -c \
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
check "the state dir is private (0700)" test "$(stat -c %a "$H/Library/Logs/slp-gc" 2>/dev/null || stat -f %Lp "$H/Library/Logs/slp-gc")" = 700
check "no temp file is left behind by the atomic installs" test -z "$(find "$H/.config/slp-room/bin" "$H/Library/LaunchAgents" -name '.*' -type f)"
check "--gc-only touches only slp-gc, its config, plist and state dir" \
  test "$(files)" = "./.config/slp-room/bin/slp-gc ./.config/slp-room/slp-gc.conf ./Library/LaunchAgents/$LABEL.plist "
check "--gc-only made no Paseo config, seats or skill" test ! -e "$H/.paseo" -a ! -e "$H/.claude" -a ! -e "$H/.config/slp-room/claude-peer"
check "launchctl: bootout then bootstrap, only the stub" test "$(cat "$tmp/launchctl.log")" = "bootout gui/$UID_N/$LABEL
bootstrap gui/$UID_N $PLIST"
check "the summary says report-only, launchd loaded, and how to run slp-gc" bash -c 'grep -q "report-only" "$0" && grep -q "launchd agent: loaded" "$0" && grep -q "bin/slp-gc report" "$0"' "$tmp/gc-only-1.out"
[ -n "${EVIDENCE_DIR:-}" ] && { cp "$tmp/gc-only-1.out" "$EVIDENCE_DIR/install-transcript-gc-only.txt"; cp "$PLIST" "$EVIDENCE_DIR/slp-gc.plist"; cp "$CONF" "$EVIDENCE_DIR/slp-gc.conf.default"; (cd "$H" && find . | sort) > "$EVIDENCE_DIR/home-after-install.txt"; }

# --- 2. opt-ins persist and edit only their keys ---------------------------------------------------
printf 'SLP_GC_MEM_WARN_MB=2048\n' >> "$CONF"
run gc-apply --gc-only --gc-apply
check "--gc-apply sets only APPLY=1" test "$RC" = 0 -a "$(flags)" = 100
check "--gc-apply keeps the other lines" test "$(conf_val SLP_GC_MEM_WARN_MB)" = 2048
check "--gc-apply is announced in a prominent line naming the opt-in" bash -c 'grep -q "^!! slp-gc is RUNNING WITH OPT-INS" "$0" && grep -q "^!!   - apply" "$0"' "$tmp/gc-apply.out"
run gc-rerun --gc-only
check "a re-run without flags keeps the opt-in" test "$RC" = 0 -a "$(flags)" = 100 -a "$(conf_val SLP_GC_MEM_WARN_MB)" = 2048
check "the re-run does not duplicate keys" test "$(grep -c '^SLP_GC_APPLY=' "$CONF")" = 1
for f in --gc-kill --gc-kill-stale --gc-kill-memory; do
  run "gc-alone$f" --gc-only "$f"
  check "$f without --gc-apply errors, naming --gc-apply, and changes nothing" test "$RC" -ne 0 -a "$(flags)" = 100 && grep -q -- "--gc-apply" "$tmp/gc-alone$f.out"
done
run gc-stale --gc-only --gc-apply --gc-kill-stale
check "--gc-kill-stale sets apply + stale only" test "$RC" = 0 -a "$(flags)" = 110
run gc-mem --gc-only --gc-report-only
run gc-mem --gc-only --gc-apply --gc-kill-memory
check "--gc-kill-memory sets apply + memory only" test "$RC" = 0 -a "$(flags)" = 101
run gc-kill --gc-only --gc-apply --gc-kill
check "--gc-apply --gc-kill sets all three" test "$RC" = 0 -a "$(flags)" = 111
check "the summary names every active opt-in" bash -c 'grep -q "^!!   - apply" "$0" && grep -q "^!!   - kill-stale" "$0" && grep -q "^!!   - kill-memory" "$0"' "$tmp/gc-kill.out"
check "the plist still has no --apply with every opt-in on" bash -c '! grep -q -- "--apply" "$0"' "$PLIST"
run gc-both --gc-only --gc-report-only --gc-apply
check "--gc-report-only with --gc-apply is refused" test "$RC" -ne 0 -a "$(flags)" = 111
run gc-reset --gc-only --gc-report-only
check "--gc-report-only resets all three" test "$RC" = 0 -a "$(flags)" = 000
check "--gc-report-only keeps the other lines" test "$(conf_val SLP_GC_MEM_WARN_MB)" = 2048
# the summary reads the config as slp-gc's read_config does: last value wins, \r and one pair of quotes stripped, only exactly 1
cp "$CONF" "$tmp/conf.keep"
printf 'SLP_GC_APPLY=1\nSLP_GC_APPLY=2\nSLP_GC_KILL_STALE="1"\r\nSLP_GC_KILL_MEMORY=1\nSLP_GC_KILL_MEMORY=01\n' >> "$CONF"
run gc-norm --gc-only --no-gc-launchd
check "the summary normalises the config like slp-gc (quotes and CR stripped, last wins, exactly 1)" bash -c '! grep -q "^!!   - apply" "$0" && grep -q "^!!   - kill-stale" "$0" && ! grep -q "^!!   - kill-memory" "$0"' "$tmp/gc-norm.out"
cp "$tmp/conf.keep" "$CONF"
# a symlinked config is refused
mv "$CONF" "$tmp/conf.real"; ln -s "$tmp/conf.real" "$CONF"
run gc-symlink --gc-only --gc-apply
check "a symlinked config is refused with a message and not edited" test "$RC" -ne 0 -a "$(grep -c '^SLP_GC_APPLY=0' "$tmp/conf.real")" = 1 && grep -q "symlink" "$tmp/gc-symlink.out"
rm -f "$CONF"; mv "$tmp/conf.real" "$CONF"
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

# --- 4b. the login-home guard: SLP_LAUNCHCTL stays set to the logging stub throughout -----------------
cp "$tmp/launchctl.log" "$tmp/launchctl.stubbed.log"
mkdir -p "$tmp/other-home" "$tmp/dscl-other" "$tmp/dscl-none"
cat > "$tmp/dscl-other/dscl" <<STUB
#!/bin/sh
printf 'NFSHomeDirectory: %s\\n' "$tmp/other-home"
STUB
printf '#!/bin/sh\nexit 1\n' > "$tmp/dscl-none/dscl"; cp "$tmp/dscl-none/dscl" "$tmp/dscl-none/getent"
chmod +x "$tmp/dscl-other/dscl" "$tmp/dscl-none"/*
# guard <name> <pathdir|-> <SLP_LAUNCHCTL value|-> args...: install with the given fakes
guard() {
  local name="$1" pdir="$2" lc="$3"; shift 3
  : > "$tmp/launchctl.log"; RC=0
  local -a e=(env -u SLP_ROOM_HOME -u SLP_GC_STATE_DIR -u SLP_LAUNCHCTL HOME="$tmp/home" TMPDIR="$tmp/tmp")
  [ "$lc" = - ] || e+=(SLP_LAUNCHCTL="$lc")
  if [ "$pdir" = - ]; then e+=(PATH="$stubs:$PATH"); else e+=(PATH="$pdir:$stubs:$PATH"); fi
  "${e[@]}" bash "$REPO/install.sh" "$@" > "$tmp/$name.out" 2>&1 < /dev/null || RC=$?
}
guard other-home "$tmp/dscl-other" "$stubs/launchctl" --gc-only
check "a login home that is not HOME: nothing reaches the logging stub or PATH's launchctl" test "$RC" = 0 -a ! -s "$tmp/launchctl.log"
check "...with a loud WARNING and 'launchd agent NOT loaded' in the summary" bash -c 'grep -q "^WARNING: the launchd agent was written but NOT loaded" "$0" && grep -q "launchd agent NOT loaded" "$0"' "$tmp/other-home.out"
guard unresolved-nostub "$tmp/dscl-other" - --gc-only
check "without SLP_LAUNCHCTL the PATH dscl/id stubs are ignored and launchd is skipped (nothing logged)" test "$RC" = 0 -a ! -s "$tmp/launchctl.log" && grep -q "launchd agent NOT loaded" "$tmp/unresolved-nostub.out" && ! grep -q "other-home" "$tmp/unresolved-nostub.out"
guard unresolved-stub "$tmp/dscl-none" "$stubs/launchctl" --gc-only
check "an unresolvable login home with SLP_LAUNCHCTL set may load through it" test "$RC" = 0 -a "$(wc -l < "$tmp/launchctl.log" | tr -d ' ')" = 2
guard relative - launchctl --gc-only
check "a relative SLP_LAUNCHCTL is refused (nothing runs, PATH's launchctl included)" test "$RC" = 0 -a ! -s "$tmp/launchctl.log" && grep -q "not an absolute path" "$tmp/relative.out"
guard nonexec - "$tmp/no-such-launchctl" --gc-only
check "a missing SLP_LAUNCHCTL path is refused" test "$RC" = 0 -a ! -s "$tmp/launchctl.log" && grep -q "not an existing executable" "$tmp/nonexec.out"
guard no-launchd - "$stubs/launchctl" --gc-only --no-gc-launchd
check "--no-gc-launchd says the agent was not installed" grep -q "launchd agent not installed" "$tmp/no-launchd.out"

# --- 4c. state dir mode, early symlink refusal ------------------------------------------------------
mkdir -p "$tmp/sd-home/.config/slp-room" "$tmp/sd-home/Library/Logs/slp-gc"; chmod 755 "$tmp/sd-home/Library/Logs/slp-gc"
RC=0; HOME="$tmp/sd-home" PATH="$stubs:$PATH" SLP_LAUNCHCTL="$stubs/launchctl" bash "$REPO/install.sh" --gc-only --no-gc-launchd > "$tmp/sd.out" 2>&1 < /dev/null || RC=$?
check "an existing state dir keeps its mode (0755) and the install warns" test "$RC" = 0 -a "$(stat -c %a "$tmp/sd-home/Library/Logs/slp-gc" 2>/dev/null || stat -f %Lp "$tmp/sd-home/Library/Logs/slp-gc")" = 755 && grep -q "not owned by you or not mode 0700" "$tmp/sd.out"
mkdir -p "$tmp/sl-home/.config/slp-room"; : > "$tmp/sl-target"; ln -s "$tmp/sl-target" "$tmp/sl-home/.config/slp-room/slp-gc.conf"
RC=0; HOME="$tmp/sl-home" PATH="$stubs:$PATH" SLP_LAUNCHCTL="$stubs/launchctl" bash "$REPO/install.sh" > "$tmp/sl.out" 2>&1 < /dev/null || RC=$?
check "a symlinked config is refused before any install step: no partial install (default mode too)" test "$RC" -ne 0 -a "$(cd "$tmp/sl-home" && find . -mindepth 1 | sort | tr '\n' ' ')" = "./.config ./.config/slp-room ./.config/slp-room/slp-gc.conf " && grep -q symlink "$tmp/sl.out"

# --- 5. nothing real was touched ----------------------------------------------------------------------
[ -n "${EVIDENCE_DIR:-}" ] && { cp "$tmp/launchctl.stubbed.log" "$EVIDENCE_DIR/stub-launchctl.log"; (cd "$H" && find . | sort) > "$EVIDENCE_DIR/home-after-default-install.txt"; }
check "launchctl was only ever the stub (it logged, and PATH's real one was never used)" test -s "$tmp/launchctl.stubbed.log"
check "the stub log holds only bootout/bootstrap of the agent" bash -c '! grep -vE "^(bootout gui/[0-9]+/'$LABEL'|bootstrap gui/[0-9]+ .*/'$LABEL'.plist)$" "$0"' "$tmp/launchctl.stubbed.log"
REAL_AFTER="$(snap_real)"
[ "$REAL_AFTER" = "$REAL_BEFORE" ] || diff <(printf '%s\n' "$REAL_BEFORE") <(printf '%s\n' "$REAL_AFTER") | head -10
check "the real HOME's slp-room, LaunchAgents, slp-gc logs and Paseo config are unchanged" test "$REAL_AFTER" = "$REAL_BEFORE"

if [ "$FAILED" -ne 0 ]; then echo "slp-gc-install tests: FAILED"; exit 1; fi
echo "slp-gc-install tests: all checks passed"
