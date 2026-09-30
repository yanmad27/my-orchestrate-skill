#!/usr/bin/env bash
# Sandbox for slp-gc tests: a temp PASEO_HOME + HOME with fixture records, and stub
# ps/top/lsof/paseo/kill/... binaries that log their argv. Sourced by run-tests.sh.
# Nothing here touches the real ~/.paseo or real processes.

# fixed clock, so ages in the fixtures are exact
FX_NOW=1790000000
A_LIVE=aaaaaaaa-0000-4000-8000-000000000001      # unarchived, idle
A_GC1=aaaaaaaa-0000-4000-8000-000000000011       # archived 30 d  -> garbage (has an archived-owner claude child)
A_GC2=aaaaaaaa-0000-4000-8000-000000000012       # archived 20 d, dir name with a newline -> garbage
A_YOUNG=aaaaaaaa-0000-4000-8000-000000000021     # archived 3 d   -> protected (age)
A_PARENT=aaaaaaaa-0000-4000-8000-000000000022    # archived 30 d, referenced by a live child's label
A_CHILD=aaaaaaaa-0000-4000-8000-000000000023     # unarchived child of A_PARENT
A_PROC=aaaaaaaa-0000-4000-8000-000000000024      # archived 30 d, a process still carries its PASEO_AGENT_ID
A_INVOKER=aaaaaaaa-0000-4000-8000-000000000025   # archived 30 d, is the invoking agent
A_INFLIGHT=aaaaaaaa-0000-4000-8000-000000000026  # archived 30 d, referenced by an in-flight creation
A_CLOSEDU=aaaaaaaa-0000-4000-8000-000000000027   # closed but not archived
A_STALE=aaaaaaaa-0000-4000-8000-000000000028      # archived 30 d, owner of an old claude child (pid 121)
A_MISSING=aaaaaaaa-0000-4000-8000-0000000000ff   # no record on disk
A_NOINT=aaaaaaaa-0000-4000-8000-000000000029      # archived 30 d but the record has no internal key (strict: skipped)
A_NLREF=aaaaaaaa-0000-4000-8000-00000000002a     # archived 30 d, named only by a malformed file whose name has a newline
FAKE_CFG_TOKEN=FAKE-CFG-TOKEN-1234567890
FAKE_ENV_TOKEN=FAKE-ENV-TOKEN-abcdefghij
FAKE_LOG_TOKEN=FAKE-LOG-TOKEN-9999999999

fx_iso() { date -u -r $((FX_NOW - $1)) +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$((FX_NOW - $1))" +%Y-%m-%dT%H:%M:%S.000Z; }

fx_agent() {  # dir id status archivedDaysAgo|- provider [parentId]
  local dir="$1" id="$2" st="$3" ad="$4" prov="$5" parent="${6:-}" noint="${7:-}" arch=null labels='{}' intr='"internal":false,'
  [ "$ad" = - ] || arch="\"$(fx_iso $((ad * 86400)))\""
  [ -z "$parent" ] || labels="{\"paseo.parent-agent-id\":\"$parent\"}"
  [ -z "$noint" ] || intr=""
  mkdir -p "$dir"
  cat > "$dir/$id.json" <<J
{"id":"$id","provider":"$prov","cwd":"/tmp/fx","createdAt":"$(fx_iso 4000000)","updatedAt":"$(fx_iso 100)","lastStatus":"$st",
 "title":"SECRET-PROMPT-TITLE","labels":$labels,$intr"archivedAt":$arch,"runtimeInfo":{"sessionId":"sess-$id"}}
J
}
fx_sched() {  # dir id status target updatedAgo lastRunAgo|- room(0/1) runs
  local dir="$1" id="$2" st="$3" tgt="$4" upd="$5" last="$6" room="${7:-1}" runs="${8:-2}" nm='"supervisor: room"' lr=null nx=null r="" i
  [ "$room" = 1 ] || nm='"user job"'
  [ "$last" = - ] || lr="\"$(fx_iso "$last")\""
  [ "$st" != active ] || nx="\"$(fx_iso -60)\""
  for i in $(seq 1 "$runs"); do r="$r{\"id\":\"r$i\",\"scheduledFor\":\"$(fx_iso $((i * 120)))\",\"startedAt\":\"$(fx_iso $((i * 120)))\",\"status\":\"failed\",\"error\":\"already has an active run\"},"; done
  r="[${r%,}]"
  cat > "$dir/$id.json" <<J
{"id":"$id","name":$nm,"prompt":"[supervisor-heartbeat] hello","cadence":{"type":"cron","expression":"*/2 * * * *"},
 "target":{"type":"agent","agentId":"$tgt"},"status":"$st","createdAt":"$(fx_iso 900000)","updatedAt":"$(fx_iso "$upd")",
 "nextRunAt":$nx,"lastRunAt":$lr,"runs":$r}
J
}
fx_psrow() {  # pid ppid etime rssKB lstart cmd
  printf '%6s %6s %6s %12s %8s %s %s\n' "$1" "$2" "$2" "$3" "$4" "$5" "$6"
}

make_sandbox() {  # make_sandbox <dir>
  local SB="$1" P H F i
  P="$SB/paseo home"; H="$SB/home"; F="$SB/fix"
  mkdir -p "$P" "$H/Library/Logs/DiagnosticReports" "$H/Library/Logs/Paseo" "$SB/bin" "$F" "$SB/logs" "$SB/state" "$SB/cfg"
  FX_TMP="$SB.tmp"; mkdir -p "$FX_TMP"; FX_SB="$SB"; FX_PHOME="$P"; FX_HOME="$H"; FX_FIX="$F"; FX_LOGS="$SB/logs"; FX_STATE="$SB/state"; FX_BIN="$SB/bin"
  # --- Paseo home ---
  printf '{"pid":110,"startedAt":"x","listen":"127.0.0.1:6767","desktopManaged":true}\n' > "$P/paseo.pid"
  printf '{"agents":{"providers":{"x":{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"%s"}}}}}\n' "$FAKE_CFG_TOKEN" > "$P/config.json"
  printf '{"tok":"%s"}\n' "$FAKE_CFG_TOKEN" > "$P/config.json.bak-20260929120628"
  printf '{"level":30,"time":"t","msg":"ws_runtime_metrics","pid":111,"memory":{"rss":1000,"heapUsed":500},"agents":{"timelineStats":{"totalItems":42,"maxItemsPerAgent":40}}}\n{"msg":"startup","token":"%s"}\n' "$FAKE_LOG_TOKEN" > "$P/daemon.log"
  echo old > "$P/20260918-0416-01-daemon.log"
  fx_agent "$P/agents/slug-a" "$A_LIVE" idle - claude
  fx_agent "$P/agents/slug-a" "$A_GC1" closed 30 claude-peer
  fx_agent "$P/agents/odd
slug" "$A_GC2" closed 20 claude
  fx_agent "$P/agents/slug-a" "$A_YOUNG" closed 3 claude
  fx_agent "$P/agents/slug-a" "$A_PARENT" closed 30 claude-lead
  fx_agent "$P/agents/slug-a" "$A_CHILD" idle - claude-peer "$A_PARENT"
  fx_agent "$P/agents/slug-a" "$A_PROC" closed 30 claude
  fx_agent "$P/agents/slug-a" "$A_INVOKER" closed 30 claude
  fx_agent "$P/agents/slug-a" "$A_INFLIGHT" closed 30 claude
  fx_agent "$P/agents/slug-a" "$A_CLOSEDU" closed - claude
  fx_agent "$P/agents/slug-a" "$A_STALE" closed 30 claude
  fx_agent "$P/agents/slug-a" "$A_NOINT" closed 30 claude "" noint
  fx_agent "$P/agents/slug-a" "$A_NLREF" closed 30 claude
  printf '{not json, mentions %s\n' "$A_NLREF" > "$P/agents/odd
slug/bad
name.json"
  printf '{not json\n' > "$P/agents/slug-a/bad.json"
  ln -s "$A_GC1.json" "$P/agents/slug-a/link.json"
  mkdir -p "$P/schedules"
  fx_sched "$P/schedules" 0000000a completed "$A_GC1" 432000 259200          # garbage
  fx_sched "$P/schedules" 0000000b completed "$A_MISSING" 432000 259200      # garbage (target absent)
  fx_sched "$P/schedules" 0000000c active "$A_LIVE" 60 60 1 50               # protected: live target
  fx_sched "$P/schedules" 0000000d completed "$A_GC2" 600 900                # too young
  perl -pi -e 's/"supervisor: room"/"supervisor: \\u001b[31mred"/' "$P/schedules/0000000d.json"
  fx_sched "$P/schedules" 0000000e active "$A_YOUNG" 7200 7200              # anomaly, report only
  fx_sched "$P/schedules" 0000000f completed "$A_LIVE" 432000 259200         # completed but target live
  printf '{"id": ' > "$P/schedules/00000010.json"
  fx_sched "$P/schedules" 00000011 completed "$A_MISSING" 432000 259200
  sed -i.b 's/"lastRunAt":[^,]*,//' "$P/schedules/00000011.json"; rm -f "$P/schedules/00000011.json.b"
  ln -s 0000000a.json "$P/schedules/lnk00000.json"
  mkdir -p "$P/creations"
  printf '{"fingerprint":"f","inFlight":{"x":1},"snapshot":{"phase":"running","agentId":"%s"}}\n' "$A_INFLIGHT" > "$P/creations/c1.json"
  echo abc > "$P/creations/c1.claim"
  mkdir -p "$P/agent-requests" "$P/uploads/upload_x"; echo '{"state":"completed"}' > "$P/agent-requests/r1.json"; echo pdf > "$P/uploads/upload_x/a.pdf"
  # worktrees: one dirty, one clean (no upstream)
  mkdir -p "$P/worktrees/abcd1234/dirty" "$P/worktrees/abcd1234/clean" "$P/worktrees/empty000"
  for i in dirty clean; do
    git -C "$P/worktrees/abcd1234/$i" init -q 2>/dev/null
    echo a > "$P/worktrees/abcd1234/$i/f"; git -C "$P/worktrees/abcd1234/$i" add f
    git -C "$P/worktrees/abcd1234/$i" -c user.name=t -c user.email=t@t commit -qm i 2>/dev/null
  done
  echo dirt > "$P/worktrees/abcd1234/dirty/untracked"
  # transcript for one agent (>512 KB)
  mkdir -p "$SB/cfg/projects/p1"; head -c 700000 /dev/zero | tr '\0' 'x' > "$SB/cfg/projects/p1/sess-$A_LIVE.jsonl"
  # diagnostic reports: a Paseo crash + a jetsam (kept), an unrelated crash + an old one (dropped)
  echo "Process: Paseo Helper" > "$H/Library/Logs/DiagnosticReports/Paseo-1.crash"
  echo "jetsam" > "$H/Library/Logs/DiagnosticReports/JetsamEvent-2026.ips"
  echo "Process: Safari" > "$H/Library/Logs/DiagnosticReports/Safari-1.crash"
  echo "Process: Paseo" > "$H/Library/Logs/DiagnosticReports/Paseo-old.crash"; touch -t 200001010000 "$H/Library/Logs/DiagnosticReports/Paseo-old.crash"
  echo "main log" > "$H/Library/Logs/Paseo/main.log"
  # --- process fixtures: pid ppid etime rssKB lstart cmd ---
  local HP="/Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper"
  local RP="/Applications/Paseo.app/Contents/Frameworks/Paseo Helper (Renderer).app/Contents/MacOS/Paseo Helper (Renderer)"
  local CL="/opt/homebrew/bin/claude --output-format stream-json --input-format stream-json --permission-prompt-tool stdio --mcp-config {}"
  local L1="Wed Sep 30 08:00:00 2026" L2="Wed Sep 30 09:00:00 2026" W="/Users/x/.config/slp-room/bin/slp-wait"
  {
    fx_psrow 100 1 05:00:00 900000 "$L1" "/Applications/Paseo.app/Contents/MacOS/Paseo"
    fx_psrow 101 100 05:00:00 900000 "$L1" "$RP --type=renderer"
    fx_psrow 102 100 05:00:00 900000 "$L1" "$HP --type=gpu-process"
    fx_psrow 103 100 05:00:00 9000 "$L1" "$HP --type=utility --utility-sub-type=network.mojom.NetworkService"
    fx_psrow 110 100 05:00:00 30000 "$L1" "Paseo Supervisor"
    fx_psrow 111 110 04:59:00 150000 "$L1" "Paseo Daemon"
    fx_psrow 112 111 04:59:00 25000 "$L1" "$HP /x/@getpaseo/server/dist/server/terminal/terminal-worker-process.js"
    fx_psrow 120 111 04:00:00 200000 "$L2" "$CL"
    fx_psrow 121 111 02:00:00 200000 "$L2" "$CL"
    fx_psrow 122 1 03:00:00 200000 "$L2" "$CL"
    fx_psrow 123 1 05:00 200000 "$L2" "$CL"
    fx_psrow 124 1 03:00:00 200000 "$L2" "$CL"
    fx_psrow 125 1 03:00:00 200000 "$L2" "$CL"
    fx_psrow 130 1 05:00 1000 "$L2" "/bin/sh $W $A_LIVE 110"
    fx_psrow 131 130 01:00 118000 "$L2" "$HP --disable-warning=DEP0040 /x/node-entrypoint-runner.js node-script /x/cli/dist/index.js wait $A_LIVE --timeout 110 --json"
    fx_psrow 140 121 02:00:00 30000 "$L2" "uv run mcp-atlassian"
    fx_psrow 150 999 09:00:00 300000 "$L2" "/opt/homebrew/bin/claude --dangerously-skip-permissions"
    fx_psrow 160 111 05:00 200000 "$L2" "$CL"
    fx_psrow 170 1 03:00:00 200000 "$L2" "$CL"
    fx_psrow 180 111 01:30:00 200000 "$L2" "$CL"
    fx_psrow 190 1 04:00:00 1000 "$L2" "$CL"
    fx_psrow 195 999 03:00:00 200000 "$L2" "$CL"
    fx_psrow 200 1 05:00:00 900000 "$L1" "/Applications/Paseo.app/Contents/MacOS/Paseo"
    fx_psrow 201 200 05:00:00 900000 "$L1" "$HP --type=gpu-process"
    printf 'garbage row that is not a ps row\n'
  } > "$F/ps.txt"
  sed 's/^\(   125 .*\)Wed Sep 30 09:00:00 2026/\1Wed Sep 30 09:59:59 2026/' "$F/ps.txt" > "$F/ps.recheck"
  local ID="PASEO_HOME=$P"
  {
    echo "  100 /Applications/Paseo.app/Contents/MacOS/Paseo PATH=/usr/bin HOME=/Users/x SECRET_KEY=$FAKE_ENV_TOKEN"
    echo "  110 Paseo Supervisor PATH=/usr/bin $ID"
    echo "  111 Paseo Daemon PATH=/usr/bin $ID CLAUDE_CODE_OAUTH_TOKEN=$FAKE_ENV_TOKEN"
    for i in "120 $A_LIVE" "121 $A_STALE" "122 $A_LIVE" "123 $A_LIVE" "124 $A_INVOKER2" "125 $A_LIVE" "160 $A_PROC" "180 $A_LIVE" "190 $A_LIVE" "195 $A_LIVE"; do
      set -- $i
      echo "  $1 /opt/homebrew/bin/claude --output-format stream-json PATH=/usr/bin PASEO_AGENT_ID=$2 $ID CLAUDE_CODE_OAUTH_TOKEN=$FAKE_ENV_TOKEN ANTHROPIC_AUTH_TOKEN=$FAKE_ENV_TOKEN"
    done
    echo "  130 /bin/sh $W PATH=/usr/bin PASEO_AGENT_ID=$A_LIVE $ID"
    echo "  131 Paseo Helper node PATH=/usr/bin PASEO_AGENT_ID=$A_LIVE $ID"
    echo "  170 /opt/homebrew/bin/claude --output-format stream-json PATH=/usr/bin PASEO_AGENT_ID=$A_LIVE PASEO_HOME=/somewhere/else ANTHROPIC_API_KEY=$FAKE_ENV_TOKEN"
  } > "$F/env.txt"
  # claude 124 is the invoker's own child; give the sandbox one more agent id for it
  cat > "$F/top.txt" <<T
Processes: 400 total
PID    MEM    CMPRS
100    30000M 20000M
101    5000M  100M
102    20000M 15000M
103    9M     1M
110    20000M 100M
111    150M   20M
112    25M    24M
120    200M   30M
121    200M+  30M
122    200M   30M
123    200M   30M
124    200M   30M
125    200M   30M
130    1M     0B
131    118M   10M
140    300M   10M
150    9000K  0B
160    200M   30M
170    200M   30M
195    20000M 15000M
200    100M   10M
201    20000M 15000M
T
  printf '%s\n' 'Mach Virtual Memory Statistics: (page size of 16384 bytes)' 'Pages free: 10.' 'Pages stored in compressor: 221406.' 'Pages occupied by compressor: 100000.' 'Swapouts: 5.' 'Pageouts: 11040.' > "$F/vm_stat.txt"
  # --- stubs ---
  cat > "$SB/bin/ps" <<'S'
#!/bin/sh
# stub ps: -p N reads ps.recheck (if present) filtered to that pid, otherwise the whole ps.txt.
# SLPGC_ADD_SELF=1 adds a row for the caller (slp-gc) whose parent is claude 190: its process tree.
pid=""; while [ $# -gt 0 ]; do [ "$1" = -p ] && pid="$2"; shift; done
if [ -n "$pid" ]; then
  f="$SLPGC_FIX/ps.recheck"; [ -f "$f" ] || f="$SLPGC_FIX/ps.txt"; awk -v p="$pid" '$1 == p' "$f"
else
  cat "$SLPGC_FIX/ps.txt"
  [ -z "$SLPGC_ADD_SELF" ] || printf '%6s %6s %6s %12s %8s %s %s\n' "$PPID" 190 190 00:10 1000 "Wed Sep 30 09:00:00 2026" "/bin/bash slp-gc"
fi
S
  cat > "$SB/bin/psenv" <<'S'
#!/bin/sh
# stub ps for the environment: -p N prints the command + env of that pid (the fixture line minus its pid)
pid=""; while [ $# -gt 0 ]; do [ "$1" = -p ] && pid="$2"; shift; done
awk -v p="$pid" '$1 == p { $1 = ""; sub(/^ +/, ""); print }' "$SLPGC_FIX/env.txt"
S
  printf '#!/bin/sh\ncat "$SLPGC_FIX/top.txt"\n' > "$SB/bin/top"
  printf '#!/bin/sh\necho p111\n' > "$SB/bin/lsof"
  printf '#!/bin/sh\ncat "$SLPGC_FIX/vm_stat.txt"\n' > "$SB/bin/vm_stat"
  printf '#!/bin/sh\necho "total = 2048.00M  used = 1500.50M  free = 547.50M  (encrypted)"\n' > "$SB/bin/sysctl"
  printf '#!/bin/sh\necho "$*" >> "$SLPGC_LOGS/kill.log"\n' > "$SB/bin/kill"
  printf '#!/bin/sh\necho "$*" >> "$SLPGC_LOGS/osascript.log"\n' > "$SB/bin/osascript"
  printf '#!/bin/sh\necho "2026-09-30 memorystatus: fixture line"\n' > "$SB/bin/log"
  cat > "$SB/bin/paseo" <<'S'
#!/bin/sh
# stub paseo: logs argv, then plays the daemon (removes the record it is asked to delete).
# Wants the exact argv slp-gc must use: <group> <cmd> --home <dir> -- <id>   (or agent ls ... --home <dir>)
echo "$*" >> "$SLPGC_LOGS/paseo.log"
echo "PASEO_HOME=$PASEO_HOME" >> "$SLPGC_LOGS/paseo.env"
[ "$1" = --version ] && { echo "0.10.2-stub"; exit 0; }
[ -z "$SLPGC_PASEO_HANG" ] || exec sleep 30
case "$1 $2" in
  "agent ls") [ -f "$SLPGC_FIX/agents-ls.json" ] || exit 1; cat "$SLPGC_FIX/agents-ls.json"; exit 0 ;;
  "agent delete"|"schedule delete") ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
[ "$3" = --home ] && [ "$5" = -- ] && [ "$#" = 6 ] || { echo "bad argv: $*" >&2; exit 2; }
id="$6"
case "$1" in
  agent) find "$PASEO_HOME/agents" -mindepth 2 -maxdepth 2 -type f -name "$id.json" -exec rm -f {} + ;;
  schedule) rm -f "$PASEO_HOME/schedules/$id.json" ;;
esac
S
  chmod +x "$SB"/bin/*
  # the invoker's agent (its own claude child is pid 124)
  export SLPGC_FIX="$F" SLPGC_LOGS="$SB/logs"
}
A_INVOKER2=$A_INVOKER

# run slp-gc inside the sandbox environment
fx_gc() {  # fx_gc <args...>
  env -i PATH="/usr/bin:/bin:/usr/local/bin" SLP_GC_TEST=1 SLP_GC_TEST_HOOK="${FX_HOOK:-}" HOME="$FX_HOME" TMPDIR="$FX_TMP" \
    PASEO_HOME="$FX_PHOME" PASEO_AGENT_ID="${FX_INVOKER:-$A_INVOKER}" CLAUDE_CONFIG_DIR="$FX_SB/cfg" \
    SLP_GC_STATE_DIR="$FX_STATE" SLP_GC_CONFIG="$FX_SB/slp-gc.conf" SLP_GC_NOW="$FX_NOW" \
    SLP_GC_PS="$FX_BIN/ps" SLP_GC_PSENV="$FX_BIN/psenv" SLP_GC_TOP="$FX_BIN/top" SLP_GC_LSOF="$FX_BIN/lsof" \
    SLP_GC_VMSTAT="$FX_BIN/vm_stat" SLP_GC_SYSCTL="$FX_BIN/sysctl" SLP_GC_KILL="$FX_BIN/kill" \
    SLP_GC_OSASCRIPT="$FX_BIN/osascript" SLP_GC_PASEO="$FX_BIN/paseo" \
    SLPGC_FIX="$FX_FIX" SLPGC_LOGS="$FX_LOGS" SLPGC_PASEO_HANG="${SLPGC_PASEO_HANG:-}" SLPGC_ADD_SELF="${SLPGC_ADD_SELF:-}" \
    SLP_GC_CLI_TIMEOUT="${SLP_GC_CLI_TIMEOUT:-5}" ${FX_EXTRA_ENV:-} \
    "$FX_GC" "$@"
}

# snapshot: path, type, mode, symlink target, sha256, mtime — for every entry under a tree
fx_snapshot() {
  local root="$1" p t m s h mt
  find "$root" -print0 | sort -z | while IFS= read -r -d '' p; do
    if [ -L "$p" ]; then t=l; s="$(readlink "$p")"; h=-
    elif [ -d "$p" ]; then t=d; s=-; h=-
    else t=f; s=-; h="$( { shasum -a 256 "$p" 2>/dev/null || sha256sum "$p"; } | awk '{print $1}')"; fi
    m="$(stat -c %a "$p" 2>/dev/null || stat -f %Lp "$p")"; mt="$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p")"
    printf '%q %s %s %q %s %s\n' "${p#"$root"}" "$t" "$m" "$s" "$h" "$mt"
  done
}

# a hook that runs after slp-gc's evaluation and before its first action: it UNARCHIVES two of the
# targets (A_GC1: an archived agent that a garbage schedule points at; A_GC2), the way a user could
fx_make_hook() {
  cat > "$FX_SB/hook.sh" <<'H'
#!/bin/sh
find "$PASEO_HOME/agents" -type f \( -name 'aaaaaaaa-0000-4000-8000-000000000011.json' -o -name 'aaaaaaaa-0000-4000-8000-000000000012.json' \) -exec sh -c 'for f; do jq ".archivedAt = null" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done' sh {} +
H
  chmod +x "$FX_SB/hook.sh"
  FX_HOOK="$FX_SB/hook.sh"
}
