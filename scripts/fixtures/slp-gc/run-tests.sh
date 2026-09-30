#!/usr/bin/env bash
# slp-gc sandbox tests. Prints "ok: ..." / "FAIL: ..." lines, exits 1 on any failure.
# Everything runs in temp sandboxes (temp PASEO_HOME + HOME, stub ps/top/lsof/paseo/kill/...):
# never against the real ~/.paseo or real processes. Needs bash, jq, perl, git (no macOS tools).
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

for tool in jq perl git; do command -v "$tool" >/dev/null 2>&1 || { echo "ok: slp-gc tests skipped ($tool missing)"; exit 0; }; done
# shellcheck source=sandbox.sh
. "$HERE/sandbox.sh"
# shellcheck disable=SC2034
FX_GC="$GC"
fresh() { rm -rf "$WORK/sb" "$WORK/sb.tmp"; mkdir -p "$WORK/sb"; make_sandbox "$WORK/sb" >/dev/null 2>&1
          unset SLPGC_PASEO_HANG SLPGC_ADD_SELF FX_EXTRA_ENV FX_HOOK FX_INVOKER; RP="$(cd -P "$FX_PHOME" && pwd -P)"; }
logn() { if [ -f "$FX_LOGS/$1" ]; then wc -l < "$FX_LOGS/$1" | tr -d ' '; else echo 0; fi; }
agent_file() { find "$FX_PHOME/agents" -mindepth 2 -maxdepth 2 -name "$1.json" -print -quit 2>/dev/null; }
agent_count() { find "$FX_PHOME/agents" -name "$1.json" -print0 | tr -cd '\0' | wc -c | tr -d ' '; }
exists_all() { local p; for p in "$@"; do [ -e "$p" ] || [ -L "$p" ] || { echo "  missing: $p"; return 1; }; done; }
kills() { sort "$FX_LOGS/kill.log" 2>/dev/null | tr '\n' ' '; }
del_line() { sed -i.b "/^  $1 /d" "$FX_FIX/env.txt"; rm -f "$FX_FIX/env.txt.b"; }   # make one pid's env unreadable
set_ls() { printf '%s\n' "$1" > "$FX_FIX/agents-ls.json"; }
ls_row() { printf '{"id":"%s","archivedAt":"2026-08-01T00:00:00.000Z","status":"%s"}' "$1" "$2"; }

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
check "report --json is one valid JSON document with process, schedule, agent, index and garbage sections" jq -e '.procs.procs and .schedules and .agents.rows and .index.ok and (.garbage | type == "array")' "$WORK/report.json"
SLPGC_PASEO_HANG=1 fx_gc report >/dev/null 2>&1; check "report works while the paseo CLI would hang (it never calls it)" test "$?" = 0 -a "$(logn paseo.log)" = 0
R="$WORK/report.txt"
check "report lists every process class with footprint, cmprs, rss, class and overall totals" bash -c "for c in app-main renderer gpu utility supervisor daemon terminal-worker claude-child agent-descendant slp-wait paseo-wait; do grep -q \"^ *[0-9]* *[0-9]* \$c\" '$R' || { echo missing \$c; exit 1; }; done; grep -q 'totals per class' '$R' && grep -q ' ALL ' '$R' && grep -q 'CMPRS' '$R'"
check "report flags footprints above the warn threshold" grep -q '!!WARN' "$R"
check "report states why an item is or is not garbage" bash -c "grep -q 'GARBAGE: archived 20 d ago' '$R' && grep -q 'archived 3 d ago (< 14 d)' '$R' && grep -q 'protected: target agent is live' '$R' && grep -q 'unarchived agent references it via paseo.parent-agent-id' '$R' && grep -q 'in-flight creation' '$R' && grep -q 'invalid JSON' '$R' && grep -q 'symlink' '$R' && grep -q 'dirty=1' '$R'"
check "report shows schedule runs, size and fires; anomalies stay report-only" bash -c "grep -q 'runs 50' '$R' && grep -q 'fires 1h/24h 30/50' '$R' && grep -q 'anomaly (report-only)' '$R'"
check "repair 8: missing keys (internal / lastRunAt) are skipped, not defaulted; a newline-named malformed file still protects the id it mentions" bash -c "grep -q 'required keys missing' '$R' && grep -A1 '$A_NLREF' '$R' | grep -q 'unreadable record/schedule mentions it'"
check "repair 4/L9: control characters in fields are sanitised in the text report" bash -c "! grep -q \$'\\033' '$R' && grep -q 'supervisor: ?\[31mred' '$R'"

# --- (ii) --apply -------------------------------------------------------------------------------
fresh
PROT=("$(agent_file "$A_LIVE")" "$(agent_file "$A_YOUNG")" "$(agent_file "$A_PARENT")" "$(agent_file "$A_CHILD")" "$(agent_file "$A_PROC")"
      "$(agent_file "$A_INVOKER")" "$(agent_file "$A_INFLIGHT")" "$(agent_file "$A_CLOSEDU")" "$(agent_file "$A_STALE")"
      "$(agent_file "$A_NOINT")" "$(agent_file "$A_NLREF")"
      "$FX_PHOME/agents/slug-a/bad.json" "$FX_PHOME/agents/slug-a/link.json"
      "$FX_PHOME/schedules/0000000c.json" "$FX_PHOME/schedules/0000000d.json" "$FX_PHOME/schedules/0000000e.json"
      "$FX_PHOME/schedules/0000000f.json" "$FX_PHOME/schedules/00000010.json" "$FX_PHOME/schedules/00000011.json" "$FX_PHOME/schedules/lnk00000.json"
      "$FX_PHOME/worktrees/abcd1234/dirty/untracked" "$FX_PHOME/worktrees/abcd1234/clean/f" "$FX_PHOME/config.json" "$FX_PHOME/daemon.log" "$FX_PHOME/paseo.pid")
fx_snapshot "$WORK/sb" > "$WORK/snap2.before"
fx_gc report --apply > "$WORK/apply.txt" 2>"$WORK/apply.err"; rc=$?
fx_snapshot "$WORK/sb" > "$WORK/snap2.after"
diff "$WORK/snap2.before" "$WORK/snap2.after" > "$WORK/snap2.diff"
keep "$WORK/apply.txt" ii-apply-output.txt; keep "$WORK/snap2.diff" ii-snapshot-diff.txt; keep "$FX_LOGS/paseo.log" ii-stub-paseo-argv.log; keep "$FX_LOGS/paseo.env" ii-stub-paseo-env.log
printf '%s\n' "schedule delete --home $RP -- 0000000a" "schedule delete --home $RP -- 0000000b" "agent delete --home $RP -- $A_GC1" "agent delete --home $RP -- $A_GC2" | sort > "$WORK/expect.paseo"
sort "$FX_LOGS/paseo.log" > "$WORK/got.paseo"
check "--apply exits 0 and calls the stub paseo with exactly the four targeted argvs, each with --home <resolved home> and -- before the id" bash -c "test '$rc' = 0 && cmp -s '$WORK/expect.paseo' '$WORK/got.paseo'"
check "--apply also passes PASEO_HOME in the env and never uses --all / --cwd" bash -c "! grep -qv '^PASEO_HOME=$RP\$' '$FX_LOGS/paseo.env' && ! grep -qE -- '--all|--cwd' '$FX_LOGS/paseo.log'"
check "--apply removed only the targeted records (via the stub daemon); no other file or symlink under the home changed" bash -c "grep -E '^[<>] .{0,2}/paseo' '$WORK/snap2.diff' | grep -E ' [fl] [0-7]+ ' > '$WORK/snap2.files'; test \"\$(grep -c '^<' '$WORK/snap2.files')\" = 4 -a \"\$(grep -c '^>' '$WORK/snap2.files')\" = 0 && ! grep -vE '0000000a|0000000b|$A_GC1|$A_GC2' '$WORK/snap2.files' | grep -q ."
check "--apply leaves every protected fixture alone (unarchived, <14 d, live-child label, live schedule target, malformed, symlink, missing keys, newline-named malformed reference, dirty worktree...)" exists_all "${PROT[@]}"
check "--apply sent no signal without kill flags" test "$(logn kill.log)" = 0
fx_gc report --apply >/dev/null 2>&1; check "a second --apply finds nothing left to do (idempotent, no new CLI call)" test "$(logn paseo.log)" = 4

fresh; echo '{"pid":9999,"listen":"127.0.0.1:6767"}' > "$FX_PHOME/paseo.pid"
fx_gc report --apply > "$WORK/refuse.txt" 2>&1; rc=$?
check "--apply is refused (exit 3) when the Supervisor/daemon cannot be identified; nothing is called" test "$rc" = 3 -a "$(logn paseo.log)" = 0 -a "$(logn kill.log)" = 0
check "the refusal is explained in the report" grep -q 'identification: FAILED' "$WORK/refuse.txt"
fresh; SLPGC_PASEO_HANG=1 SLP_GC_CLI_TIMEOUT=1 fx_gc report --apply > "$WORK/hang.txt" 2>&1; rc=$?
keep "$WORK/hang.txt" ii-hung-cli-output.txt
check "a hung paseo CLI is cut by the external timeout; the run stops after one attempt and touches nothing" test "$rc" = 1 -a "$(logn paseo.log)" = 1 -a -f "$FX_PHOME/schedules/0000000a.json" -a -f "$FX_PHOME/schedules/0000000b.json" -a "$(agent_count "$A_GC2")" = 1

# repair 4: the full predicate is recomputed right before each action
fresh; fx_make_hook
fx_gc report --apply > "$WORK/hook.txt" 2>&1; rc=$?
keep "$WORK/hook.txt" ii-recheck-unarchived-between-evaluation-and-action.txt; keep "$FX_LOGS/paseo.log" ii-recheck-paseo-argv.log
check "repair 4: targets unarchived between evaluation and action are NOT touched (schedule 0a lost its archived target, agents A_GC1/A_GC2 are live); only the still-garbage schedule 0b goes" bash -c "test '$rc' = 0 && test \"\$(cat '$FX_LOGS/paseo.log')\" = 'schedule delete --home $RP -- 0000000b' && test -f '$FX_PHOME/schedules/0000000a.json' && test '$(agent_count "$A_GC1")' = 1 -a '$(agent_count "$A_GC2")' = 1 && grep -q 'no longer garbage on the fresh full re-evaluation' '$WORK/hook.txt'"

# repair 3: unreadable env => ownership cannot be disproved
fresh; del_line 120
fx_gc report > "$WORK/blind.txt" 2>&1
check "repair 3: the report says the env of an agent-class process is unreadable and --apply would need a paseo agent ls proof" grep -q 'env of 1 agent-class process(es) is unreadable' "$WORK/blind.txt"
fx_gc report --apply > "$WORK/blind-apply.txt" 2>&1; rc=$?
keep "$WORK/blind-apply.txt" ii-unreadable-env-apply.txt; keep "$FX_LOGS/paseo.log" ii-unreadable-env-paseo-argv.log
check "repair 3: with unreadable env and a failing 'paseo agent ls', no agent is deleted (schedules are unaffected)" bash -c "! grep -q 'agent delete' '$FX_LOGS/paseo.log' && grep -q 'agent ls -a -g --json --home $RP' '$FX_LOGS/paseo.log' && grep -c 'schedule delete' '$FX_LOGS/paseo.log' | grep -q 2 && test '$(agent_count "$A_GC1")' = 1 -a '$(agent_count "$A_GC2")' = 1"
fresh; del_line 120; set_ls "[$(ls_row "$A_GC1" closed),$(ls_row "$A_GC2" running)]"
fx_gc report --apply > "$WORK/blind-apply2.txt" 2>&1
check "repair 3: 'paseo agent ls' proof allows the archived-and-not-running agent and blocks the one shown running" bash -c "grep -q 'agent delete --home $RP -- $A_GC1' '$FX_LOGS/paseo.log' && ! grep -q 'agent delete --home $RP -- $A_GC2' '$FX_LOGS/paseo.log' && test '$(agent_count "$A_GC1")' = 0 -a '$(agent_count "$A_GC2")' = 1"

# repair 6: home binding
fresh; sed -i.b "s#^  110 Paseo Supervisor PATH=/usr/bin PASEO_HOME=.*#  110 Paseo Supervisor PATH=/usr/bin PASEO_HOME=/elsewhere#" "$FX_FIX/env.txt"
fx_gc report --apply > "$WORK/home1.txt" 2>&1; rc=$?
check "repair 6: --apply is refused (exit 3) when the Supervisor's PASEO_HOME is another home" test "$rc" = 3 -a "$(logn paseo.log)" = 0
fresh; del_line 110
fx_gc report --apply > "$WORK/home2.txt" 2>&1; rc=$?
check "repair 6: with the Supervisor's env unreadable, a non-default home is refused (exit 3)" test "$rc" = 3 -a "$(logn paseo.log)" = 0
fresh; del_line 110; ln -s "$FX_PHOME" "$FX_HOME/.paseo"
fx_gc report --apply > "$WORK/home3.txt" 2>&1; rc=$?
check "repair 6: with the Supervisor's env unreadable, the default ~/.paseo (resolved) is accepted" test "$rc" = 0 -a "$(logn paseo.log)" = 4

# --- (iii) kills ---------------------------------------------------------------------------------
fresh
fx_gc report --kill-stale-processes >/dev/null 2>&1; rc=$?
check "kill flags without --apply are refused (exit 2), nothing signalled" test "$rc" = 2 -a "$(logn kill.log)" = 0
fx_gc report --apply --kill-stale-processes --kill-over-memory > "$WORK/kill.txt" 2>&1; rc=$?
keep "$WORK/kill.txt" iii-kill-output.txt; keep "$FX_LOGS/kill.log" iii-stub-kill-argv.log; keep "$WORK/kill.txt" iii-kill-report.txt
check "kills signal exactly the launchd-reparented orphans (122, 190, slp-wait 130) and the bound over-threshold helper (GPU 102), SIGTERM only, single pids" test "$(kills)" = "-TERM 102 -TERM 122 -TERM 130 -TERM 190 "
check "repair 1: daemon-owned claude 121 (owner archived) is never signalled and is reported as daemon-owned" bash -c "! grep -q ' 121\$' '$FX_LOGS/kill.log' && grep -q 'daemon-owned' '$WORK/kill.txt'"
check "repair 2: a 20000 MB stream-json claude with a matching PASEO_HOME that is NOT under the daemon (195, parent 999) and a GPU helper under a different app main (201, 20000 MB) are not signalled" bash -c "! grep -qE ' (195|201)\$' '$FX_LOGS/kill.log' && grep -q 'not a direct child of the app main' '$WORK/kill.txt' && grep -q 'not a descendant of the identified daemon' '$WORK/kill.txt'"
check "never signalled: app main 100 (30000 MB), Supervisor 110 (20000 MB), daemon, invoker's agent 124, young 123/131/160, other-home 170, daemon-run children" bash -c "! grep -qE ' (100|110|111|112|120|121|123|124|131|140|150|160|170|180|195|200|201)\$' '$FX_LOGS/kill.log'"
check "a pid whose lstart changed between listing and signal (125) is skipped" grep -q '125 -> skipped (lstart' "$WORK/kill.txt"
check "no SIGKILL and no process-group signal was ever issued" bash -c "! grep -qE -- '-9|-KILL|-SIGKILL| -[0-9]+\$|--' '$FX_LOGS/kill.log'"
fresh; fx_gc report --apply --kill-stale-processes >/dev/null 2>&1
check "--kill-stale-processes alone signals only the orphans" test "$(kills)" = "-TERM 122 -TERM 130 -TERM 190 "
fresh; fx_gc report --apply --kill-over-memory >/dev/null 2>&1
check "--kill-over-memory alone signals only the over-threshold helper" test "$(kills)" = "-TERM 102 "
fresh; SLPGC_ADD_SELF=1 fx_gc report --apply --kill-stale-processes > "$WORK/self.txt" 2>&1
check "the process tree slp-gc runs in (an old ppid-1 claude that is its ancestor) is never signalled" bash -c "! grep -q ' 190\$' '$FX_LOGS/kill.log' && grep -q 'protected: in slp-gc' '$WORK/self.txt'"
fresh; FX_INVOKER=$A_LIVE fx_gc report --apply --kill-stale-processes >/dev/null 2>&1
check "processes of the invoking agent are protected whichever agent that is (invoker = A_LIVE: 122/125/130/190 stay)" bash -c "! grep -qE ' (122|125|130|190)\$' '$FX_LOGS/kill.log'"
fresh; del_line 122
fx_gc report --apply --kill-stale-processes >/dev/null 2>&1
check "repair 3/env: a process whose env is unreadable is never signalled by the stale rule" test "$(kills)" = "-TERM 130 -TERM 190 "

# --- record -------------------------------------------------------------------------------------
fresh; fx_gc record > /dev/null 2>&1; rc=$?
check "record appends one JSONL sample with per-process memory and system totals" bash -c "test '$rc' = 0 && test \$(wc -l < '$FX_STATE/memory.jsonl') = 1 && jq -e '(.procs | length) == 23 and .system.compressor_stored_pages == 221406 and .system.swap_used_mb == 1500.5 and .overall.n == 23' '$FX_STATE/memory.jsonl'"
check "record stores no command lines or environment (exe names only)" bash -c "! grep -qE 'FAKE-|stream-json|mcp-config|--output-format' '$FX_STATE/memory.jsonl'"
check "record: >= warn raises alerts.log + one notification, rate-limited to once per 15 min" bash -c "test \$(wc -l < '$FX_STATE/alerts.log') = 1 && test \$(wc -l < '$FX_LOGS/osascript.log') = 1"
fx_gc record >/dev/null 2>&1
check "a second record within 15 min appends a sample but no second alert" bash -c "test \$(wc -l < '$FX_STATE/memory.jsonl') = 2 && test \$(wc -l < '$FX_STATE/alerts.log') = 1 && test \$(wc -l < '$FX_LOGS/osascript.log') = 1"
head -c 6000000 /dev/zero | tr '\0' 'x' > "$FX_STATE/memory.jsonl"; fx_gc record >/dev/null 2>&1
check "memory.jsonl rotates at ~5 MB keeping one predecessor" bash -c "test -f '$FX_STATE/memory.jsonl.1' && test \$(wc -c < '$FX_STATE/memory.jsonl') -lt 100000"
head -c 5242870 /dev/zero | tr '\0' 'x' > "$FX_STATE/memory.jsonl"; rm -f "$FX_STATE/memory.jsonl.1"; fx_gc record >/dev/null 2>&1
check "#9: the cap includes the size of the line about to be added (5 MB - 10 bytes + one sample rotates)" bash -c "test -f '$FX_STATE/memory.jsonl.1' && test \$(wc -c < '$FX_STATE/memory.jsonl') -lt 100000"

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
fresh; printf '# comment\nSLP_GC_APPLY=1\nSLP_GC_KILL_STALE="1"\nEVIL=$(touch %s/pwned)\nSLP_GC_KILL_MEMORY=$(touch %s/pwned2)\n' "$WORK" "$WORK" > "$FX_SB/slp-gc.conf"
fx_gc tick >/dev/null 2>&1
check "tick config keys enable the kill phases individually; the file is parsed, never executed" bash -c "test \"\$(sort '$FX_LOGS/kill.log' | tr '\n' ' ')\" = '-TERM 122 -TERM 130 -TERM 190 ' && ! test -e '$WORK/pwned' && ! test -e '$WORK/pwned2'"
fresh; printf 'SLP_GC_APPLY=1\nSLP_GC_KILL_STALE=1\nSLP_GC_APPLY=0\n' > "$FX_SB/slp-gc.conf"; fx_gc tick >/dev/null 2>&1
check "repair 5: the last assignment wins (APPLY=1 then APPLY=0 => nothing applied, nothing killed)" test "$(logn paseo.log)" = 0 -a ! -f "$FX_LOGS/kill.log"
fresh; printf 'SLP_GC_APPLY=1\nSLP_GC_APPLY=yes\n' > "$FX_SB/slp-gc.conf"; fx_gc tick >/dev/null 2>&1
check "repair 5: a flag is on only when its final value is exactly 1 (yes/true/2 are off)" test "$(logn paseo.log)" = 0
fresh; printf 'SLP_GC_APPLY=1\nSLP_GC_KILL_MEMORY=1\nSLP_GC_MEM_KILL_MB=10\n' > "$FX_SB/slp-gc.conf"; fx_gc tick >/dev/null 2>&1
check "repair 5: SLP_GC_MEM_KILL_MB=10 is below the 1024 floor and falls back to 16384 (only the 20000 MB helper is signalled, not 200 MB processes)" test "$(kills)" = "-TERM 102 "
fresh; printf 'SLP_GC_MEM_WARN_MB=8000\nSLP_GC_MEM_KILL_MB=7000\nSLP_GC_APPLY=1\nSLP_GC_KILL_MEMORY=1\n' > "$FX_SB/slp-gc.conf"; fx_gc tick >/dev/null 2>&1
check "repair 5: a kill threshold below the warn threshold is invalid (default 16384 used): 102 still the only kill" test "$(kills)" = "-TERM 102 "

# repair 7: the lock
LSTART() { LC_ALL=C /bin/ps -o lstart= -p "$1" | tr -s ' ' | sed 's/^ //; s/ $//'; }
fresh; sleep 60 & holder=$!
mkdir -p "$FX_STATE/tick.lock"; printf '%s\t%s\n' "$holder" "$(LSTART "$holder")" > "$FX_STATE/tick.lock/owner"; touch -t 200001010000 "$FX_STATE/tick.lock" "$FX_STATE/tick.lock/owner"
fx_gc tick > "$WORK/tick3.txt" 2>&1
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
keep "$WORK/tick3.txt" v-tick-locked-output.txt
check "repair 7: the lock prevents a concurrent tick and an OLD lock with a live owner (same pid + lstart) is never stolen" bash -c "grep -q 'another tick is running' '$WORK/tick3.txt' && test ! -f '$FX_STATE/memory.jsonl' && test -d '$FX_STATE/tick.lock'"
fresh; sleep 60 & holder=$!
mkdir -p "$FX_STATE/tick.lock"; printf '%s\t%s\n' "$holder" "Mon Jan  1 00:00:00 2001" > "$FX_STATE/tick.lock/owner"
fx_gc tick > /dev/null 2>&1
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "repair 7: a lock whose pid is alive but has a different start time (pid reuse) is stale and recovered" bash -c "test -s '$FX_STATE/memory.jsonl' && test ! -e '$FX_STATE/tick.lock'"
fresh; mkdir -p "$FX_STATE/tick.lock"; printf '%s\t%s\n' 99999999 "Mon Jan  1 00:00:00 2001" > "$FX_STATE/tick.lock/owner"
fx_gc tick > /dev/null 2>&1
check "repair 7: a lock with a dead owner is recovered; the lock is released afterwards and no takeover dir is left" bash -c "test -s '$FX_STATE/memory.jsonl' && test ! -e '$FX_STATE/tick.lock' && test ! -e '$FX_STATE/tick.lock.takeover'"
check "repair 7: cleanup removes the lock only if the owner file is still ours (static)" grep -q 'cat "$LOCKDIR/owner" 2>/dev/null)" = "$NONCE"' "$GC"
fresh; env -i PATH=/usr/bin:/bin SLP_GC_TEST=1 HOME="$FX_HOME" TMPDIR="$FX_TMP" SLP_GC_STATE_DIR="$FX_STATE" SLP_GC_CONFIG=/nonexistent PASEO_HOME="$FX_PHOME" \
  SLP_GC_PS="$FX_BIN/ps" SLP_GC_PSENV="$FX_BIN/psenv" SLP_GC_TOP="$FX_BIN/top" SLP_GC_LSOF="$FX_BIN/lsof" SLP_GC_VMSTAT="$FX_BIN/vm_stat" \
  SLP_GC_SYSCTL="$FX_BIN/sysctl" SLPGC_FIX="$FX_FIX" "$GC" tick >/dev/null 2>&1
check "tick works under a minimal environment (env -i, PATH=/usr/bin:/bin)" test -s "$FX_STATE/memory.jsonl"

# --- hardening ----------------------------------------------------------------------------------
fresh
env -i PATH=/usr/bin:/bin HOME="$FX_HOME" TMPDIR="$FX_TMP" SLP_GC_STATE_DIR="$FX_STATE" PASEO_HOME="$FX_PHOME" \
  SLP_GC_PS="$FX_BIN/ps" SLP_GC_PSENV="$FX_BIN/psenv" SLP_GC_TOP="$FX_BIN/top" SLP_GC_KILL="$FX_BIN/kill" SLP_GC_PASEO="$FX_BIN/paseo" SLP_GC_NOW=1 \
  SLPGC_FIX="$FX_FIX" SLPGC_LOGS="$FX_LOGS" "$GC" report --apply > "$WORK/notest.txt" 2>&1
check "L6: without SLP_GC_TEST=1 the probe/clock/CLI overrides are ignored (fixture processes never appear, identification fails, nothing is called)" bash -c "! grep -q 'Supervisor 110' '$WORK/notest.txt' && grep -q 'identification: FAILED' '$WORK/notest.txt' && test '$(logn paseo.log)' = 0 -a '$(logn kill.log)' = 0"
fresh; printf '%s\n' "$(cat "$FX_FIX/ps.txt")" "$(grep '^   111 ' "$FX_FIX/ps.txt")" > "$FX_FIX/ps.dup"; mv "$FX_FIX/ps.dup" "$FX_FIX/ps.txt"
fx_gc report --apply > "$WORK/dup.txt" 2>&1; rc=$?
check "L4: duplicate pid rows in the ps output fail identification and refuse --apply (exit 3)" test "$rc" = 3 -a "$(logn paseo.log)" = 0 && grep -q 'duplicate pid rows' "$WORK/dup.txt"
fresh; FX_EXTRA_ENV="SLP_GC_CLI_TIMEOUT=abc SLP_GC_MEM_WARN_MB=0800" fx_gc report > "$WORK/num.txt" 2>&1; rc=$?
check "L7/L13: an invalid SLP_GC_CLI_TIMEOUT falls back (exit 0); 0800 is read as decimal 800" bash -c "test '$rc' = 0 && grep -q 'warn >= 800 MB' '$WORK/num.txt'"
check "L2: uuid validation is newline-safe (a trailing newline or CR fails)" bash -c "eval \"\$(grep -E '^(UUID_RE|uuid_ok)' '$GC')\"; uuid_ok $A_GC1 && ! uuid_ok \"$A_GC1\$'\\n'\" && ! uuid_ok \"$A_GC1\$'\\r'\" && ! uuid_ok 'x'"
check "the bundle subcommand is gone: 'slp-gc bundle' is a usage error (exit 2) and no bundle code remains" bash -c "'$GC' bundle >/dev/null 2>&1; test \$? = 2 && ! grep -qiE 'do_bundle|tar -c|--since|REDACT_PL|DiagnosticReports' '$GC'"

# --- static properties -------------------------------------------------------------------------
check "slp-gc is bash 3.2-syntax clean and executable" bash -c "bash -n '$GC' && test -x '$GC'"
check "slp-gc has no SIGKILL, no process-group signal, no eval/source of the config, no recursive rm outside temp/lock/report rotation" bash -c "
  ! grep -nE 'kill +-(9|KILL|SIGKILL)|-KILL|kill +-[0-9]+ +-|kill +.*-- *-' '$GC' | grep -v '^[0-9]*: *#' | grep -q . &&
  ! grep -nE '(^|[^a-z_])(source|\\.) +\"?\\\$\\{?(file|SLP_GC_CONFIG)' '$GC' | grep -q . &&
  ! grep -nE '(^|[^a-z])rm +-' '$GC' | grep -vE '\\\$T|LOCKDIR|STATE/reports|stale\\.' | grep -q ."
check "every paseo CLI call passes --home explicitly and -- before ids (static)" bash -c "grep -c 'run_cli .*--home \"\$PHOME\"' '$GC' | grep -q 2 && grep -q -- '-- \"\$id\"' '$GC'"
check "--help exits 0; an unknown flag exits 2" bash -c "'$GC' --help >/dev/null && ! '$GC' --bogus >/dev/null 2>&1; test \$? = 0"

[ "$FAILED" = 0 ] || exit 1
