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
umask 077   # the ledger and the state dir must be 0600 / 0700
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
EV="${SLPGC_EVIDENCE:-}"; [ -z "$EV" ] || mkdir -p "$EV"
keep() { [ -z "$EV" ] || cp "$1" "$EV/$2" 2>/dev/null; }

for tool in jq perl git; do command -v "$tool" >/dev/null 2>&1 || { echo "ok: slp-gc tests skipped ($tool missing)"; exit 0; }; done
# shellcheck source=sandbox.sh
. "$HERE/sandbox.sh"
# shellcheck disable=SC2034
FX_GC="$GC"
# make_sandbox is slow (git init/commit): the first fresh builds a pristine copy, later ones restore it (same path, mtimes kept)
fresh() { rm -rf "$WORK/sb" "$WORK/sb.tmp"; mkdir -p "$WORK/sb"
          if [ -d "$WORK/pristine" ]; then cp -Rp "$WORK/pristine/." "$WORK/sb/"; mkdir -p "$WORK/sb.tmp"
          else make_sandbox "$WORK/sb" >/dev/null 2>&1; mkdir -p "$WORK/pristine"; cp -Rp "$WORK/sb/." "$WORK/pristine/"; fi
          unset FX_TRACE SLPGC_PASEO_HANG SLPGC_ADD_SELF FX_EXTRA_ENV FX_HOOK FX_INVOKER; RP="$(cd -P "$FX_PHOME" && pwd -P)"; }
logn() { if [ -f "$FX_LOGS/$1" ]; then wc -l < "$FX_LOGS/$1" | tr -d ' '; else echo 0; fi; }
agent_file() { find "$FX_PHOME/agents" -mindepth 2 -maxdepth 2 -name "$1.json" -print -quit 2>/dev/null; }
agent_count() { find "$FX_PHOME/agents" -name "$1.json" -print0 | tr -cd '\0' | wc -c | tr -d ' '; }
exists_all() { local p; for p in "$@"; do [ -e "$p" ] || [ -L "$p" ] || { echo "  missing: $p"; return 1; }; done; }
kills() { sort "$FX_LOGS/kill.log" 2>/dev/null | tr '\n' ' '; }
del_line() { sed -i.b "/^  $1 /d" "$FX_FIX/env.txt"; rm -f "$FX_FIX/env.txt.b"; }   # make one pid's env unreadable
# paseo agent inspect output (capitalised keys): set_inspect <id> <Archived> <ArchivedAt json> <Status> [Id]
nogc() { rm -f "$FX_PHOME"/schedules/0000000[ab].json; find "$FX_PHOME/agents" -type f \( -name "$A_GC1.json" -o -name "$A_GC2.json" \) -exec rm -f {} +; }   # kill tests: no garbage to delete (each delete costs a full recheck)
# ArchivedAt "@disk" = exactly what the record on disk says (the proof must agree with the freshly read record)
set_inspect() { local at="$3"; [ "$at" != @disk ] || at="$(jq -c .archivedAt "$(agent_file "$1")")"
  printf '{"Id":"%s","Archived":%s,"ArchivedAt":%s,"Status":"%s","ParentAgentId":null,"Cwd":"/tmp/fx","Worktree":null}\n' "${5:-$1}" "$2" "$at" "$4" > "$FX_FIX/inspect-$1.json"; }
ARCH_AT=@disk

# --- (i) report is read-only ---------------------------------------------------------------------
# the retention scan (find/du/git) is slow, so the fixtures skip it (test-only SLP_GC_SKIP_RETENTION) except here
fresh; FX_RETENTION=on
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

# shellcheck disable=SC2034  # read by sandbox.sh (fx_gc)
FX_RETENTION=
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
check "repair 3: the report says the env of an agent-class process is unreadable and --apply would need a paseo agent inspect proof" grep -q 'env of 1 agent-class process(es) is unreadable' "$WORK/blind.txt"
fx_gc report --apply > "$WORK/blind-apply.txt" 2>&1; rc=$?
keep "$WORK/blind-apply.txt" ii-unreadable-env-apply.txt; keep "$FX_LOGS/paseo.log" ii-unreadable-env-paseo-argv.log
check "repair 3 / T1: with unreadable env and a failing 'paseo agent inspect', no agent is deleted (schedules are unaffected)" bash -c "! grep -q 'agent delete' '$FX_LOGS/paseo.log' && grep -q 'agent inspect --home $RP --json -- $A_GC1' '$FX_LOGS/paseo.log' && grep -c 'schedule delete' '$FX_LOGS/paseo.log' | grep -q 2 && test '$(agent_count "$A_GC1")' = 1 -a '$(agent_count "$A_GC2")' = 1"
fresh; del_line 120; set_inspect "$A_GC1" true "$ARCH_AT" closed; set_inspect "$A_GC2" true "$ARCH_AT" running
fx_gc report --apply > "$WORK/blind-apply2.txt" 2>&1
check "repair 3 / T1: the 'paseo agent inspect' proof allows the archived-and-not-running agent and blocks the one shown running" bash -c "grep -q 'agent delete --home $RP -- $A_GC1' '$FX_LOGS/paseo.log' && ! grep -q 'agent delete --home $RP -- $A_GC2' '$FX_LOGS/paseo.log' && test '$(agent_count "$A_GC1")' = 0 -a '$(agent_count "$A_GC2")' = 1"

# repair 6: home binding
fresh; sed -i.b "s#^  110 Paseo Supervisor PATH=/usr/bin PASEO_HOME=.*#  110 Paseo Supervisor PATH=/usr/bin PASEO_HOME=/elsewhere#" "$FX_FIX/env.txt"
fx_gc report --apply > "$WORK/home1.txt" 2>&1; rc=$?
check "repair 6: --apply is refused (exit 3) when the Supervisor's PASEO_HOME is another home" test "$rc" = 3 -a "$(logn paseo.log)" = 0
fresh; del_line 110
fx_gc report --apply > "$WORK/home2.txt" 2>&1; rc=$?
check "repair 6: with the Supervisor's env unreadable, a non-default home is refused (exit 3)" test "$rc" = 3 -a "$(logn paseo.log)" = 0
fresh; del_line 110; ln -s "$FX_PHOME" "$FX_HOME/.paseo"
fx_gc report --apply > "$WORK/home3.txt" 2>&1; rc=$?
check "repair 6 / L2: with the Supervisor's env unreadable even the default ~/.paseo (resolved) is REFUSED (exit 3, nothing called) and the refusal is logged" bash -c "test '$rc' = 3 -a '$(logn paseo.log)' = 0 && grep -q 'not proven to serve this home' '$FX_STATE/actions.log' && grep -q 'not proven to serve this home' '$WORK/home3.txt'"

# identification without an env: the Supervisor holds its home's daemon.log open for writing (lsof -F fan)
sup_files() { printf 'f21\naw\nn%s\n' "$@" > "$FX_FIX/supfiles.110"; }
fresh; del_line 110; sup_files "$RP/daemon.log"
fx_gc report > "$WORK/lsof1.txt" 2>&1
check "ident/lsof: an unreadable Supervisor env is proven by its writable \$PHOME/daemon.log (identification ok, home via lsof)" grep -q 'identification: ok (Supervisor 110, home via lsof' "$WORK/lsof1.txt"
fresh; del_line 110; sup_files /elsewhere/.paseo/daemon.log
fx_gc report --apply > "$WORK/lsof2.txt" 2>&1; rc=$?
check "ident/lsof: only ANOTHER home's daemon.log is held: identification FAILED, --apply refused (exit 3), nothing called" bash -c "test '$rc' = 3 -a '$(logn paseo.log)' = 0 && grep -q 'identification: FAILED' '$WORK/lsof2.txt'"
fresh; del_line 110; sup_files "$RP/daemon.log" /elsewhere/.paseo/daemon.log
fx_gc report --apply > "$WORK/lsof3.txt" 2>&1; rc=$?
check "ident/lsof: the target home's AND another home's writable daemon.log (ambiguous): FAILED, refused (exit 3)" bash -c "test '$rc' = 3 -a '$(logn paseo.log)' = 0 && grep -q 'identification: FAILED' '$WORK/lsof3.txt'"
fresh; del_line 110; printf 'f21\nar\nn%s\n' "$RP/daemon.log" > "$FX_FIX/supfiles.110"
fx_gc report > "$WORK/lsof4.txt" 2>&1
check "ident/lsof: a read-only descriptor for daemon.log is not proof" grep -q 'identification: FAILED' "$WORK/lsof4.txt"
fresh; del_line 110
fx_gc report --apply > "$WORK/lsof5.txt" 2>&1; rc=$?
check "ident/lsof: no lsof entry at all: FAILED, refused (exit 3)" bash -c "test '$rc' = 3 -a '$(logn paseo.log)' = 0 && grep -q 'identification: FAILED' '$WORK/lsof5.txt'"
fresh; sup_files /elsewhere/.paseo/daemon.log
fx_gc report > "$WORK/lsof6.txt" 2>&1
check "ident/lsof: a readable env is authoritative (lsof is not consulted: identification ok via env even with another home's daemon.log listed)" grep -q 'identification: ok (Supervisor 110, home via env' "$WORK/lsof6.txt"

# C6: test isolation. Overrides for notifier/CLI/kill unset + logging osascript/paseo/kill first on PATH: none runs
fresh; : > "$FX_LOGS/osascript.log"
fx_gc_canary record > "$WORK/c6a.txt" 2>&1
fx_gc_canary tick > "$WORK/c6b.txt" 2>&1
fx_gc_canary report --apply --kill-stale-processes --kill-over-memory > "$WORK/c6c.txt" 2>&1
check "C6 canary: an alerting record/tick ran (alerts.log written) yet the logging osascript on PATH never ran" bash -c "test -s '$FX_STATE/alerts.log' && test '$(logn osascript.log)' = 0"
check "C6 canary: an --apply attempt with the kill flags ran the PATH paseo and kill zero times" bash -c "test '$(logn paseo.log)' = 0 && test '$(logn kill.log)' = 0"
fresh; printf '#!/bin/sh\necho "$*" >> "$SLPGC_LOGS/paseo-ambient.log"\n' > "$FX_BIN/paseo-ambient"; chmod +x "$FX_BIN/paseo-ambient"
FX_CANARY_PASEO_CLI="$FX_BIN/paseo-ambient"
fx_gc_canary record > "$WORK/c6d.txt" 2>&1
fx_gc_canary tick > "$WORK/c6e.txt" 2>&1
fx_gc_canary report --apply --kill-stale-processes --kill-over-memory > "$WORK/c6f.txt" 2>&1
unset FX_CANARY_PASEO_CLI
check "C6 canary: with the ambient PASEO_CLI set to a logging stub and SLP_GC_PASEO unset, an alerting record/tick and an --apply attempt never run it (nor the PATH paseo)" bash -c "test -s '$FX_STATE/alerts.log' && test '$(logn paseo-ambient.log)' = 0 && test '$(logn paseo.log)' = 0"
test_branch_has_ambient_cli() { sed -n '/^resolve_cli()/,/^  fi$/p' "$GC" | grep -qF 'ovr "${PASEO_CLI'; }
if test_branch_has_ambient_cli; then fail "C6: the test branch of resolve_cli reads the ambient PASEO_CLI (static)"; else ok "C6: the test branch of resolve_cli never reads the ambient PASEO_CLI (static)"; fi
check "C6: under SLP_GC_TEST=1 the notifier, CLI and kill fall back to inert no-ops (static)" bash -c "grep -q 'OSASCRIPT=\"\$INERT\"' '$GC' && grep -q 'KILL=\"\$INERT\"' '$GC' && grep -q 'an unset override is \"no CLI\"' '$GC'"

# --- (iii) kills ---------------------------------------------------------------------------------
fresh; nogc
fx_gc report --kill-stale-processes >/dev/null 2>&1; rc=$?
check "kill flags without --apply are refused (exit 2), nothing signalled" test "$rc" = 2 -a "$(logn kill.log)" = 0
fx_gc report --apply --kill-stale-processes --kill-over-memory > "$WORK/kill.txt" 2>&1; rc=$?
keep "$WORK/kill.txt" iii-kill-output.txt; keep "$FX_LOGS/kill.log" iii-stub-kill-argv.log; keep "$WORK/kill.txt" iii-kill-report.txt
check "kills signal exactly the launchd-reparented orphans (122, 190, slp-wait 130) and the bound over-threshold helper (GPU 102), SIGTERM only, single pids" test "$(kills)" = "-TERM 102 -TERM 122 -TERM 130 -TERM 190 "
check "repair 1: daemon-owned claude 121 (owner archived) is never signalled and is reported as daemon-owned" bash -c "! grep -q ' 121\$' '$FX_LOGS/kill.log' && grep -q 'daemon-owned' '$WORK/kill.txt'"
check "repair 2: a 20000 MB stream-json claude with a matching PASEO_HOME that is NOT under the daemon (195, parent 999) and a GPU helper under a different app main (201, 20000 MB) are not signalled" bash -c "! grep -qE ' (195|201)\$' '$FX_LOGS/kill.log' && grep -q 'not a direct child of the app main' '$WORK/kill.txt' && grep -q 'agent child itself is never memory-killed' '$WORK/kill.txt'"
check "never signalled: app main 100 (30000 MB), Supervisor 110 (20000 MB), daemon, invoker's agent 124, young 123/131/160, other-home 170, daemon-run children" bash -c "! grep -qE ' (100|110|111|112|120|121|123|124|131|140|150|160|170|180|195|200|201)\$' '$FX_LOGS/kill.log'"
check "a pid whose lstart changed between listing and signal (125) is skipped" grep -q '125 -> skipped (lstart' "$WORK/kill.txt"
check "no SIGKILL and no process-group signal was ever issued" bash -c "! grep -qE -- '-9|-KILL|-SIGKILL| -[0-9]+\$|--' '$FX_LOGS/kill.log'"
fresh; nogc; fx_gc report --apply --kill-stale-processes >/dev/null 2>&1
check "--kill-stale-processes alone signals only the orphans" test "$(kills)" = "-TERM 122 -TERM 130 -TERM 190 "
fresh; nogc; fx_gc report --apply --kill-over-memory >/dev/null 2>&1
check "--kill-over-memory alone signals only the over-threshold helper" test "$(kills)" = "-TERM 102 "
fresh; nogc; SLPGC_ADD_SELF=1 fx_gc report --apply --kill-stale-processes > "$WORK/self.txt" 2>&1
check "the process tree slp-gc runs in (an old ppid-1 claude that is its ancestor) is never signalled" bash -c "! grep -q ' 190\$' '$FX_LOGS/kill.log' && grep -q 'protected: in slp-gc' '$WORK/self.txt'"
fresh; nogc; FX_INVOKER=$A_LIVE fx_gc report --apply --kill-stale-processes >/dev/null 2>&1
check "processes of the invoking agent are protected whichever agent that is (invoker = A_LIVE: 122/125/130/190 stay)" bash -c "! grep -qE ' (122|125|130|190)\$' '$FX_LOGS/kill.log'"
fresh; nogc; del_line 122
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
fresh; nogc; printf '# comment\nSLP_GC_APPLY=1\nSLP_GC_KILL_STALE="1"\nEVIL=$(touch %s/pwned)\nSLP_GC_KILL_MEMORY=$(touch %s/pwned2)\n' "$WORK" "$WORK" > "$FX_SB/slp-gc.conf"
fx_gc tick >/dev/null 2>&1
check "tick config keys enable the kill phases individually; the file is parsed, never executed" bash -c "test \"\$(sort '$FX_LOGS/kill.log' | tr '\n' ' ')\" = '-TERM 122 -TERM 130 -TERM 190 ' && ! test -e '$WORK/pwned' && ! test -e '$WORK/pwned2'"
fresh; printf 'SLP_GC_APPLY=1\nSLP_GC_KILL_STALE=1\nSLP_GC_APPLY=0\n' > "$FX_SB/slp-gc.conf"; fx_gc tick >/dev/null 2>&1
check "repair 5: the last assignment wins (APPLY=1 then APPLY=0 => nothing applied, nothing killed)" test "$(logn paseo.log)" = 0 -a ! -f "$FX_LOGS/kill.log"
fresh; printf 'SLP_GC_APPLY=1\nSLP_GC_APPLY=yes\n' > "$FX_SB/slp-gc.conf"; fx_gc tick >/dev/null 2>&1
check "repair 5: a flag is on only when its final value is exactly 1 (yes/true/2 are off)" test "$(logn paseo.log)" = 0
fresh; nogc; printf 'SLP_GC_APPLY=1\nSLP_GC_KILL_MEMORY=1\nSLP_GC_MEM_KILL_MB=10\n' > "$FX_SB/slp-gc.conf"; fx_gc tick >/dev/null 2>&1
check "repair 5: SLP_GC_MEM_KILL_MB=10 is below the 1024 floor and falls back to 16384 (only the 20000 MB helper is signalled, not 200 MB processes)" test "$(kills)" = "-TERM 102 "
fresh; nogc; printf 'SLP_GC_MEM_WARN_MB=8000\nSLP_GC_MEM_KILL_MB=7000\nSLP_GC_APPLY=1\nSLP_GC_KILL_MEMORY=1\n' > "$FX_SB/slp-gc.conf"; fx_gc tick >/dev/null 2>&1
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
fresh; fx_gc_min tick >/dev/null 2>&1
check "tick works under a minimal environment (env -i, PATH=/usr/bin:/bin)" test -s "$FX_STATE/memory.jsonl"

# --- hardening ----------------------------------------------------------------------------------
fresh
fx_gc_bare report > "$WORK/notest.txt" 2>&1
check "L6: without SLP_GC_TEST=1 the probe/clock/CLI overrides are ignored (fixture processes never appear, identification fails, nothing is called)" bash -c "! grep -q 'Supervisor 110' '$WORK/notest.txt' && grep -q 'identification: FAILED' '$WORK/notest.txt' && test '$(logn paseo.log)' = 0 -a '$(logn kill.log)' = 0"
fresh; printf '%s\n' "$(cat "$FX_FIX/ps.txt")" "$(grep '^   111 ' "$FX_FIX/ps.txt")" > "$FX_FIX/ps.dup"; mv "$FX_FIX/ps.dup" "$FX_FIX/ps.txt"
fx_gc report --apply > "$WORK/dup.txt" 2>&1; rc=$?
check "L4: duplicate pid rows in the ps output fail identification and refuse --apply (exit 3)" bash -c 'test "$1" = 3 -a "$2" = 0 && grep -q "duplicate pid rows" "$3"' _ "$rc" "$(logn paseo.log)" "$WORK/dup.txt"
fresh; FX_EXTRA_ENV="SLP_GC_CLI_TIMEOUT=abc SLP_GC_MEM_WARN_MB=0800" fx_gc report > "$WORK/num.txt" 2>&1; rc=$?
check "L7/L13: an invalid SLP_GC_CLI_TIMEOUT falls back (exit 0); 0800 is read as decimal 800" bash -c "test '$rc' = 0 && grep -q 'warn >= 800 MB' '$WORK/num.txt'"
check "L2: uuid validation is newline-safe (a trailing newline or CR fails)" bash -c "eval \"\$(grep -E '^(UUID_RE|uuid_ok)' '$GC')\"; uuid_ok $A_GC1 && ! uuid_ok \"$A_GC1\$'\\n'\" && ! uuid_ok \"$A_GC1\$'\\r'\" && ! uuid_ok 'x'"
check "the bundle subcommand is gone: 'slp-gc bundle' is a usage error (exit 2) and no bundle code remains" bash -c "'$GC' bundle >/dev/null 2>&1; test \$? = 2 && ! grep -qiE 'do_bundle|tar -c|--since|REDACT_PL|DiagnosticReports' '$GC'"

# ====================================================================================================
# B1b: inspect proof, lineage ledger, orphaned agent descendants, memory guard, concurrency, heartbeats
# ====================================================================================================
# --- T1: the archived proof comes from `paseo agent inspect`, not `agent ls` -----------------------
# two candidates per run (A_GC1, A_GC2), each with its own inspect answer; the dependent schedules are removed to keep runs short
inspect_run() {  # inspect_run <GC1: archived at status id> -- <GC2 ...>; a lone "none" = no inspect answer (the CLI fails)
  fresh; del_line 120; rm -f "$FX_PHOME"/schedules/0000000[ab].json
  [ "$1" = none ] || set_inspect "$A_GC1" "$1" "$2" "$3" "$4"
  [ "$5" = none ] || set_inspect "$A_GC2" "$5" "$6" "$7" "$8"
  fx_gc report --apply > "$WORK/insp.txt" 2>&1
}
inspect_run true "$ARCH_AT" closed "" true "$ARCH_AT" running ""
check "T1 inspect success: Archived true + ArchivedAt + Status closed + matching Id => deleted, with the exact argv 'agent inspect --home <home> --json -- <uuid>'; 'agent ls' is never called" bash -c "grep -qx 'agent inspect --home $RP --json -- $A_GC1' '$FX_LOGS/paseo.log' && grep -q 'agent delete --home $RP -- $A_GC1' '$FX_LOGS/paseo.log' && test '$(agent_count "$A_GC1")' = 0 && ! grep -q 'agent ls' '$FX_LOGS/paseo.log'"
check "T1 inspect running: Status running => skipped, the record stays" bash -c "grep -qx 'agent inspect --home $RP --json -- $A_GC2' '$FX_LOGS/paseo.log' && ! grep -q 'agent delete --home $RP -- $A_GC2' '$FX_LOGS/paseo.log' && test '$(agent_count "$A_GC2")' = 1 && grep -q \"inspect' did not prove\" '$WORK/insp.txt'"
inspect_run false null closed "" true null closed ""
check "T1 inspect failure: Archived false, or Archived true with ArchivedAt null => skipped" bash -c "! grep -q 'agent delete' '$FX_LOGS/paseo.log' && test '$(agent_count "$A_GC1")' = 1 -a '$(agent_count "$A_GC2")' = 1"
inspect_run true "$ARCH_AT" closed "aaaaaaaa-0000-4000-8000-0000000000ee" none - - -
check "T1 inspect failure: Id differs from the requested uuid, or the CLI errors (no answer) => skipped" bash -c "! grep -q 'agent delete' '$FX_LOGS/paseo.log' && test '$(agent_count "$A_GC1")' = 1 -a '$(agent_count "$A_GC2")' = 1"
inspect_run true "$ARCH_AT" idle "" none - - -
check "L9/T1 inspect: Status must be exactly closed (the disk rule): an archived agent shown idle is skipped; the stub prints stderr noise on every call, which never reaches the JSON parser (success case above)" bash -c "! grep -q 'agent delete' '$FX_LOGS/paseo.log' && test '$(agent_count "$A_GC1")' = 1"
inspect_run true '"2020-01-01T00:00:00.000Z"' closed "" none - - -
check "#6/T1 inspect: ArchivedAt must agree with the freshly read record (a different timestamp => skipped)" bash -c "! grep -q 'agent delete' '$FX_LOGS/paseo.log' && test '$(agent_count "$A_GC1")' = 1"
fresh; del_line 120; rm -f "$FX_PHOME"/schedules/0000000[ab].json; set_inspect "$A_GC1" true "$ARCH_AT" closed; set_inspect "$A_GC2" true "$ARCH_AT" closed
SLPGC_PASEO_HANG=1 SLP_GC_CLI_TIMEOUT=1 fx_gc report --apply > "$WORK/insp-hang.txt" 2>&1
check "T1: the inspect call runs under the CLI timeout (a hung CLI stops the run after one attempt, nothing deleted)" bash -c "test \"\$(wc -l < '$FX_LOGS/paseo.log' | tr -d ' ')\" = 1 && test '$(agent_count "$A_GC1")' = 1"

# --- T2: the lineage ledger, written only by record/tick, only into the state dir -------------------
fresh; fx_lean; rm -f "$FX_STATE/lineage.tsv"
fx_snapshot "$FX_PHOME" > "$WORK/home.before"
fx_gc record >/dev/null 2>&1
fx_snapshot "$FX_PHOME" > "$WORK/home.after"
keep "$FX_STATE/lineage.tsv" t2-lineage.tsv
check "T2: record writes <state>/lineage.tsv: one row per process below a claude/codex child of the daemon (pid, lstart, comm, owner agent id, first-seen, orphaned-at) - 7 descendants below claude children, plus the two ppid-1 env-proof orphans (312, 350) with orphaned-at = now" bash -c "test -f '$FX_STATE/lineage.tsv' && awk -F'\t' 'NF == 7' '$FX_STATE/lineage.tsv' | wc -l | grep -q 9 && grep -q \"^300	Wed Sep 30 09:00:00 2026	node	$A_LIVE	$FX_NOW\" '$FX_STATE/lineage.tsv' && grep -q '^301	' '$FX_STATE/lineage.tsv' && grep -q '^140	' '$FX_STATE/lineage.tsv' && grep -q \"^312	Wed Sep 30 09:00:00 2026	node	$A_YOUNG	$FX_NOW	$FX_NOW\" '$FX_STATE/lineage.tsv'"
check "T2: no row for the daemon, agent children, helpers, orphans or anything outside the daemon's subtree" bash -c "! grep -qE '^(100|101|102|110|111|112|120|121|130|131|150|310|311|313)	' '$FX_STATE/lineage.tsv'"
check "T2/T7: record writes nothing into PASEO_HOME (snapshot identical) and makes zero paseo calls" bash -c "cmp -s '$WORK/home.before' '$WORK/home.after' && test '$(logn paseo.log)' = 0 && test '$(logn kill.log)' = 0"
check "T2: the ledger is written atomically (temp + mv in the state dir): no temp file is left" bash -c "test \"\$(ls -A '$FX_STATE' | grep -c '^.lineage\.')\" = 0"
# a claude child whose PASEO_AGENT_ID is unreadable => owner "pid:<childpid>@<lstart>"
fresh; fx_lean; rm -f "$FX_STATE/lineage.tsv"; del_line 120; fx_gc record >/dev/null 2>&1
check "T2: with the agent child's env unreadable the owner is pid:<childpid>@<lstart>" grep -q "^300	Wed Sep 30 09:00:00 2026	node	pid:120@Wed Sep 30 09:00:00 2026	" "$FX_STATE/lineage.tsv"
# pruning: dead rows go, live reparented rows stay, first-seen survives
fresh; fx_lean
printf '9999\tWed Sep 30 09:00:00 2026\tnode\t%s\t1789990000\n300\tWed Sep 30 09:00:00 2026\tnode\t%s\t1789000000\t0\n310\tWed Sep 30 09:00:00 2026\tnode\t%s\t1789990000\n310\tWed Sep 30 07:00:00 2026\tnode\t%s\t1789990000\t0\nnot a row\n' "$A_LIVE" "$A_LIVE" "$A_LIVE" "$A_LIVE" > "$FX_STATE/lineage.tsv"
fx_gc record >/dev/null 2>&1
check "T2 prune: a row whose pid+lstart no longer exists (dead pid 9999; pid 310 with another lstart; a malformed line) is dropped" bash -c "! grep -q '^9999	' '$FX_STATE/lineage.tsv' && ! grep -q 'Wed Sep 30 07:00:00' '$FX_STATE/lineage.tsv' && ! grep -q 'not a row' '$FX_STATE/lineage.tsv'"
check "T2 prune: a live process that left the subtree (reparented orphan 310) keeps its row - that row is the proof - and first-seen survives (300 keeps 1789000000); the orphaned-at of a row whose process now has ppid 1 is set to this tick (310)" bash -c "grep -q \"^310	Wed Sep 30 09:00:00 2026	node	$A_LIVE	1789990000	$FX_NOW	\" '$FX_STATE/lineage.tsv' && grep -q '^300	.*	1789000000	0	' '$FX_STATE/lineage.tsv'"
fresh; fx_lean; printf '301\tWed Sep 30 09:00:00 2026\tnode\t%s\t1789000001\t0\n300\tWed Sep 30 09:00:00 2026\tnode\t%s\t1789000000\t0\n' "$A_LIVE" "$A_LIVE" > "$FX_STATE/lineage.tsv"
FX_EXTRA_ENV="SLP_GC_LEDGER_CAP=2" fx_gc record >/dev/null 2>&1
check "T2 cap: the ledger is cut to the cap (test cap 2), oldest first-seen dropped (300 first-seen 100 and 301 first-seen 200 go; only rows first seen now stay)" bash -c "test \"\$(wc -l < '$FX_STATE/lineage.tsv' | tr -d ' ')\" = 2 && ! grep -q '^30[01]	' '$FX_STATE/lineage.tsv' && test \"\$(awk -F'\t' '\$5 != $FX_NOW' '$FX_STATE/lineage.tsv' | wc -l | tr -d ' ')\" = 0"
check "T2 cap: the production cap is 5000 rows (static)" grep -q 'LEDGER_CAP=5000' "$GC"
# symlinks are never followed
fresh; fx_lean; mv "$FX_STATE/lineage.tsv" "$WORK/real-ledger.tsv"; ln -s "$WORK/real-ledger.tsv" "$FX_STATE/lineage.tsv"; cp "$WORK/real-ledger.tsv" "$WORK/real-ledger.copy"
fx_gc report > "$WORK/sym.txt" 2>&1
check "T2 symlink: a lineage.tsv that is a symlink is not read (the ledger-only orphans 310/314 are not even listed)" bash -c "! grep -qE '^ +(310|314) ' '$WORK/sym.txt' && grep -q 'LEDGER: lineage.tsv is not a regular file' '$WORK/sym.txt'"
fx_gc record >/dev/null 2>&1
check "T2 symlink: record replaces the symlink with a regular file and never writes through it" bash -c "test ! -L '$FX_STATE/lineage.tsv' && test -f '$FX_STATE/lineage.tsv' && cmp -s '$WORK/real-ledger.tsv' '$WORK/real-ledger.copy'"

# --- T3: orphaned agent descendants ------------------------------------------------------------------
fresh; fx_lean
fx_snapshot "$WORK/sb" > "$WORK/snap3.before"
fx_gc report > "$WORK/orph.txt" 2>&1; fx_gc report --json > "$WORK/orph.json" 2>&1
fx_snapshot "$WORK/sb" > "$WORK/snap3.after"; keep "$WORK/orph.txt" t3-orphan-report.txt
check "T7 report is read-only with the ledger and orphan fixtures present (snapshot of the whole sandbox identical, no paseo call, no signal)" bash -c "cmp -s '$WORK/snap3.before' '$WORK/snap3.after' && test '$(logn paseo.log)' = 0 && test '$(logn kill.log)' = 0"
check "T3: report always shows the orphan category with memory and owner: ledger orphan 310 (4500 MB, owner not live, orphaned 1 h ago) is an ORPHAN; env-proof orphan 312 is listed but waits for its orphaned-at" bash -c "grep -q '== (a2) orphaned agent descendants' '$WORK/orph.txt' && grep -E '^ +310 .*owner aaaaaaaa .*4500(\.0)? MB.*proof ledger.*ORPHAN' '$WORK/orph.txt' && grep -E '^ +312 .*owner aaaaaaaa .*2000(\.0)? MB.*proof env' '$WORK/orph.txt' | grep -qv ORPHAN && grep -A1 -E '^ +312 ' '$WORK/orph.txt' | grep -q 'real executable path not recorded'"
check "N2/T7: a nohup dev server with ppid 1 whose owner agent is still live (350, owner A_LIVE with a running claude child) is listed as NOT an orphan" bash -c "grep -E '^ +350 ' '$WORK/orph.txt' | grep -qv ORPHAN && grep -A1 -E '^ +350 ' '$WORK/orph.txt' | grep -q 'treated as LIVE'"
check "T3: OrbStack-like /Applications/OrbStack.app ppid-1 process with PASEO env is reported as PROTECTED, not an orphan" bash -c "grep -E '^ +313 .*PROTECTED' '$WORK/orph.txt' | grep -qv ORPHAN && grep -A1 -E '^ +313 ' '$WORK/orph.txt' | grep -q 'inside an .app bundle'"
check "T3: young (5 min < 10), non-allowlisted comm, other-home and no-provenance processes are not proven orphans" bash -c "grep -A1 -E '^ +314 ' '$WORK/orph.txt' | grep -q 'orphaned 300s ago < 600s' && grep -A1 -E '^ +315 ' '$WORK/orph.txt' | grep -q '(comm \"mytool\") is not in SLP_GC_KILL_COMMS' && ! grep -qE '^ +(316|317|311) ' '$WORK/orph.txt'"
check "T3: the cwd hint is shown (supporting, never proof) for a listed orphan whose cwd is under the Paseo worktrees dir" bash -c "grep -q 'hint (never proof): cwd .*worktrees/abcd1234/dirty (under the Paseo worktrees dir)' '$WORK/orph.txt'"
check "T3: --json exposes .procs.orphans (without command lines) and the tree" bash -c "jq -e '(.procs.orphans | length) == 6 and (.procs.orphans | all(has(\"cmd\") | not)) and .procs.tree.totalMb > 0' '$WORK/orph.json'"

fresh; fx_lean
fx_gc report --apply --kill-stale-processes --kill-over-memory > /dev/null 2>&1; MEMKILLS="$(kills)"
fresh; fx_lean
fx_gc report --apply --kill-stale-processes > "$WORK/o2.txt" 2>&1
keep "$WORK/o2.txt" t3-orphan-kill-output.txt; keep "$FX_LOGS/kill.log" t3-orphan-kill-argv.log
check "T3/T7 the retitled orphan 'node (vitest 3)' with an EMPTY env but a ledger match (310) is killed under the kill flag, (owner not live, orphaned an hour ago); SIGTERM, single pid; the env-proof orphan 312 has no orphaned-at yet and waits" test "$(kills)" = "-TERM 310 "
check "T7 the same pid with a different lstart (311: ledger lstart differs) is not killed" bash -c "! grep -qE ' 311\$' '$FX_LOGS/kill.log'"
check "T7 OrbStack (313, .app bundle, PASEO env, 9000 MB) is never killed, not even with --kill-over-memory" bash -c "! grep -qE ' 313\$' '$FX_LOGS/kill.log' && [[ '$MEMKILLS' != *' 313 '* ]]"
check "T7/N2 an orphan orphaned for less than the minimum (314: 5 min), a non-allowlisted comm (315), the nohup server with a live owner (350), no-provenance 317 and other-home 316 are not killed" bash -c "! grep -qE ' (314|315|316|317|350)\$' '$FX_LOGS/kill.log'"
# env-proof orphan: record stamps its orphaned-at, the minimum is measured from it
fresh; fx_lean; rm -f "$FX_STATE/lineage.tsv"; fx_gc record >/dev/null 2>&1
fx_gc report --apply --kill-stale-processes > "$WORK/e2e1.txt" 2>&1; K1="$(kills)"
FX_EXTRA_ENV="SLP_GC_NOW=$((FX_NOW + 700))" fx_gc report --apply --kill-stale-processes > "$WORK/e2e2.txt" 2>&1
check "N2/T7 an env-proof orphan (312) is not killed right after record stamped its orphaned-at (0 s < 600 s), and IS killed 700 s later; the live-owner server 350 never" bash -c "test -z '$K1' && grep -qE ' 312\$' '$FX_LOGS/kill.log' && ! grep -qE ' 350\$' '$FX_LOGS/kill.log'"
# eligibility overrides are checked on the report (WOULD SIGTERM = the same predicate the kill loop uses; the kill loop itself is exercised above)
fresh; fx_lean
FX_EXTRA_ENV="SLP_GC_ORPHAN_COMMS=mytool" fx_gc report > "$WORK/cfg1.txt" 2>&1
FX_EXTRA_ENV="SLP_GC_KILL_COMMS=mytool" fx_gc report > "$WORK/cfg1b.txt" 2>&1
check "N1/T3: SLP_GC_KILL_COMMS (and its old alias SLP_GC_ORPHAN_COMMS) is configurable (mytool: 315 would now be killed, the node orphan 310 would not)" bash -c "grep -qE 'WOULD SIGTERM pid 315 ' '$WORK/cfg1.txt' && ! grep -qE 'WOULD SIGTERM pid 310 ' '$WORK/cfg1.txt' && grep -qE 'WOULD SIGTERM pid 315 ' '$WORK/cfg1b.txt' && ! grep -qE 'WOULD SIGTERM pid 310 ' '$WORK/cfg1b.txt'"
FX_EXTRA_ENV="SLP_GC_ORPHAN_MIN_AGE_MIN=2" fx_gc report > "$WORK/cfg2.txt" 2>&1
check "T3: SLP_GC_ORPHAN_MIN_AGE_MIN is configurable (2 min: the 5-minute-old ledger orphan 314 would now be killed)" grep -qE 'WOULD SIGTERM pid 314 ' "$WORK/cfg2.txt"
# the ordered ps identity re-read: the row changes after the evaluation
fresh; fx_lean; sed 's/^\(   310 .*\)node (vitest 3)$/\1node (vitest 9)/' "$FX_FIX/ps.txt" > "$FX_FIX/ps.recheck"
fx_gc report --apply --kill-stale-processes > "$WORK/o3.txt" 2>&1
check "T3: the ps identity is re-read right before the kill (a changed command line on 310 => skipped)" bash -c "! grep -qE ' 310\$' '$FX_LOGS/kill.log' && grep -q '310 -> skipped' '$WORK/o3.txt'"
fresh; fx_lean; FX_INVOKER=$A_YOUNG fx_gc report --apply --kill-stale-processes > "$WORK/inv.txt" 2>&1
check "T3: orphans of the invoking agent are protected (invoker = their owner: 310 stays)" bash -c "! grep -qE ' 310\$' '$FX_LOGS/kill.log' && grep -q 'protected: belongs to the invoking agent' '$WORK/inv.txt'"
fresh; fx_lean; rm -f "$FX_STATE/lineage.tsv"; fx_gc report > "$WORK/nol.txt" 2>&1
check "T3: without the ledger the empty-env orphan 310 has no proof (not listed) while the env-proof orphan 312 is listed (waiting for its orphaned-at)" bash -c "! grep -qE '^ +310 ' '$WORK/nol.txt' && grep -qE '^ +312 ' '$WORK/nol.txt' && ! grep -qE 'WOULD SIGTERM pid 312 ' '$WORK/nol.txt'"

# --- T4: memory guard ---------------------------------------------------------------------------------
fresh; fx_lean
fx_gc report > "$WORK/mem0.txt" 2>&1
check "T4 defaults: warn 3072 MB, kill 4096 MB, tree warn 50% of RAM (16384 MB from the stub sysctl => 8192)" bash -c "grep -q 'warn >= 3072 MB, memory-kill > 4096 MB' '$WORK/mem0.txt' && grep -q 'warn >= 8192 MB (50% of 16384 MB RAM)' '$WORK/mem0.txt'"
check "T4: the report shows the tree total (app subtree + proven orphans), per-agent subtree totals and the orphan total" bash -c "grep -q '== (a3) Paseo tree memory' '$WORK/mem0.txt' && grep -q 'proven orphans 4500' '$WORK/mem0.txt' && grep -q 'per-agent subtree totals (top 10' '$WORK/mem0.txt' && grep -qE '^ +aaaaaaaa +claude-child +processes' '$WORK/mem0.txt' && grep -q '!!TREE-WARN' '$WORK/mem0.txt'"
fresh; fx_lean; SLPGC_MEMSIZE=549755813888 fx_gc report > "$WORK/mem1.txt" 2>&1
check "T4: RAM comes from hw.memsize (overridable in tests): with 512 GiB the tree warn is 256 GiB and no TREE-WARN" bash -c "grep -q '50% of 524288 MB RAM' '$WORK/mem1.txt' && ! grep -q '!!TREE-WARN' '$WORK/mem1.txt'"
# kill eligibility
fresh; fx_lean
sed -i.b 's/^120    200M   30M/120    9000M  30M/; s/^111    150M   20M/111    5000M  20M/' "$FX_FIX/top.txt"
fx_gc report --apply --kill-over-memory > "$WORK/mem2.txt" 2>&1
keep "$WORK/mem2.txt" t4-memory-kill-output.txt; keep "$FX_LOGS/kill.log" t4-memory-kill-argv.log
check "T4/T7 a vitest worker under a live agent over the kill threshold (300, 5000 MB), a proven orphan over it (310, 4500 MB) and the GPU helper (102) are killed, SIGTERM, only with --kill-over-memory" test "$(kills)" = "-TERM 102 -TERM 300 -TERM 310 "
check "N1/L5: over-threshold workers under an agent that are NOT killable: an Xcode swift-frontend inside an .app (340), a non-allowlisted comm (341), an allowlisted node inside an .app (343) are report-only; a benign argv whose real executable is inside an .app (342) is refused at kill time" bash -c "! grep -qE ' (340|341|343)\$' '$FX_LOGS/kill.log' && ! grep -qE ' 342\$' '$FX_LOGS/kill.log' && grep -q 'executable inside an .app bundle' '$WORK/mem2.txt' && grep -q 'comm \"mytool\" is not in SLP_GC_KILL_COMMS' '$WORK/mem2.txt' && grep -q '342 -> skipped (executable path /Applications/Foo.app/Contents/MacOS/node is inside an .app bundle' '$WORK/mem2.txt'"
check "T7 the claude parent (120, 9000 MB) is never killed: 'an agent child itself is never memory-killed'" bash -c "! grep -qE ' 120\$' '$FX_LOGS/kill.log' && grep -q 'agent child itself is never memory-killed' '$WORK/mem2.txt'"
check "T7 the daemon over the threshold (111, 5000 MB) is reported, not killed" bash -c "! grep -qE ' 111\$' '$FX_LOGS/kill.log' && grep -qE 'daemon: pid 111 footprint 5000(\.0)? MB \(report-only' '$WORK/mem2.txt' && grep -q 'the daemon is never memory-killed' '$WORK/mem2.txt'"
check "T4: never killed by memory: app main 100, Supervisor 110, OrbStack 313 (9000 MB), a sub-threshold worker 301, orphans below the threshold (312, 2000 MB)" bash -c "! grep -qE ' (100|110|313|301|312)\$' '$FX_LOGS/kill.log'"
fresh; fx_lean; fx_gc report --apply > /dev/null 2>&1
check "T3/T4: --apply without the kill flags sends no signal at all (orphans and over-memory processes are only reported)" test "$(logn kill.log)" = 0
# a worker under a claude child that is NOT under the identified daemon stays report-only
fresh; fx_lean; fx_psrow 320 195 01:00:00 20000000 "Wed Sep 30 09:00:00 2026" "node (vitest 3)" >> "$FX_FIX/ps.txt"; echo '320    20000M 50M' >> "$FX_FIX/top.txt"
fx_gc report > "$WORK/mem3.txt" 2>&1
check "repair 2 (descendants): a 20000 MB worker below a claude child that is not under the identified daemon (320 under 195) is report-only" bash -c "! grep -qE 'WOULD SIGTERM pid 320 ' '$WORK/mem3.txt' && grep -q 'not a descendant of the identified daemon' '$WORK/mem3.txt'"
# config: last wins, floor, tree
fresh; fx_lean; printf 'SLP_GC_APPLY=1\nSLP_GC_KILL_MEMORY=1\nSLP_GC_MEM_KILL_MB=6000\nSLP_GC_MEM_KILL_MB=4000\n' > "$FX_SB/slp-gc.conf"; fx_gc tick >/dev/null 2>&1
check "T4 config: SLP_GC_MEM_KILL_MB last assignment wins (4000: the 4500 MB orphan 310 and the 5000 MB worker 300 go; 6000 would spare 310)" test "$(kills)" = "-TERM 102 -TERM 300 -TERM 310 "
fresh; fx_lean; FX_EXTRA_ENV="SLP_GC_MEM_KILL_MB=500" fx_gc report > "$WORK/floor.txt" 2>&1
check "T4 config: a kill threshold below the 1024 floor falls back to the 4096 default" grep -q 'memory-kill > 4096 MB' "$WORK/floor.txt"

# --- T4: record alerts ----------------------------------------------------------------------------------
fresh; fx_lean; FX_EXTRA_ENV="SLP_GC_MEM_WARN_MB=999999 SLP_GC_MEM_KILL_MB=999999" fx_gc record >/dev/null 2>&1
keep "$FX_STATE/alerts.log" t4-record-alerts.log
check "T4/T7 record alerts on the tree total and on a proven orphan > 1024 MB even when no single process passes warn: one alerts.log line, one notification" bash -c "test \$(wc -l < '$FX_STATE/alerts.log') = 1 && grep -q 'ALERT Paseo tree' '$FX_STATE/alerts.log' && grep -qE 'orphaned agent descendant\(s\) > 1024 MB: node pid 310 4500(\.0)? MB' '$FX_STATE/alerts.log' && test \$(wc -l < '$FX_LOGS/osascript.log') = 1"
check "T4: record's sample carries the tree totals, per-agent totals and the orphans (no command lines)" bash -c "jq -e '.tree.totalMb > 0 and (.tree.agents | length) > 0 and (.orphans | map(select(.proven)) | length) == 1 and .tree.orphanMb == 4500' '$FX_STATE/memory.jsonl' && ! grep -q 'vitest' '$FX_STATE/memory.jsonl'"
fx_gc record >/dev/null 2>&1
check "T4: alerts are rate-limited (a second record within 15 min appends a sample, no second alert or notification)" bash -c "test \$(wc -l < '$FX_STATE/memory.jsonl') = 2 && test \$(wc -l < '$FX_STATE/alerts.log') = 1 && test \$(wc -l < '$FX_LOGS/osascript.log') = 1"
fresh; fx_lean; sed -i.b 's/^310    4500M/310    900M/; s/^312    2000M/312    900M/; s/^314    5000M/314    100M/' "$FX_FIX/top.txt"
FX_EXTRA_ENV="SLP_GC_MEM_WARN_MB=999999 SLP_GC_MEM_KILL_MB=999999" SLPGC_MEMSIZE=549755813888 fx_gc record >/dev/null 2>&1
check "T4: no alert when the tree is under tree-warn, no process passes warn and no proven orphan exceeds 1024 MB" bash -c "test ! -e '$FX_STATE/alerts.log' && test ! -e '$FX_LOGS/osascript.log'"

# --- T5: concurrency -------------------------------------------------------------------------------------
fresh; fx_lean
fx_gc report > "$WORK/conc1.txt" 2>&1
check "T5: one agent with a test-runner subtree (120: workers 300 and 301) => counted with workers and memory, no warning" bash -c "grep -q '== (a4) test-runner concurrency (report-only): 1 agent(s)' '$WORK/conc1.txt' && grep -qE '^ +aaaaaaaa +test-runner processes +2 +5500 MB' '$WORK/conc1.txt' && ! grep -q '!!CONCURRENCY-WARN' '$WORK/conc1.txt'"
fresh; fx_lean
{ fx_psrow 330 180 01:00:00 100000 "Wed Sep 30 09:00:00 2026" "node (vitest 1)"; fx_psrow 331 160 01:00:00 100000 "Wed Sep 30 09:00:00 2026" "node /x/node_modules/.bin/jest --ci"
  fx_psrow 332 121 01:00:00 100000 "Wed Sep 30 09:00:00 2026" "python -m pytest tests"; fx_psrow 333 120 01:00:00 100000 "Wed Sep 30 09:00:00 2026" "node /x/mocha/bin/mocha.js"; } >> "$FX_FIX/ps.txt"
printf '%s\n' '330    100M   10M' '331    100M   10M' '332    100M   10M' '333    100M   10M' >> "$FX_FIX/top.txt"
fx_gc report > "$WORK/conc2.txt" 2>&1
check "T5: more than SLP_GC_TEST_CONCURRENCY_WARN (3) agents running test suites => !!CONCURRENCY-WARN with the count (4 agents: 120, 180, 160, 121)" bash -c "grep -q '4 agent(s) with vitest/jest/pytest/mocha/playwright subtrees (warn when > 3)   !!CONCURRENCY-WARN' '$WORK/conc2.txt'"
FX_EXTRA_ENV="SLP_GC_TEST_CONCURRENCY_WARN=4" fx_gc report > "$WORK/conc3.txt" 2>&1
check "T5: the concurrency warning threshold is configurable (4: 4 agents no longer warn); report-only, nothing was signalled" bash -c "! grep -q '!!CONCURRENCY-WARN' '$WORK/conc3.txt' && test '$(logn kill.log)' = 0 && test '$(logn paseo.log)' = 0"

# --- T6: heartbeat health --------------------------------------------------------------------------------
fresh
jq '.runs[0].error = "boom" | .runs[1].startedAt = "2026-09-20T00:00:00.000Z" | .runs[1].scheduledFor = "2026-09-20T00:00:00.000Z"' "$FX_PHOME/schedules/0000000a.json" > "$WORK/s.json" && mv "$WORK/s.json" "$FX_PHOME/schedules/0000000a.json"
fx_gc report > "$WORK/hb.txt" 2>&1
check "T6: per schedule, runs[] length, failures in the last 24 h and the share of 'already has an active run' (0000000c: 50 runs, 50 failures, 100%)" bash -c "grep -A3 '^  0000000c ' '$WORK/hb.txt' | grep -q 'heartbeat health: runs\[\] 50, failures in the last 24 h 50, \"already has an active run\" share 100%'"
check "T6: a failure older than 24 h is not counted and a different error is not an 'active run' failure (0000000a: 2 runs, 1 failure in 24 h, 0%)" bash -c "grep -A3 '^  0000000a ' '$WORK/hb.txt' | grep -q 'heartbeat health: runs\[\] 2, failures in the last 24 h 1, \"already has an active run\" share 0%'"

# --- fix round: N3 (caps, one recheck per batch, tick budget), L1-L8, F7 ---------------------------------------
sedtop() { sed -i.b "$1" "$FX_FIX/top.txt"; rm -f "$FX_FIX/top.txt.b"; }
fresh; fx_lean
FX_EXTRA_ENV="SLP_GC_MAX_KILLS=1" fx_gc report --apply --kill-over-memory > "$WORK/cap.txt" 2>&1
check "N3: SLP_GC_MAX_KILLS caps the signals per run (1 of the 3 eligible: 102, 300, 310) and the rest is logged as deferred" bash -c "test \"\$(wc -l < '$FX_LOGS/kill.log' | tr -d ' ')\" = 1 && grep -q 'SLP_GC_MAX_KILLS=1 reached' '$WORK/cap.txt'"
fresh; fx_lean
# shellcheck disable=SC2034  # read by sandbox.sh (fx_gc)
FX_TRACE=1
fx_gc report --apply --kill-over-memory > "$WORK/batch.txt" 2>&1
check "X1/N3: every kill is preceded by its own full recheck (the claude child's env is read 5 times: the evaluation + 4 rechecks for the 4 candidates: 102, 300, 342 refused at the exe check, 310)" bash -c "test \"\$(grep -cx 120 '$FX_LOGS/psenv.log')\" = 5 && test \"\$(wc -l < '$FX_LOGS/kill.log' | tr -d ' ')\" = 3"
check "L3/L4: the rechecks skip the wide env reads and the cwd hints (OrbStack 313's env and the lsof cwd calls happen once, in the evaluation)" bash -c "test \"\$(grep -cx 313 '$FX_LOGS/psenv.log')\" = 1 && test \"\$(wc -l < '$FX_LOGS/lsof-cwd.log' | tr -d ' ')\" = 6"
check "L1: only class-matched rows have their env read (the Supervisor 110, claude 120, ppid-1 candidates); a worker whose path merely says .paseo (360) is not; pool of 4 and a 3 s per-pid alarm in production (static)" bash -c "grep -qx 120 '$FX_LOGS/psenv.log' && grep -qx 110 '$FX_LOGS/psenv.log' && ! grep -qx 360 '$FX_LOGS/psenv.log' && grep -q 'ENV_JOBS=4' '$GC' && grep -q 'run_to 3 \"\$PSENV\"' '$GC'"
# tick budget: a slow top makes the record itself take > 1 s, so the apply phase is skipped and logged; the sample is still written
fresh; fx_lean; printf 'SLP_GC_APPLY=1\nSLP_GC_KILL_MEMORY=1\nSLP_GC_TICK_BUDGET_S=1\n' > "$FX_SB/slp-gc.conf"
FX_EXTRA_ENV="SLP_GC_TOP=$FX_BIN/top-slow" fx_gc tick > "$WORK/budget.txt" 2>&1
check "R2/N3: a record that uses the whole tick budget (1 s budget, 2 s top) does NOT starve the kill phase: the sample is written and the kills still run in the reserved window (hard cap 20 s), which is logged" bash -c "test -s '$FX_STATE/memory.jsonl' && test \"\$(wc -l < '$FX_LOGS/kill.log' | tr -d ' ')\" -ge 1 && grep -q 'reserved 20 s window' '$FX_STATE/tick.log'"
fresh; printf 'SLP_GC_APPLY=1\nSLP_GC_TICK_BUDGET_S=1\n' > "$FX_SB/slp-gc.conf"
FX_EXTRA_ENV="SLP_GC_TOP=$FX_BIN/top-slow" fx_gc tick > "$WORK/budget2.txt" 2>&1
check "R2/N3: without kill flags an exhausted budget skips the whole apply phase (nothing is deleted) and says so" bash -c "test -s '$FX_STATE/memory.jsonl' && test '$(logn paseo.log)' = 0 && grep -q 'expired after record' '$FX_STATE/tick.log' && grep -q 'budget' '$WORK/budget2.txt'"
# R3: readable Supervisor env without PASEO_HOME is accepted for the default home only; an unreadable env always refuses (see repair 6 / L2)
fresh; sed -i.b "s#^  110 Paseo Supervisor PATH=/usr/bin PASEO_HOME=.*#  110 Paseo Supervisor PATH=/usr/bin#" "$FX_FIX/env.txt"; ln -s "$FX_PHOME" "$FX_HOME/.paseo"
fx_gc report --apply > "$WORK/r3a.txt" 2>&1; rc=$?
check "R3: a readable Supervisor env without PASEO_HOME is accepted for the default ~/.paseo (--apply runs: exit 0, 4 deletes)" test "$rc" = 0 -a "$(logn paseo.log)" = 4
fresh; sed -i.b "s#^  110 Paseo Supervisor PATH=/usr/bin PASEO_HOME=.*#  110 Paseo Supervisor PATH=/usr/bin#" "$FX_FIX/env.txt"
fx_gc report --apply > "$WORK/r3b.txt" 2>&1; rc=$?
check "R3: the same readable env without PASEO_HOME is refused for a non-default home (exit 3, nothing called)" test "$rc" = 3 -a "$(logn paseo.log)" = 0
# R1: the owner is LIVE unless provably dead
fresh; fx_lean; fx_more; del_line 120
fx_gc report --apply --kill-stale-processes --kill-over-memory > "$WORK/r1a.txt" 2>&1
check "R1: with an agent-class process whose env is unreadable (env-blind) NO orphan is killed, not even one whose owner is archived (310) or by memory; the nohup dev server of a live agent (350) neither" bash -c "! grep -qE ' (310|312|350|351|352|374)\$' '$FX_LOGS/kill.log' && grep -q 'treated as LIVE' '$WORK/r1a.txt'"
fresh; fx_lean; fx_more
fx_gc report > "$WORK/r1b.txt" 2>&1
check "R1: an owner in state unknown (374: no record, and the sandbox has unreadable agent records) is treated as live and not proven; a live idle agent (371, unarchived, no child) too" bash -c "grep -A1 -E '^ +374 ' '$WORK/r1b.txt' | grep -q 'treated as LIVE' && grep -A1 -E '^ +371 ' '$WORK/r1b.txt' | grep -q 'treated as LIVE' && ! grep -qE 'WOULD SIGTERM pid (374|371) ' '$WORK/r1b.txt'"
check "R1: an archived owner (310, A_YOUNG) is dead: the orphan is proven and killed - only with the kill flag (see the T3/T7 check above)" grep -qE 'WOULD SIGTERM pid 310 ' "$WORK/r1b.txt"
# X1: the owner becomes live between two kills of the same batch: the second kill must not happen
fresh; fx_lean; fx_more
printf '#!/bin/sh\nf=$(find "$PASEO_HOME/agents" -name "%s.json" | head -n 1); jq ".archivedAt = null" "$f" > "$f.t" && mv "$f.t" "$f"\n' "$A_YOUNG" > "$FX_FIX/after-kill.sh"; chmod +x "$FX_FIX/after-kill.sh"
fx_gc report --apply --kill-stale-processes > "$WORK/x1a.txt" 2>&1
check "X1: the owner (A_YOUNG) is un-archived after the first kill of a batch (310): the second orphan of the same owner (375) is re-evaluated and NOT killed" bash -c "grep -qE ' 310\$' '$FX_LOGS/kill.log' && ! grep -qE ' (375|319)\$' '$FX_LOGS/kill.log' && grep -q '375 -> skipped (no longer eligible' '$WORK/x1a.txt'"
# X2: a live agent child carrying the owner's PASEO_AGENT_ID protects the owner although its record says archived
fresh; fx_lean; fx_more
fx_gc report > "$WORK/x2a.txt" 2>&1
check "X2: an orphan whose owner record is archived (A_STALE) but a live agent child (121) still carries that PASEO_AGENT_ID is treated as live" bash -c "grep -A1 -E '^ +376 ' '$WORK/x2a.txt' | grep -q 'treated as LIVE' && ! grep -qE 'WOULD SIGTERM pid 376 ' '$WORK/x2a.txt'"
# X3: ledger and env disagree about the owner
check "X3: the ledger says archived owner A_YOUNG but the current env says the live agent A_LIVE (377, same pid, lstart, exe) => no proof, not killed" bash -c "grep -A1 -E '^ +377 ' '$WORK/x2a.txt' | grep -q 'contradicts the ledger owner' && ! grep -qE 'WOULD SIGTERM pid 377 ' '$WORK/x2a.txt'"

# F7: quiet tick
fresh; FX_EXTRA_ENV="SLP_GC_MEM_WARN_MB=999999 SLP_GC_MEM_KILL_MB=999999 SLP_GC_TREE_WARN_MB=99999999" fx_gc tick > "$WORK/quiet.txt" 2>&1
check "F7: a tick on the normal path prints nothing (stdout/stderr empty) but writes the sample, the report and tick.log" bash -c "! test -s '$WORK/quiet.txt' && test -s '$FX_STATE/memory.jsonl' && test \"\$(ls '$FX_STATE/reports' | wc -l | tr -d ' ')\" = 1"
fresh; fx_gc tick > "$WORK/alert.txt" 2>&1
check "F7: a tick prints on alerts (the ALERT line) and on errors only" grep -q ' ALERT ' "$WORK/alert.txt"
fresh; head -c 1100000 /dev/zero | tr '\0' x > "$FX_STATE/launchd.log"; fx_gc tick >/dev/null 2>&1
check "F7: <state>/launchd.log is rotated at the start of a tick (1 MiB, one predecessor)" bash -c "test -f '$FX_STATE/launchd.log.1' && test \"\$(wc -c < '$FX_STATE/launchd.log.1' | tr -d ' ')\" = 1100000"
fresh; fx_gc --help > "$WORK/help.txt" 2>&1
check "F7: --help shows the new defaults (MEM_WARN 3072, MEM_KILL 4096, TREE_WARN 50% of RAM) and the new keys" bash -c "cat '$WORK/help.txt' | grep -q 'SLP_GC_MEM_WARN_MB\[3072\]' && cat '$WORK/help.txt' | grep -q 'SLP_GC_MEM_KILL_MB\[4096' && cat '$WORK/help.txt' | grep -q 'SLP_GC_TREE_WARN_MB\[50% of RAM\]' && cat '$WORK/help.txt' | grep -q 'SLP_GC_MAX_KILLS\[10' && cat '$WORK/help.txt' | grep -q 'SLP_GC_TICK_BUDGET_S\[45\]'"
# L7: actions.log rotation
fresh; head -c 1048540 /dev/zero | tr '\0' x > "$FX_STATE/actions.log"; fx_gc report --apply >/dev/null 2>&1
check "L7: actions.log is rotated (1 MiB, one predecessor)" bash -c "test -f '$FX_STATE/actions.log.1' && test \"\$(wc -c < '$FX_STATE/actions.log' | tr -d ' ')\" -lt 100000"
# L6: the ledger and the state dir must be ours: uid + 0600 / 0700
fresh; fx_lean; chmod 644 "$FX_STATE/lineage.tsv"; fx_gc report > "$WORK/l6a.txt" 2>&1
check "L6: a ledger that is not mode 0600 is ignored (fail closed): the ledger orphans are not listed and the report says why" bash -c "! grep -qE '^ +(310|314) ' '$WORK/l6a.txt' && grep -q 'LEDGER: lineage.tsv is not owned by uid .* with mode 0600' '$WORK/l6a.txt'"
chmod 600 "$FX_STATE/lineage.tsv"; chmod 755 "$FX_STATE"; fx_gc report > "$WORK/l6b.txt" 2>&1
check "L6: a state dir that is not mode 0700 makes the ledger untrusted too" bash -c "! grep -qE '^ +310 ' '$WORK/l6b.txt' && grep -q 'LEDGER: state dir is not owned by uid .* with mode 0700' '$WORK/l6b.txt'"
fx_gc record >/dev/null 2>&1; fx_gc report > "$WORK/l6c.txt" 2>&1
check "L6: record tightens its own state dir to 0700 and the ledger is trusted again" bash -c "grep -qE '^ +310 .*ORPHAN' '$WORK/l6c.txt' && ! grep -q 'LEDGER:' '$WORK/l6c.txt'"
# L8: memory.jsonl keeps the top 30 processes + per-class totals + the tree total
fresh; fx_lean; for i in 1 2 3 4 5 6 7 8; do fx_psrow $((400 + i)) 120 01:00:00 1000 "Wed Sep 30 09:00:00 2026" "node w$i" >> "$FX_FIX/ps.txt"; echo "$((400 + i))    $((50 + i))M   1M" >> "$FX_FIX/top.txt"; done
fx_gc record >/dev/null 2>&1
check "L8: memory.jsonl keeps the top 30 processes by footprint plus per-class totals and the tree total (overall.n still counts all)" bash -c "jq -e '(.procs | length) == 30 and .overall.n > 30 and (.totals | length) > 0 and .tree.totalMb > 0 and (.procs[0].footprint_mb >= .procs[29].footprint_mb)' '$FX_STATE/memory.jsonl'"

# --- cross-family review addendum ---------------------------------------------------------------------
# #3 the real executable, not argv/title: an OrbStack-like process retitled to node
fresh; fx_lean; fx_more; : > "$FX_LOGS/psenv.log"
fx_gc report > "$WORK/x1.txt" 2>&1
check "#3 an OrbStack-like process retitled 'node (helper)' whose real executable (ledger + lsof txt) is /Applications/OrbStack.app/... is reported PROTECTED, never an orphan" bash -c "grep -E '^ +318 .*PROTECTED' '$WORK/x1.txt' | grep -qv ORPHAN && grep -A1 -E '^ +318 ' '$WORK/x1.txt' | grep -q 'inside an .app bundle'"
check "#2 ledger rows that fail validation (owner 'not-a-uuid', first-seen in the far future) are dropped and reported; the rows are not listed" bash -c "grep -q 'LEDGER: 2 row(s) failed validation' '$WORK/x1.txt' && ! grep -qE '^ +(372|373) ' '$WORK/x1.txt'"
check "#2 a ledger-only orphan whose owner agent is unarchived and merely not running (371, owner A_CLOSEDU) is NOT proven: a ledger-only proof needs an archived or missing owner" bash -c "grep -E '^ +371 ' '$WORK/x1.txt' | grep -qv ORPHAN && grep -A1 -E '^ +371 ' '$WORK/x1.txt' | grep -q 'treated as LIVE'"
fresh; fx_lean; fx_more
fx_gc report --apply --kill-stale-processes > "$WORK/x2.txt" 2>&1
check "#2/#3 poisoned ledger rows are never killed: 319 (real exe /usr/local/bin/node differs from the recorded /opt/homebrew/bin/node) is skipped at action time; 318 (OrbStack exe), 371 (owner not dead) and the dropped rows 372/373 stay; 310 (a healthy row) is killed" bash -c "grep -q '319 -> skipped (executable path /usr/local/bin/node differs from the one recorded' '$WORK/x2.txt' && ! grep -qE ' (318|319|371|372|373|350)\$' '$FX_LOGS/kill.log' && grep -qE ' 310\$' '$FX_LOGS/kill.log'"
# an exe that cannot be read is never killed
fresh; fx_lean; rm -f "$FX_FIX/txt.310"; sed -i.b 's/^\(   310 .*\)$/\1/' "$FX_FIX/ps.txt"; rm -f "$FX_FIX/ps.txt.b"
fx_gc report --apply --kill-stale-processes > "$WORK/x3.txt" 2>&1
check "#3 if the real executable cannot be read at action time (no lsof txt, no absolute ps comm) nothing is killed" bash -c "grep -q '310 -> skipped (real executable path unreadable' '$WORK/x3.txt' && ! grep -qE ' 310\$' '$FX_LOGS/kill.log'"
# #4 invoker protection from slp-gc's own ancestry, with unreadable env
fresh; fx_orphans; fx_more; del_line 190; sedtop() { sed -i.b "$1" "$FX_FIX/top.txt"; rm -f "$FX_FIX/top.txt.b"; }
FX_INVOKER=aaaaaaaa-0000-4000-8000-0000000000dd SLPGC_ADD_SELF=1 fx_gc report --apply --kill-stale-processes --kill-over-memory > "$WORK/x4.txt" 2>&1
check "#4 the invoking agent child is derived from slp-gc's own ancestry: its subtree (353, 5000 MB) and the orphan whose ledger owner is pid:190@lstart (352) are protected even with PASEO_AGENT_ID unreadable and no matching invoker env" bash -c "! grep -qE ' (353|352)\$' '$FX_LOGS/kill.log' && grep -q \"protected: in the invoking agent's process subtree\" '$WORK/x4.txt' && grep -q 'protected: belongs to the invoking agent (from slp-gc' '$WORK/x4.txt'"
# #5 the owners of orphans keep their agent record alive
fresh; fx_orphans; fx_more
fx_gc report --apply > "$WORK/x5.txt" 2>&1
check "#5 an archived, otherwise garbage agent (A_GC1) that owns a live orphan (351) is not deleted (while its sibling garbage A_GC2 is); the per-action recheck repeats the union" bash -c "grep -q 'agent delete --home $RP -- $A_GC2' '$FX_LOGS/paseo.log' && ! grep -q 'agent delete --home $RP -- $A_GC1' '$FX_LOGS/paseo.log' && test '$(agent_count "$A_GC1")' = 1"
# #7 footprint re-read before a memory kill
fresh; fx_lean; printf '%s\n' '300    100M   10M' > "$FX_FIX/top.pid"
fx_gc report --apply --kill-over-memory > "$WORK/x7.txt" 2>&1
check "#7 the memory kill re-reads the footprint right before SIGTERM: 300 fell to 100 MB => skipped; the others (102 is not in top.pid either, so unreadable => fail closed) are not signalled on a stale reading" bash -c "grep -q '300 -> skipped (footprint now 100' '$WORK/x7.txt' && ! grep -qE ' 300\$' '$FX_LOGS/kill.log'"
# #8 top runs in the same order in both modes: no background job
check "#8 test mode changes only worker counts: top is never a background job (static)" bash -c "! grep -n 'collect_top .*&' '$GC' | grep -q . && grep -q 'ENV_JOBS=4' '$GC'"

# --- static properties -------------------------------------------------------------------------
check "slp-gc is bash 3.2-syntax clean and executable" bash -c "bash -n '$GC' && test -x '$GC'"
check "slp-gc has no SIGKILL, no process-group signal, no eval/source of the config, no recursive rm outside temp/lock/report rotation" bash -c "
  ! grep -nE 'kill +-(9|KILL|SIGKILL)|-KILL|kill +-[0-9]+ +-|kill +.*-- *-' '$GC' | grep -v '^[0-9]*: *#' | grep -q . &&
  ! grep -nE '(^|[^a-z_])(source|\\.) +\"?\\\$\\{?(file|SLP_GC_CONFIG)' '$GC' | grep -q . &&
  ! grep -nE '(^|[^a-z])rm +-' '$GC' | grep -vE '\\\$T|LOCKDIR|STATE/reports|stale\\.' | grep -q ."
check "every paseo CLI call passes --home explicitly and -- before ids (static)" bash -c "grep -c 'run_cli .*--home \"\$PHOME\"' '$GC' | grep -q 2 && grep -q -- '-- \"\$id\"' '$GC'"
fresh; fx_gc --help >/dev/null 2>&1; rc1=$?; fx_gc --bogus >/dev/null 2>&1; rc2=$?
check "--help exits 0; an unknown flag exits 2" test "$rc1" = 0 -a "$rc2" = 2

[ "$FAILED" = 0 ] || exit 1
