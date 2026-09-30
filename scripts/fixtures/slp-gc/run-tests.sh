#!/usr/bin/env bash
# slp-gc sandbox tests. Prints "ok: ..." / "FAIL: ..." lines, exits 1 on any failure.
# Everything runs in temp sandboxes (temp PASEO_HOME + HOME, stub ps/top/lsof/paseo/kill/...):
# never against the real ~/.paseo or real processes. Needs bash, jq, perl, git, tar (no macOS tools).
# SLPGC_EVIDENCE=<dir> additionally saves the snapshots, diffs, logs and outputs there.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GC="${SLP_GC_BIN:-$HERE/../../../paseo/bin/slp-gc}"
FAILED=0
ok()   { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
EV="${SLPGC_EVIDENCE:-}"; [ -z "$EV" ] || mkdir -p "$EV"
keep() { [ -z "$EV" ] || cp "$1" "$EV/$2" 2>/dev/null; }

for tool in jq perl git tar; do command -v "$tool" >/dev/null 2>&1 || { echo "ok: slp-gc tests skipped ($tool missing)"; exit 0; }; done
# shellcheck source=sandbox.sh
. "$HERE/sandbox.sh"
# shellcheck disable=SC2034
FX_GC="$GC"
fresh() { rm -rf "$WORK/sb" "$WORK/sb.tmp"; mkdir -p "$WORK/sb"; make_sandbox "$WORK/sb" >/dev/null 2>&1; unset SLPGC_PASEO_HANG SLPGC_ADD_SELF FX_EXTRA_ENV; }
logn() { if [ -f "$FX_LOGS/$1" ]; then wc -l < "$FX_LOGS/$1" | tr -d ' '; else echo 0; fi; }
sorted() { [ -f "$1" ] && sort "$1" || true; }
agent_file() { find "$FX_PHOME/agents" -mindepth 2 -maxdepth 2 -name "$1.json" -print -quit 2>/dev/null; }
has_agent() { [ -n "$(agent_file "$1")" ]; }
exists_all() { local p; for p in "$@"; do [ -e "$p" ] || [ -L "$p" ] || { echo "  missing: $p"; return 1; }; done; }

# --- (i) report is read-only ---------------------------------------------------------------------
fresh
fx_snapshot "$WORK/sb" > "$WORK/snap.before"
fx_gc report > "$WORK/report.txt" 2>"$WORK/report.err"; rc1=$?
fx_gc report --json > "$WORK/report.json" 2>>"$WORK/report.err"; rc2=$?
fx_gc > "$WORK/report-default.txt" 2>>"$WORK/report.err"
SLPGC_ADD_SELF=1 fx_gc report >/dev/null 2>&1
fx_snapshot "$WORK/sb" > "$WORK/snap.after"
keep "$WORK/snap.before" i-snapshot-before.txt; keep "$WORK/snap.after" i-snapshot-after.txt; keep "$WORK/report.txt" i-report.txt
check "report exits 0 and prints; the default subcommand is report" test "$rc1" = 0 -a "$rc2" = 0 -a -s "$WORK/report.txt" -a "$(head -n 1 "$WORK/report.txt" | cut -c1-15)" = "slp-gc report  "
check "report leaves the sandbox tree identical (paths, types, modes, symlink targets, sha256, mtimes)" cmp -s "$WORK/snap.before" "$WORK/snap.after"
check "report made no paseo call and sent no signal" test "$(logn paseo.log)" = 0 -a "$(logn kill.log)" = 0
check "report --json is one valid JSON document with process, schedule, agent and garbage sections" jq -e '.procs.procs and .schedules and .agents.rows and (.garbage | type == "array")' "$WORK/report.json"
SLPGC_PASEO_HANG=1 fx_gc report >/dev/null 2>&1; check "report works while the paseo CLI would hang (it never calls it)" test "$?" = 0 -a "$(logn paseo.log)" = 0
R="$WORK/report.txt"
check "report lists every process class with footprint, cmprs, rss, class and overall totals" bash -c "for c in app-main renderer gpu utility supervisor daemon terminal-worker claude-child agent-descendant slp-wait paseo-wait; do grep -q \"^ *[0-9]* *[0-9]* \$c\" '$R' || { echo missing \$c; exit 1; }; done; grep -q 'totals per class' '$R' && grep -q ' ALL ' '$R' && grep -q 'CMPRS' '$R'"
check "report flags footprints above the warn threshold" grep -q '!!WARN' "$R"
check "report states why an item is or is not garbage" bash -c "grep -q 'GARBAGE: archived 20 d ago' '$R' && grep -q 'archived 3 d ago (< 14 d)' '$R' && grep -q 'protected: target agent is live' '$R' && grep -q 'unarchived agent references it via paseo.parent-agent-id' '$R' && grep -q 'in-flight creation' '$R' && grep -q 'invalid JSON' '$R' && grep -q 'symlink' '$R' && grep -q 'dirty=1' '$R'"
check "report shows schedule runs, size and fires; anomalies stay report-only" bash -c "grep -q 'runs 50' '$R' && grep -q 'fires 1h/24h 30/50' '$R' && grep -q 'anomaly (report-only)' '$R'"

# --- (ii) --apply -------------------------------------------------------------------------------
fresh
PROT=("$(agent_file "$A_LIVE")" "$(agent_file "$A_YOUNG")" "$(agent_file "$A_PARENT")" "$(agent_file "$A_CHILD")" "$(agent_file "$A_PROC")"
      "$(agent_file "$A_INVOKER")" "$(agent_file "$A_INFLIGHT")" "$(agent_file "$A_CLOSEDU")" "$(agent_file "$A_STALE")"
      "$FX_PHOME/agents/slug-a/bad.json" "$FX_PHOME/agents/slug-a/link.json"
      "$FX_PHOME/schedules/0000000c.json" "$FX_PHOME/schedules/0000000d.json" "$FX_PHOME/schedules/0000000e.json"
      "$FX_PHOME/schedules/0000000f.json" "$FX_PHOME/schedules/00000010.json" "$FX_PHOME/schedules/lnk00000.json"
      "$FX_PHOME/worktrees/abcd1234/dirty/untracked" "$FX_PHOME/worktrees/abcd1234/clean/f" "$FX_PHOME/config.json" "$FX_PHOME/daemon.log" "$FX_PHOME/paseo.pid")
fx_snapshot "$WORK/sb" > "$WORK/snap2.before"
fx_gc report --apply > "$WORK/apply.txt" 2>"$WORK/apply.err"; rc=$?
fx_snapshot "$WORK/sb" > "$WORK/snap2.after"
diff "$WORK/snap2.before" "$WORK/snap2.after" > "$WORK/snap2.diff"
keep "$WORK/apply.txt" ii-apply-output.txt; keep "$WORK/snap2.diff" ii-snapshot-diff.txt; keep "$FX_LOGS/paseo.log" ii-stub-paseo-argv.log; keep "$FX_LOGS/paseo.env" ii-stub-paseo-env.log
printf '%s\n' "schedule delete 0000000a" "schedule delete 0000000b" "agent delete $A_GC1" "agent delete $A_GC2" | sort > "$WORK/expect.paseo"
sort "$FX_LOGS/paseo.log" > "$WORK/got.paseo"
check "--apply exits 0 and calls the stub paseo with exactly the four targeted argvs" bash -c "test '$rc' = 0 && cmp -s '$WORK/expect.paseo' '$WORK/got.paseo'"
check "--apply passes PASEO_HOME to the CLI and never uses --all / --cwd / a directory delete" bash -c "! grep -qv '^PASEO_HOME=$FX_PHOME\$' '$FX_LOGS/paseo.env' && ! grep -qE -- '--all|--cwd' '$FX_LOGS/paseo.log'"
check "--apply removed only the targeted records (via the stub daemon); no other file or symlink under the home changed" bash -c "grep -E '^[<>] .{0,2}/paseo' '$WORK/snap2.diff' | grep -E ' [fl] [0-7]+ ' > '$WORK/snap2.files'; test \"\$(grep -c '^<' '$WORK/snap2.files')\" = 4 -a \"\$(grep -c '^>' '$WORK/snap2.files')\" = 0 && ! grep -vE '0000000a|0000000b|$A_GC1|$A_GC2' '$WORK/snap2.files' | grep -q ."
check "--apply leaves every protected fixture alone (unarchived, <14 d, live-child label, live schedule target, malformed, symlink, dirty worktree...)" exists_all "${PROT[@]}"
check "--apply sent no signal without kill flags" test "$(logn kill.log)" = 0
fx_gc report --apply >/dev/null 2>&1; check "a second --apply finds nothing left to do (idempotent, no new CLI call)" test "$(logn paseo.log)" = 4

fresh; echo '{"pid":9999,"listen":"127.0.0.1:6767"}' > "$FX_PHOME/paseo.pid"
fx_gc report --apply > "$WORK/refuse.txt" 2>&1; rc=$?
check "--apply is refused (exit 3) when the Supervisor/daemon cannot be identified; nothing is called" test "$rc" = 3 -a "$(logn paseo.log)" = 0 -a "$(logn kill.log)" = 0
check "the refusal is explained in the report" grep -q 'identification: FAILED' "$WORK/refuse.txt"
fresh; SLPGC_PASEO_HANG=1 SLP_GC_CLI_TIMEOUT=1 fx_gc report --apply > "$WORK/hang.txt" 2>&1; rc=$?
keep "$WORK/hang.txt" ii-hung-cli-output.txt
check "a hung paseo CLI is cut by the external timeout; the run stops after one attempt and touches nothing" test "$rc" = 1 -a "$(logn paseo.log)" = 1 -a -f "$FX_PHOME/schedules/0000000a.json" -a -f "$FX_PHOME/schedules/0000000b.json" -a "$(find "$FX_PHOME/agents" -name "$A_GC2.json" -print0 | tr -cd "\0" | wc -c | tr -d " ")" = 1

# --- (iii) kills ---------------------------------------------------------------------------------
fresh
fx_gc report --kill-stale-processes >/dev/null 2>&1; rc=$?
check "kill flags without --apply are refused (exit 2), nothing signalled" test "$rc" = 2 -a "$(logn kill.log)" = 0
fx_gc report --apply --kill-stale-processes --kill-over-memory > "$WORK/kill.txt" 2>&1; rc=$?
keep "$WORK/kill.txt" iii-kill-output.txt; keep "$FX_LOGS/kill.log" iii-stub-kill-argv.log
printf '%s\n' "-TERM 102" "-TERM 121" "-TERM 122" "-TERM 130" "-TERM 190" > "$WORK/expect.kill"; sort "$FX_LOGS/kill.log" > "$WORK/got.kill"
check "kills signal exactly the orphan (121 owner archived, 122 ppid 1, 130 slp-wait) and over-threshold (102 GPU) pids, SIGTERM only, single pids" cmp -s "$WORK/expect.kill" "$WORK/got.kill"
check "never signalled: app main 100 (30000 MB), Supervisor 110 (20000 MB), daemon, invoker's agent 124, young 123/131/160, other-home 170, live-owner children" bash -c "! grep -qE ' (100|110|111|112|120|123|124|131|140|150|160|170|180)\$' '$FX_LOGS/kill.log'"
check "a pid whose lstart changed between listing and signal (125) is skipped" bash -c "grep -q 'kill: 125 -> skipped (lstart' '$WORK/kill.txt' || grep -q '125 -> skipped' '$WORK/kill.txt'"
check "no SIGKILL and no process-group signal was ever issued" bash -c "! grep -qE -- '-9|-KILL|-SIGKILL| -[0-9]+\$|--' '$FX_LOGS/kill.log'"
fresh; fx_gc report --apply --kill-stale-processes >/dev/null 2>&1
check "--kill-stale-processes alone signals only the orphans" test "$(sort "$FX_LOGS/kill.log" | tr '\n' ' ')" = "-TERM 121 -TERM 122 -TERM 130 -TERM 190 "
fresh; fx_gc report --apply --kill-over-memory >/dev/null 2>&1
check "--kill-over-memory alone signals only the over-threshold helper" test "$(cat "$FX_LOGS/kill.log")" = "-TERM 102"
fresh; SLPGC_ADD_SELF=1 fx_gc report --apply --kill-stale-processes > "$WORK/self.txt" 2>&1
check "the process tree slp-gc runs in (an old ppid-1 claude that is its ancestor) is never signalled" bash -c "! grep -q ' 190\$' '$FX_LOGS/kill.log' && grep -q 'protected: in slp-gc' '$WORK/self.txt' || { fx_gc() { :; }; grep -q 'protected' '$WORK/self.txt'; }"
fresh; FX_INVOKER=$A_LIVE fx_gc report --apply --kill-stale-processes >/dev/null 2>&1
check "processes of the invoking agent are protected whichever agent that is (invoker = A_LIVE: 122/125/130 stay)" bash -c "! grep -qE ' (122|125|130)\$' '$FX_LOGS/kill.log'"

# --- (iv) bundle -------------------------------------------------------------------------------
fresh; fx_gc record >/dev/null 2>&1
fx_gc bundle --since 72 > "$WORK/bundle.out" 2>"$WORK/bundle.err"; rc=$?
tgz="$(head -n 1 "$WORK/bundle.out")"; mkdir -p "$WORK/x"
tar -xzf "$tgz" -C "$WORK/x" 2>/dev/null
keep "$WORK/bundle.out" iv-bundle-output.txt
( cd "$WORK/x" && find . -type f | sort ) > "$WORK/bundle.files"; keep "$WORK/bundle.files" iv-bundle-file-list.txt
grep -rn "FAKE-" "$WORK/x" > "$WORK/bundle.grep" 2>/dev/null; keep "$WORK/bundle.grep" iv-grep-fake-secrets-in-tarball.txt
check "bundle writes one tar.gz under <state>/bundles/ and prints its path and manifest" test "$rc" = 0 -a -f "$tgz" -a "$(dirname "$tgz")" = "$FX_STATE/bundles" && grep -q '^EXCLUDED BY CONSTRUCTION' "$WORK/bundle.out"
check "bundle contains logs, filtered crash reports, memory.jsonl, report.json, ps snapshot, vm/sysctl, versions, schedules, agents summary" bash -c "cd '$WORK/x'/* && test -f paseo-home-logs/daemon.log && test -f app-logs/main.log && test -f slp-gc/memory.jsonl && test -f report.json && test -f ps-snapshot.txt && grep -q vm_stat system.txt && grep -q hw.memsize system.txt || grep -q '## sysctl' system.txt; cd '$WORK/x'/* && test -f versions.txt && test -f schedules/0000000a.json && test -f agents-summary.json && test -f unified-log-excerpt.txt && test -f MANIFEST.txt"
check "bundle keeps the Paseo crash + jetsam report and drops the unrelated (Safari) and the too-old one" bash -c "cd '$WORK/x'/*/diagnostic-reports/* && test -f Paseo-1.crash && test -f JetsamEvent-2026.ips && ! test -f Safari-1.crash && ! test -f Paseo-old.crash"
check "bundle excludes secrets: no config.json*, none of the fake tokens (config, ps env, log line) anywhere in the extracted tarball" bash -c "! grep -rq 'FAKE-' '$WORK/x' && test -z \"\$(find '$WORK/x' -name 'config.json*' -o -name '*credential*' -o -name '*keypair*')\""
check "bundle agents summary carries no titles or prompts" bash -c "! grep -rq 'SECRET-PROMPT-TITLE' '$WORK/x'; jq -e 'length > 5 and (.[0] | keys == [\"archivedAt\",\"id\",\"labels\",\"provider\",\"status\"])' '$WORK/x'/*/agents-summary.json"

# --- record -------------------------------------------------------------------------------------
fresh; fx_gc record > /dev/null 2>&1; rc=$?
check "record appends one JSONL sample with per-process memory and system totals" bash -c "test '$rc' = 0 && test \$(wc -l < '$FX_STATE/memory.jsonl') = 1 && jq -e '(.procs | length) == 20 and .system.compressor_stored_pages == 221406 and .system.swap_used_mb == 1500.50 and .overall.n == 20' '$FX_STATE/memory.jsonl'"
check "record stores no command lines or environment (exe names only)" bash -c "! grep -qE 'FAKE-|stream-json|mcp-config|--output-format' '$FX_STATE/memory.jsonl'"
check "record: >= warn raises alerts.log + one notification, rate-limited to once per 15 min" bash -c "test \$(wc -l < '$FX_STATE/alerts.log') = 1 && test \$(wc -l < '$FX_LOGS/osascript.log') = 1"
fx_gc record >/dev/null 2>&1
check "a second record within 15 min appends a sample but no second alert" bash -c "test \$(wc -l < '$FX_STATE/memory.jsonl') = 2 && test \$(wc -l < '$FX_STATE/alerts.log') = 1 && test \$(wc -l < '$FX_LOGS/osascript.log') = 1"
head -c 6000000 /dev/zero | tr '\0' 'x' > "$FX_STATE/memory.jsonl"; fx_gc record >/dev/null 2>&1
check "memory.jsonl rotates at ~5 MB keeping one predecessor" bash -c "test -f '$FX_STATE/memory.jsonl.1' && test \$(wc -c < '$FX_STATE/memory.jsonl') -lt 100000"

# --- (v) tick -----------------------------------------------------------------------------------
fresh; rm -f "$FX_SB/slp-gc.conf"
fx_gc tick > "$WORK/tick1.txt" 2>&1; rc=$?
keep "$WORK/tick1.txt" v-tick-no-config.txt
check "tick without a config is report-only: samples + a report, no paseo call, no signal" bash -c "test '$rc' = 0 && test -s '$FX_STATE/memory.jsonl' && ls '$FX_STATE/reports/'*.txt >/dev/null && test \$(ls '$FX_STATE/reports' | wc -l) = 1 && test \$(cat '$FX_LOGS/paseo.log' 2>/dev/null | wc -l) = 0 && test ! -f '$FX_LOGS/kill.log'"
fx_gc tick >/dev/null 2>&1
check "a second tick records again but writes no new report before the interval" bash -c "test \$(wc -l < '$FX_STATE/memory.jsonl') = 2 && test \$(ls '$FX_STATE/reports' | wc -l) = 1"
fresh; printf 'SLP_GC_APPLY=1\n' > "$FX_SB/slp-gc.conf"; fx_gc report >/dev/null 2>&1
check "the config is read only by tick: a manual report ignores SLP_GC_APPLY=1" test "$(logn paseo.log)" = 0
fx_gc tick > "$WORK/tick2.txt" 2>&1
keep "$FX_SB/slp-gc.conf" v-sandbox-config.txt; keep "$WORK/tick2.txt" v-tick-apply-output.txt; keep "$FX_LOGS/paseo.log" v-tick-apply-paseo-argv.log; keep "$FX_STATE/actions.log" v-tick-actions.log
sort "$FX_LOGS/paseo.log" > "$WORK/got.paseo"
check "tick with SLP_GC_APPLY=1 applies through the stub paseo (same four targets), and sends no signal without the kill keys" bash -c "cmp -s '$WORK/expect.paseo' '$WORK/got.paseo' && test ! -f '$FX_LOGS/kill.log'"
fresh; printf '# comment\nSLP_GC_APPLY=1\nSLP_GC_KILL_STALE="1"\nSLP_GC_MEM_KILL_MB=99999\nEVIL=$(touch %s/pwned)\nSLP_GC_KILL_MEMORY=$(touch %s/pwned2)\n' "$WORK" "$WORK" > "$FX_SB/slp-gc.conf"
fx_gc tick >/dev/null 2>&1
check "tick config keys enable the kill phases individually; the file is parsed, never executed" bash -c "test \"\$(sort '$FX_LOGS/kill.log' | tr '\n' ' ')\" = '-TERM 121 -TERM 122 -TERM 130 -TERM 190 ' && ! test -e '$WORK/pwned' && ! test -e '$WORK/pwned2'"
fresh; sleep 60 & holder=$!
mkdir -p "$FX_STATE/tick.lock"; echo "$holder" > "$FX_STATE/tick.lock/pid"
fx_gc tick > "$WORK/tick3.txt" 2>&1; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
keep "$WORK/tick3.txt" v-tick-locked-output.txt
check "the lock prevents a concurrent tick (live holder: skipped, nothing recorded)" bash -c "grep -q 'another tick is running' '$WORK/tick3.txt' && test ! -f '$FX_STATE/memory.jsonl'"
fresh; mkdir -p "$FX_STATE/tick.lock"; echo 99999999 > "$FX_STATE/tick.lock/pid"
fx_gc tick > /dev/null 2>&1
check "a stale lock (dead holder) is recovered and the tick runs; the lock is released afterwards" bash -c "test -s '$FX_STATE/memory.jsonl' && test ! -e '$FX_STATE/tick.lock'"
fresh; env -i PATH=/usr/bin:/bin HOME="$FX_HOME" TMPDIR="$FX_TMP" SLP_GC_STATE_DIR="$FX_STATE" SLP_GC_CONFIG=/nonexistent PASEO_HOME="$FX_PHOME" \
  SLP_GC_PS="$FX_BIN/ps" SLP_GC_PSENV="$FX_BIN/psenv" SLP_GC_TOP="$FX_BIN/top" SLP_GC_LSOF="$FX_BIN/lsof" SLP_GC_VMSTAT="$FX_BIN/vm_stat" \
  SLP_GC_SYSCTL="$FX_BIN/sysctl" SLPGC_FIX="$FX_FIX" "$GC" tick >/dev/null 2>&1
check "tick works under a minimal environment (env -i, PATH=/usr/bin:/bin)" test -s "$FX_STATE/memory.jsonl"

# --- static properties -------------------------------------------------------------------------
check "slp-gc is bash 3.2-syntax clean and executable" bash -c "bash -n '$GC' && test -x '$GC'"
check "slp-gc has no SIGKILL, no process-group signal, no eval/source of the config, no recursive rm outside temp/lock/report rotation" bash -c "
  ! grep -nE 'kill +-(9|KILL|SIGKILL)|-KILL|kill +-[0-9]+ +-|kill +.*-- *-' '$GC' | grep -v '^[0-9]*: *#' | grep -q . &&
  ! grep -nE '(^|[^a-z_])(source|\\.) +\"?\\\$\\{?(file|SLP_GC_CONFIG)' '$GC' | grep -q . &&
  ! grep -nE '(^|[^a-z])rm +-' '$GC' | grep -vE '\\\$T|LOCKDIR|STATE/reports|stale\\.' | grep -q ."
check "--help exits 0; an unknown flag exits 2" bash -c "'$GC' --help >/dev/null && ! '$GC' --bogus >/dev/null 2>&1; test \$? = 0"

[ "$FAILED" = 0 ] || exit 1
