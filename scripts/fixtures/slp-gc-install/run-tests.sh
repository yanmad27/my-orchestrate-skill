#!/usr/bin/env bash
# Sandbox tests for install.sh's slp-gc install: plist, config opt-ins, --gc-only, activation.
# Every run uses HOME=$tmp/home, a stub launchctl (SLP_LAUNCHCTL=<absolute stub>, also first on
# PATH) that logs argv, a stub dscl that reports the sandbox as the login home (so the installer's
# login-home guard lets the stub load), and stub paseo/claude/pkill. The real launchctl and real
# HOME are never used; the test checks that at the end. EVIDENCE_DIR=<dir> keeps the transcript, plist and listings.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1
REPO="$PWD"
FAILED=0
ok()   { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }
# checkp <description> <predicate>: the WHOLE predicate (compound && / || included) is evaluated here.
checkp() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

REAL_HOME="${HOME:-/nonexistent}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stubs="$tmp/stubs"; mkdir -p "$stubs" "$tmp/tmp"
cat > "$stubs/launchctl" <<STUB
#!/bin/sh
# Logging, stateful stub: state file = "loaded"; mode file picks a failure (see the mode tests).
printf '%s\\n' "\$*" >> "$tmp/launchctl.log"
mode="\$(cat "$tmp/lc.mode" 2>/dev/null)"; st="$tmp/lc.state"
case "\$1" in
  bootout)
    [ "\$mode" = bootout-fail ] && { echo "Boot-out failed: 1: Operation not permitted" >&2; exit 1; }
    [ "\$mode" = bootstrap-fail-loaded ] && { echo "Boot-out failed: 3: No such process" >&2; exit 3; }
    if [ -f "\$st" ]; then rm -f "\$st"; exit 0; fi
    echo "Boot-out failed: 3: No such process" >&2; exit 3 ;;
  bootstrap)
    case "\$mode" in bootstrap-fail|bootstrap-fail-loaded) echo "Bootstrap failed: 5: Input/output error" >&2; exit 5 ;; esac
    [ -f "\$st" ] && { echo "Bootstrap failed: 5: already loaded" >&2; exit 5; }
    [ "\$mode" = ghost ] && exit 0
    : > "\$st"; exit 0 ;;
  print)
    [ -f "\$st" ] && exit 0
    echo "Could not find service" >&2; exit 113 ;;
esac
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
# ~/Library/Logs/slp-gc is also written by the live launchd agent and by real deliveries, so it is not compared
# byte for byte. AGENT_STATE_NAMES lists every name slp-gc itself creates there (a static check below fails when
# slp-gc writes a $STATE/<name> that is not listed). snap_logs compares the set of any OTHER top-level entry
# exactly; real_logs_clean proves that no file under it holds this run's fixtures: the sandbox path ($tmp) or the
# fixture agent ids (aaaaaaaa-0000-4000-8000-* / bbbbbbbb-0000-4000-8000-*, never a real random uuid).
AGENT_STATE_NAMES=(.alert-stamp .last-report '.lineage.*' actions.log alerts.log 'deliveries.*' 'delivery.lock*'
                   launchd.log lineage.tsv memory.jsonl reports tick.lock tick.log)
# shellcheck disable=SC2254  # the AGENT_STATE_NAMES entries are intentional glob patterns
agent_state_name() { local n; for n in "${AGENT_STATE_NAMES[@]}"; do case "$1" in $n) return 0 ;; esac; done; return 1; }
snap_real() {
  {
    find "$REAL_HOME/.config/slp-room" -maxdepth 1 -type f -ls
    find "$REAL_HOME/.config/slp-room/bin" "$REAL_HOME/.config/slp-room/room" \
      "$REAL_HOME/Library/LaunchAgents" "$REAL_HOME/.claude/skills/supervisor" -type f -ls
    find "$REAL_HOME/.paseo" -maxdepth 1 -name 'config.json*' -type f -ls
    snap_logs
  } 2>/dev/null | sort
}
snap_logs() {
  local d="$REAL_HOME/Library/Logs/slp-gc" e
  [ -d "$d" ] || return 0
  find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | while IFS= read -r e; do
    agent_state_name "${e##*/}" || printf 'logs-extra: %s\n' "${e##*/}"
  done
}
FIXTURE_ID_RE='(aaaaaaaa|bbbbbbbb)-0000-4000-8000-[0-9a-f]{12}'
real_logs_clean() {
  local d="$REAL_HOME/Library/Logs/slp-gc" t
  [ -d "$d" ] || return 0
  for t in "$tmp" "$(cd -P "$tmp" 2>/dev/null && pwd -P)"; do
    [ -n "$t" ] || continue
    ! grep -rqF -- "$t" "$d" 2>/dev/null || { echo "a file in $d mentions the sandbox $t" >&2; return 1; }
  done
  ! grep -rqE -- "$FIXTURE_ID_RE" "$d" 2>/dev/null || { echo "a file in $d holds a fixture agent id" >&2; return 1; }
}
slpgc_state_names_listed() {   # only reads the script's text (the path is split so check-sandboxed.pl does not take this for an execution)
  local n bad=0
  while IFS= read -r n; do
    agent_state_name "${n//XXXXXX/x}" || { echo "slp-gc writes \$STATE/$n but AGENT_STATE_NAMES does not list it" >&2; bad=1; }
  done < <(grep -o '\$STATE/[A-Za-z0-9._*-]*' "$REPO/paseo/bin/"slp-gc | sed 's|^\$STATE/||' | sort -u)
  return "$bad"
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
igc_help_ok() { igc --help >/dev/null; }
# every direct slp-gc call: test mode (inert notifier/CLI/kill), sandbox HOME, PASEO_HOME and state dir
igc() { env -i PATH=/usr/bin:/bin SLP_GC_TEST=1 HOME="$H" PASEO_HOME="$H/.paseo" SLP_GC_STATE_DIR="$H/Library/Logs/slp-gc" SLP_GC_CONFIG="$CONF" bash "$BIN" "$@"; }   # slpgc-sandboxed
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
check "the installed slp-gc runs (--help)" igc_help_ok
check "the plist is in place" test -f "$PLIST"
check "the plist has no --apply, ever" bash -c '! grep -q -- "--apply" "$0"' "$PLIST"
check "the plist runs /bin/bash <slp-gc> tick" bash -c 'grep -A3 "<key>ProgramArguments" "$0" | grep -q "/bin/bash" && grep -q "<string>'"$BIN"'</string>" "$0" && grep -q "<string>tick</string>" "$0"' "$PLIST"
check "the plist has StartInterval 60, RunAtLoad, Nice 10, Background, LowPriorityIO" bash -c \
  'tr -d " \n\t" < "$0" | grep -q "<key>StartInterval</key><integer>60</integer>" && tr -d " \n\t" < "$0" | grep -q "<key>RunAtLoad</key><true/>" && tr -d " \n\t" < "$0" | grep -q "<key>Nice</key><integer>10</integer>" && tr -d " \n\t" < "$0" | grep -q "<key>ProcessType</key><string>Background</string>" && tr -d " \n\t" < "$0" | grep -q "<key>LowPriorityIO</key><true/>"' "$PLIST"
# shellcheck disable=SC2034  # used inside the checkp predicate strings below
STUBS_REAL="$(cd -P "$stubs" && pwd -P)"
check "the plist PATH lists the system dirs first, then homebrew (extras only after them)" grep -qE "<string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin(:[^<]*)?</string>" "$PLIST"
check "the plist sets PATH, HOME and SLP_GC_CONFIG only" bash -c \
  'grep -q "/opt/homebrew/bin:/usr/local/bin" "$0" && grep -q "<string>'"$H"'</string>" "$0" && grep -q "<string>'"$CONF"'</string>" "$0" && [ "$(grep -c "SLP_GC_" "$0")" = 1 ]' "$PLIST"
check "the plist logs under the state dir" grep -q "<string>$H/Library/Logs/slp-gc/launchd.log</string>" "$PLIST"
check "no unrendered @@ placeholder remains" bash -c '! grep -q "@@" "$0"' "$PLIST"
if command -v plutil >/dev/null 2>&1; then
  check "plutil -lint accepts the plist" plutil -lint "$PLIST"
else
  ok "plutil not available, skipping plist lint"
fi
check "a fresh default config is the safe tier: APPLY=1 KILL_STALE=1 KILL_MEMORY=0" test "$(flags)" = 110
check "the default config header no longer claims report-only by default" bash -c '! grep -qi "Default: report-only" "$0"' "$CONF"
check "default config is private (0600)" test "$(stat -c %a "$CONF" 2>/dev/null || stat -f %Lp "$CONF")" = 600
check "the state dir is private (0700)" test "$(stat -c %a "$H/Library/Logs/slp-gc" 2>/dev/null || stat -f %Lp "$H/Library/Logs/slp-gc")" = 700
check "no temp file is left behind by the atomic installs" test -z "$(find "$H/.config/slp-room/bin" "$H/Library/LaunchAgents" -name '.*' -type f)"
check "--gc-only touches only slp-gc, its config, plist and state dir" \
  test "$(files)" = "./.config/slp-room/bin/slp-gc ./.config/slp-room/slp-gc.conf ./Library/LaunchAgents/$LABEL.plist ./Library/Logs/slp-gc/launchd.log "
check "--gc-only made no Paseo config, seats or skill" test ! -e "$H/.paseo" -a ! -e "$H/.claude" -a ! -e "$H/.config/slp-room/claude-peer"
check "launchctl: bootout, bootstrap, then print to verify; only the stub" test "$(cat "$tmp/launchctl.log")" = "bootout gui/$UID_N/$LABEL
bootstrap gui/$UID_N $PLIST
print gui/$UID_N/$LABEL"
check "the summary names apply + kill-stale (not kill-memory), launchd loaded, and how to run slp-gc" bash -c 'grep -q "^!!   - apply" "$0" && grep -q "^!!   - kill-stale" "$0" && ! grep -q "^!!   - kill-memory" "$0" && grep -q "launchd agent: loaded" "$0" && grep -q "bin/slp-gc report" "$0" && ! grep -q "your existing config is report-only" "$0"' "$tmp/gc-only-1.out"
[ -n "${EVIDENCE_DIR:-}" ] && { cp "$tmp/gc-only-1.out" "$EVIDENCE_DIR/install-transcript-gc-only.txt"; cp "$PLIST" "$EVIDENCE_DIR/slp-gc.plist"; cp "$CONF" "$EVIDENCE_DIR/slp-gc.conf.default"; (cd "$H" && find . | sort) > "$EVIDENCE_DIR/home-after-install.txt"; }

# --- 2. opt-ins persist and edit only their keys ---------------------------------------------------
run gc-optout --gc-only --gc-report-only
check "--gc-report-only on the safe-tier default clears all three" test "$RC" = 0 -a "$(flags)" = 000
cp "$CONF" "$tmp/conf.zero"
run gc-zero-rerun --gc-only
check "a re-run with no --gc flag over an all-zero config leaves it byte-for-byte unchanged" cmp -s "$CONF" "$tmp/conf.zero"
check "that re-run prints the one-line report-only notice with the opt-in command" bash -c 'grep -c "your existing config is report-only" "$0" | grep -qx 1 && grep -q "install.sh --gc-apply --gc-kill-stale" "$0"' "$tmp/gc-zero-rerun.out"
run gc-zero-flag --gc-only --gc-report-only
check "an explicit --gc flag prints no notice" bash -c '! grep -q "your existing config is report-only" "$0"' "$tmp/gc-zero-flag.out"
printf 'SLP_GC_MEM_WARN_MB=2048\n' >> "$CONF"
run gc-apply --gc-only --gc-apply
check "--gc-apply sets only APPLY=1" test "$RC" = 0 -a "$(flags)" = 100
check "--gc-apply keeps the other lines" test "$(conf_val SLP_GC_MEM_WARN_MB)" = 2048
check "--gc-apply is announced in a prominent line naming the opt-in" bash -c 'grep -q "^!! slp-gc is RUNNING WITH OPT-INS" "$0" && grep -q "^!!   - apply" "$0"' "$tmp/gc-apply.out"
cp "$CONF" "$tmp/conf.on"
run gc-rerun --gc-only
check "a re-run over a config with apply on is unchanged and prints no notice" bash -c 'cmp -s "$0" "$1" && ! grep -q "your existing config is report-only" "$2"' "$CONF" "$tmp/conf.on" "$tmp/gc-rerun.out"
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
checkp "a symlinked config is refused with a message and not edited" 'test "$RC" -ne 0 -a "$(grep -c '\''^SLP_GC_APPLY=0'\'' "$tmp/conf.real")" = 1 && grep -q "symlink" "$tmp/gc-symlink.out"'
rm -f "$CONF"; mv "$tmp/conf.real" "$CONF"
run gc-skill --gc-only --skill-only
check "--gc-only + --skill-only is refused" test "$RC" -ne 0

# --- 3. --no-gc-launchd, --no-gc --------------------------------------------------------------------
: > "$tmp/launchctl.log"; rm -f "$PLIST"
run nolaunchd --gc-only --no-gc-launchd
checkp "--no-gc-launchd writes no plist and never boots out or bootstraps" 'test "$RC" = 0 -a ! -e "$PLIST" && ! grep -qE "^(bootout|bootstrap)" "$tmp/launchctl.log"'
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
check "the default install over a report-only config prints the notice" grep -q "your existing config is report-only" "$tmp/default.out"
check "the default install still writes the Paseo config" test -f "$H/.paseo/config.json"
check "the default install called only the stub launchctl, three times" test "$(wc -l < "$tmp/launchctl.log" | tr -d ' ')" = 3
check "--no-reload made no paseo call" test ! -s "$tmp/paseo.log"
run noskill --skill-only
checkp "--skill-only installs no slp-gc" 'test "$RC" = 0 && ! grep -q "Installed slp-gc" "$tmp/noskill.out"'
run nogc-default --paseo-only --no-reload --no-gc
checkp "--no-gc skips every slp-gc install step, and says the existing agent remains active" 'test "$RC" = 0 && ! grep -q "Installed slp-gc" "$tmp/nogc-default.out" && grep -q "existing agent remains active: $LABEL" "$tmp/nogc-default.out" && grep -q "to remove: launchctl bootout" "$tmp/nogc-default.out"'
rm -f "$H/.config/slp-room/slp-gc.conf"
run fresh-default --paseo-only --no-reload
check "a missing config is re-created as the safe tier" test "$RC" = 0 -a "$(flags)" = 110

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
checkp "without SLP_LAUNCHCTL the PATH dscl/id stubs are ignored and launchd is skipped (nothing logged)" 'test "$RC" = 0 -a ! -s "$tmp/launchctl.log" && grep -q "launchd agent NOT loaded" "$tmp/unresolved-nostub.out" && ! grep -q "other-home" "$tmp/unresolved-nostub.out"'
guard unresolved-stub "$tmp/dscl-none" "$stubs/launchctl" --gc-only
check "an unresolvable login home with SLP_LAUNCHCTL set may load through it" test "$RC" = 0 -a "$(wc -l < "$tmp/launchctl.log" | tr -d ' ')" = 3
guard relative - launchctl --gc-only
checkp "a relative SLP_LAUNCHCTL is refused (nothing runs, PATH's launchctl included)" 'test "$RC" = 0 -a ! -s "$tmp/launchctl.log" && grep -q "not an absolute path" "$tmp/relative.out"'
guard nonexec - "$tmp/no-such-launchctl" --gc-only
checkp "a missing SLP_LAUNCHCTL path is refused" 'test "$RC" = 0 -a ! -s "$tmp/launchctl.log" && grep -q "not an existing executable" "$tmp/nonexec.out"'
guard no-launchd - "$stubs/launchctl" --gc-only --no-gc-launchd
check "--no-gc-launchd says the agent was not installed" grep -q "launchd agent not installed" "$tmp/no-launchd.out"

# --- 4c. state dir mode, early symlink refusal ------------------------------------------------------
mkdir -p "$tmp/sd-home/.config/slp-room" "$tmp/sd-home/Library/Logs/slp-gc"; chmod 755 "$tmp/sd-home/Library/Logs/slp-gc"
RC=0; HOME="$tmp/sd-home" PATH="$stubs:$PATH" SLP_LAUNCHCTL="$stubs/launchctl" bash "$REPO/install.sh" --gc-only --no-gc-launchd > "$tmp/sd.out" 2>&1 < /dev/null || RC=$?
checkp "an existing state dir keeps its mode (0755) and the install warns" 'test "$RC" = 0 -a "$(stat -c %a "$tmp/sd-home/Library/Logs/slp-gc" 2>/dev/null || stat -f %Lp "$tmp/sd-home/Library/Logs/slp-gc")" = 755 && grep -q "is mode 755, not 0700" "$tmp/sd.out"'
mkdir -p "$tmp/sl-home/.config/slp-room"; : > "$tmp/sl-target"; ln -s "$tmp/sl-target" "$tmp/sl-home/.config/slp-room/slp-gc.conf"
RC=0; HOME="$tmp/sl-home" PATH="$stubs:$PATH" SLP_LAUNCHCTL="$stubs/launchctl" bash "$REPO/install.sh" > "$tmp/sl.out" 2>&1 < /dev/null || RC=$?
checkp "a symlinked config is refused before any install step: no partial install (default mode too)" 'test "$RC" -ne 0 -a "$(cd "$tmp/sl-home" && find . -mindepth 1 | sort | tr '\''\n'\'' '\'' '\'')" = "./.config ./.config/slp-room ./.config/slp-room/slp-gc.conf " && grep -q symlink "$tmp/sl.out"'

# --- 4d. hard/soft link and special-file safety (state dir, launchd.log, config) -------------------
# hrun <name> <home> <args...>: install with the stub launchctl into an explicit sandbox HOME.
hrun() {
  local name="$1" home="$2"; shift 2; RC=0
  HOME="$home" TMPDIR="$tmp/tmp" PATH="$stubs:$PATH" SLP_LAUNCHCTL="$stubs/launchctl" \
    bash "$REPO/install.sh" "$@" > "$tmp/$name.out" 2>&1 < /dev/null || RC=$?
}
tree() { (cd "$1" && find . -mindepth 1 | sort | tr '\n' ' '); }
# a symlinked state dir: refused up front, nothing written anywhere, the target untouched
mkdir -p "$tmp/ls-home/Library/Logs" "$tmp/ls-outside" "$tmp/ls-home/.config/slp-room"
ln -s "$tmp/ls-outside" "$tmp/ls-home/Library/Logs/slp-gc"
hrun ls-state "$tmp/ls-home"
checkp "a symlinked state dir is refused before any install step (nothing written, target empty)" 'test "$RC" -ne 0 -a -z "$(ls -A "$tmp/ls-outside")" -a ! -e "$tmp/ls-home/.config/slp-room/bin" -a ! -e "$tmp/ls-home/Library/LaunchAgents" && grep -q "state dir .* is a symlink" "$tmp/ls-state.out"'
# launchd.log: a symlink is refused, a hard link (over 1 MiB) to an outside file is unlinked, never written through
mkdir -p "$tmp/ll-home/Library/Logs/slp-gc" "$tmp/ll-home/.config/slp-room"
printf 'precious\n' > "$tmp/ll-outside"
ln -s "$tmp/ll-outside" "$tmp/ll-home/Library/Logs/slp-gc/launchd.log"
hrun ll-sym "$tmp/ll-home" --gc-only
checkp "a symlinked launchd.log is refused before any install step; the target is unchanged" 'test "$RC" -ne 0 -a "$(cat "$tmp/ll-outside")" = precious -a ! -e "$tmp/ll-home/.config/slp-room/bin" && grep -q "launchd.log is a symlink" "$tmp/ll-sym.out"'
rm -f "$tmp/ll-home/Library/Logs/slp-gc/launchd.log"
head -c 1200000 /dev/zero > "$tmp/ll-outside"; cp "$tmp/ll-outside" "$tmp/ll-outside.orig"
ln "$tmp/ll-outside" "$tmp/ll-home/Library/Logs/slp-gc/launchd.log"
hrun ll-hard "$tmp/ll-home" --gc-only
LL="$tmp/ll-home/Library/Logs/slp-gc/launchd.log"
checkp "a hard-linked >1 MiB launchd.log: the outside file is unchanged (size and bytes)" 'test "$RC" = 0 && cmp -s "$tmp/ll-outside" "$tmp/ll-outside.orig"'
check "...and launchd.log is now a fresh, private, single-link regular file" test -f "$LL" -a ! -L "$LL" -a ! -s "$LL" -a "$(stat -c %a "$LL" 2>/dev/null || stat -f %Lp "$LL")" = 600 -a "$(stat -c %h "$LL" 2>/dev/null || stat -f %l "$LL")" = 1
head -c 1200000 /dev/zero > "$LL"
hrun ll-big "$tmp/ll-home" --gc-only
checkp "an oversized regular launchd.log is renamed aside (launchd.log.1) and a fresh one created" 'test "$RC" = 0 -a -s "$LL.1" -a ! -s "$LL" && test "$(wc -c < "$LL.1" | tr -d '\'' '\'')" = 1200000'
# config that is not a regular file: FIFO, directory
for kind in fifo dir; do
  h="$tmp/cf-$kind"; mkdir -p "$h/.config/slp-room"
  if [ "$kind" = fifo ]; then mkfifo "$h/.config/slp-room/slp-gc.conf"; else mkdir "$h/.config/slp-room/slp-gc.conf"; fi
  hrun "cf-$kind" "$h" --gc-only
  check "a $kind config is refused before any install step (no bin, no plist, no state dir)" test "$RC" -ne 0 -a ! -e "$h/.config/slp-room/bin" -a ! -e "$h/Library" && grep -q "not a regular file" "$tmp/cf-$kind.out"
done

# --- 4e. jq/paseo under the plist PATH ----------------------------------------------------------------
mkdir -p "$tmp/jqdir" "$tmp/emptybin" "$tmp/jq-home"
ln -s "$(command -v jq)" "$tmp/jqdir/jq"
RC=0; HOME="$tmp/jq-home" TMPDIR="$tmp/tmp" PATH="$tmp/jqdir:$stubs:/bin:/usr/bin" SLP_LAUNCHCTL="$stubs/launchctl" SLP_GC_PLIST_BASE_PATH="$tmp/emptybin" \
  bash "$REPO/install.sh" --gc-only > "$tmp/jq-odd.out" 2>&1 < /dev/null || RC=$?
JQ_REAL="$(cd -P "$tmp/jqdir" && pwd -P)"
checkp "jq outside the launchd PATH: its canonical dir is appended after the system dirs, in the plist" 'test "$RC" = 0 && grep -q "<string>$tmp/emptybin:$JQ_REAL:$STUBS_REAL</string>" "$tmp/jq-home/Library/LaunchAgents/$LABEL.plist"'
check "...and the summary says so" grep -q "launchd PATH extended after the system dirs with: $JQ_REAL (jq)" "$tmp/jq-odd.out"
# jq nowhere: build a PATH of symlinks to the system tools install.sh uses, minus jq
mkdir -p "$tmp/nojq-bin" "$tmp/nojq-home"
for t in bash sh env awk sed mktemp cp chmod mv rm mkdir cat tr cut head stat find dirname basename date id wc sort uname grep ls tail cmp ln; do
  tp="$(command -v "$t" 2>/dev/null || true)"; case "$tp" in /*) ln -sf "$tp" "$tmp/nojq-bin/$t" ;; esac
done
RC=0; HOME="$tmp/nojq-home" TMPDIR="$tmp/tmp" PATH="$tmp/nojq-bin" SLP_LAUNCHCTL="$stubs/launchctl" SLP_GC_PLIST_BASE_PATH="$tmp/emptybin" \
  "$tmp/nojq-bin/bash" "$REPO/install.sh" --gc-only > "$tmp/nojq.out" 2>&1 < /dev/null || RC=$?
checkp "jq nowhere: the install is refused with an actionable error before any install step" 'test "$RC" -ne 0 -a ! -e "$tmp/nojq-home/.config" && grep -q "jq is required by slp-gc but was not found" "$tmp/nojq.out"'

# --- 4f. what launchctl really did: already loaded, bootout/bootstrap failures -------------------------
LCH="$tmp/lc-home"; mkdir -p "$LCH"
rm -f "$tmp/lc.state" "$tmp/lc.mode"
: > "$tmp/launchctl.log"
hrun lc-first "$LCH" --gc-only
checkp "first load: loaded, verified with launchctl print" 'test "$RC" = 0 && grep -q "launchd agent: loaded .*verified with launchctl print" "$tmp/lc-first.out"'
: > "$tmp/launchctl.log"
hrun lc-again "$LCH" --gc-only
checkp "already loaded: bootout succeeds, then bootstrap, then print; loaded" 'test "$RC" = 0 -a "$(cut -d'\'' '\'' -f1 "$tmp/launchctl.log" | tr '\''\n'\'' '\'' '\'')" = "bootout bootstrap print " && grep -q "launchd agent: loaded" "$tmp/lc-again.out"'
check "the not-found bootout of a first load is not reported as a failure" bash -c '! grep -q "bootout. failed" "$0"' "$tmp/lc-first.out"
echo bootout-fail > "$tmp/lc.mode"   # state is loaded from the runs above
: > "$tmp/launchctl.log"
hrun lc-bo "$LCH" --gc-only
checkp "bootout failure while loaded: PRIOR definition reported, no bootstrap, summary says so" 'test "$RC" = 0 && ! grep -q "^bootstrap" "$tmp/launchctl.log" && grep -q "still loaded with the PRIOR definition (bootout failed" "$tmp/lc-bo.out" && grep -q "WARNING: '\''launchctl bootout'\'' failed" "$tmp/lc-bo.out"'
echo bootstrap-fail-loaded > "$tmp/lc.mode"
: > "$tmp/launchctl.log"
hrun lc-bs-loaded "$LCH" --gc-only
checkp "bootstrap failure while an older definition stays loaded: PRIOR definition reported" 'test "$RC" = 0 && grep -q "still loaded with the PRIOR definition (bootstrap failed" "$tmp/lc-bs-loaded.out"'
echo bootstrap-fail > "$tmp/lc.mode"; rm -f "$tmp/lc.state"
: > "$tmp/launchctl.log"
hrun lc-bs "$LCH" --gc-only
checkp "bootstrap failure with nothing loaded: 'launchd agent NOT loaded' and the manual command" 'test "$RC" = 0 && grep -q "launchd agent NOT loaded (launchctl bootstrap failed" "$tmp/lc-bs.out" && grep -q "WARNING: could not load the agent" "$tmp/lc-bs.out"'
echo ghost > "$tmp/lc.mode"; rm -f "$tmp/lc.state"
: > "$tmp/launchctl.log"
hrun lc-ghost "$LCH" --gc-only
checkp "bootstrap 'succeeds' but print cannot see the agent: not reported as loaded" 'test "$RC" = 0 && grep -q "launchd agent NOT loaded (bootstrap reported success but launchctl print cannot see" "$tmp/lc-ghost.out"'
rm -f "$tmp/lc.mode" "$tmp/lc.state"

# --- 4g. --no-gc-launchd / --no-gc after a normal install keep the agent and say so -------------------
: > "$tmp/launchctl.log"
hrun keep-1 "$LCH" --gc-only
: > "$tmp/launchctl.log"
hrun keep-2 "$LCH" --gc-only --no-gc-launchd
checkp "--no-gc-launchd after an install: no launchctl bootout (agent kept), and the summary says it remains active" 'test "$RC" = 0 && ! grep -q "^bootout" "$tmp/launchctl.log" && test -f "$LCH/Library/LaunchAgents/$LABEL.plist" && grep -q "existing agent remains active: $LABEL" "$tmp/keep-2.out" && grep -q "to remove: launchctl bootout gui/" "$tmp/keep-2.out"'
: > "$tmp/launchctl.log"
hrun keep-3 "$LCH" --paseo-only --no-reload --no-gc
checkp "--no-gc after an install keeps the agent and says so too" 'test "$RC" = 0 && test -f "$LCH/Library/LaunchAgents/$LABEL.plist" && grep -q "existing agent remains active: $LABEL" "$tmp/keep-3.out" && ! grep -q "^bootout" "$tmp/launchctl.log"'
rm -f "$tmp/lc.state"; mkdir -p "$tmp/fresh-home"
hrun keep-4 "$tmp/fresh-home" --gc-only --no-gc-launchd
checkp "with no earlier agent, --no-gc-launchd says nothing about one" 'test "$RC" = 0 && ! grep -q "remains active" "$tmp/keep-4.out"'

# --- 4g2. a plist left behind after a failed bootstrap is "installed (not loaded)", never "active" ---
rm -f "$tmp/lc.state"; echo bootstrap-fail > "$tmp/lc.mode"; mkdir -p "$tmp/left-home"
: > "$tmp/launchctl.log"
hrun left-1 "$tmp/left-home" --gc-only
: > "$tmp/launchctl.log"; rm -f "$tmp/lc.mode"
hrun left-2 "$tmp/left-home" --paseo-only --no-reload --no-gc
checkp "plist left by a failed bootstrap + --no-gc: 'definition remains installed (not loaded)', not 'active', no bootout" 'test "$RC" = 0 && test -f "$tmp/left-home/Library/LaunchAgents/$LABEL.plist" && grep -q "existing definition remains installed (not loaded)" "$tmp/left-2.out" && ! grep -q "remains active" "$tmp/left-2.out" && ! grep -q "^bootout" "$tmp/launchctl.log"'
RC=0; HOME="$tmp/left-home" TMPDIR="$tmp/tmp" PATH="$stubs:$PATH" SLP_LAUNCHCTL="$stubs/launchctl" bash "$REPO/install.sh" --skill-only --no-gc > "$tmp/left-3.out" 2>&1 < /dev/null || RC=$?
RC=0; env -u SLP_LAUNCHCTL HOME="$tmp/left-home" TMPDIR="$tmp/tmp" PATH="$stubs:$PATH" bash "$REPO/install.sh" --skill-only --no-gc > "$tmp/left-4.out" 2>&1 < /dev/null || RC=$?
checkp "the same with launchd not queryable (sandbox HOME, no override): 'loaded state unknown', not 'active'" 'test "$RC" = 0 && grep -q "whether it is loaded is unknown" "$tmp/left-4.out" && ! grep -q "remains active" "$tmp/left-4.out"'
rm -f "$tmp/lc.mode" "$tmp/lc.state"

# --- 4h. every documented key exists in the installed slp-gc ------------------------------------------
HELP="$(igc --help 2>&1)"
missing_help=""; missing_parser=""
for k in $( { grep -o 'SLP_GC_[A-Z_]*[A-Z]' "$CONF"; grep -o 'SLP_GC_[A-Z_]*[A-Z]' README.md; } | sort -u); do
  case "$k" in SLP_GC_TEST|SLP_GC_STATE_DIR|SLP_GC_CONFIG|SLP_GC_PLIST_BASE_PATH) continue ;; esac
  printf '%s' "$HELP" | grep -q "$k" || missing_help="$missing_help $k"
  grep -qE "(^|[ |])${k}[|)]" "$BIN" || missing_parser="$missing_parser $k"
done
checkp "every SLP_GC_* key the README or the generated config documents is in slp-gc's --help (missing:${missing_help:- none})" '[ -z "$missing_help" ]'
checkp "...and in slp-gc's config parser (missing:${missing_parser:- none})" '[ -z "$missing_parser" ]'
check "README defaults match --help: 3072 / 4096 / 50% of RAM" env HELP="$HELP" bash -c 'printf "%s" "$HELP" | grep -q "SLP_GC_MEM_WARN_MB\[3072\]" && printf "%s" "$HELP" | grep -q "SLP_GC_MEM_KILL_MB\[4096" && printf "%s" "$HELP" | grep -q "SLP_GC_TREE_WARN_MB\[50% of RAM\]" && grep -q "SLP_GC_MEM_WARN_MB. (3072)" README.md && grep -q "SLP_GC_MEM_KILL_MB. (4096)" README.md && grep -q "(50% of RAM)" README.md'
check "the README mentions lineage.tsv" grep -q "lineage.tsv" README.md
checkp "the generated config's defaults match --help (3072 / 4096)" 'grep -q "^# SLP_GC_MEM_WARN_MB=3072$" "$CONF" && grep -q "^# SLP_GC_MEM_KILL_MB=4096$" "$CONF"'

# --- 5. nothing real was touched ----------------------------------------------------------------------
[ -n "${EVIDENCE_DIR:-}" ] && { cp "$tmp/launchctl.stubbed.log" "$EVIDENCE_DIR/stub-launchctl.log"; (cd "$H" && find . | sort) > "$EVIDENCE_DIR/home-after-default-install.txt"; }
check "launchctl was only ever the stub (it logged, and PATH's real one was never used)" test -s "$tmp/launchctl.stubbed.log"
check "the stub log holds only bootout/bootstrap/print of the agent" bash -c '! grep -vE "^(bootout gui/[0-9]+/'$LABEL'|print gui/[0-9]+/'$LABEL'|bootstrap gui/[0-9]+ .*/'$LABEL'.plist)$" "$0"' "$tmp/launchctl.stubbed.log"
REAL_AFTER="$(snap_real)"
[ "$REAL_AFTER" = "$REAL_BEFORE" ] || diff <(printf '%s\n' "$REAL_BEFORE") <(printf '%s\n' "$REAL_AFTER") | head -10
check "the real HOME's slp-room, LaunchAgents, slp-gc logs and Paseo config are unchanged" test "$REAL_AFTER" = "$REAL_BEFORE"
check "no file in the real slp-gc logs holds this run's fixtures (sandbox path, fixture agent ids)" real_logs_clean
check "every \$STATE/<name> that slp-gc writes is in the agent-owned list the real-HOME check relies on" slpgc_state_names_listed

if [ "$FAILED" -ne 0 ]; then echo "slp-gc-install tests: FAILED"; exit 1; fi
echo "slp-gc-install tests: all checks passed"
