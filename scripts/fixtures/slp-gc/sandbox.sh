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
  mkdir -p "$P" "$H/Library/Logs/DiagnosticReports" "$H/Library/Logs/Paseo" "$SB/bin" "$F" "$SB/logs" "$SB/state" "$SB/cfg"; chmod 700 "$SB/state"
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
101    3500M  100M
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
pid=""; comm=""; while [ $# -gt 0 ]; do [ "$1" = -p ] && pid="$2"; [ "$1" = "comm=" ] && comm=1; shift; done
if [ -n "$comm" ]; then   # -o comm= -p N: the executable path (fixture comm.N, else the first word of the command line)
  if [ -f "$SLPGC_FIX/comm.$pid" ]; then cat "$SLPGC_FIX/comm.$pid"
  else f="$SLPGC_FIX/ps.recheck"; [ -f "$f" ] || f="$SLPGC_FIX/ps.txt"; awk -v p="$pid" '$1 == p {print $11}' "$f"; fi
elif [ -n "$pid" ]; then
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
[ -z "$SLPGC_TRACE" ] || echo "$pid" >> "$SLPGC_LOGS/psenv.log"
# pure sh (no awk): line = "<spaces><pid> <rest>"
while IFS= read -r line; do
  set -f; set -- $line; set +f
  if [ "$1" = "$pid" ]; then shift; echo "$*"; fi
done < "$SLPGC_FIX/env.txt"
S
  cat > "$SB/bin/top" <<'S'
#!/bin/sh
# stub top: `-pid N` answers from top.pid when present (a later, different reading), else the full listing
case "$*" in *" -pid "*) [ -f "$SLPGC_FIX/top.pid" ] && { cat "$SLPGC_FIX/top.pid"; exit 0; } ;; esac
cat "$SLPGC_FIX/top.txt"
S
  cat > "$SB/bin/lsof" <<'S'
#!/bin/sh
# stub lsof: `-F fan -p N` prints the fixture supfiles.N (open files in -F format, if any); `-d cwd -p N` prints the fixture cwd.N (if any); the listener query prints the daemon pid
case "$*" in
  *"-d cwd"*) [ -z "$SLPGC_TRACE" ] || echo "$*" >> "$SLPGC_LOGS/lsof-cwd.log"; p=""; while [ $# -gt 0 ]; do [ "$1" = -p ] && p="$2"; shift; done
              [ -f "$SLPGC_FIX/cwd.$p" ] && { echo "p$p"; echo fcwd; echo "n$(cat "$SLPGC_FIX/cwd.$p")"; }; exit 0 ;;
  *"-F fan"*) [ ! -x "$SLPGC_FIX/fan-hook.sh" ] || "$SLPGC_FIX/fan-hook.sh"
              [ -z "$SLPGC_TRACE" ] || echo "$*" >> "$SLPGC_LOGS/lsof-fan.log"; p=""; while [ $# -gt 0 ]; do [ "$1" = -p ] && p="$2"; shift; done
              [ -f "$SLPGC_FIX/supfiles.$p" ] && { echo "p$p"; cat "$SLPGC_FIX/supfiles.$p"; }; exit 0 ;;
  *"-d txt"*) p=""; while [ $# -gt 0 ]; do [ "$1" = -p ] && p="$2"; shift; done
              [ -f "$SLPGC_FIX/txt.$p" ] && { echo "p$p"; echo ftxt; echo "n$(cat "$SLPGC_FIX/txt.$p")"; }; exit 0 ;;
esac
echo p111
S
  printf '#!/bin/sh\nsleep 2\ncat "$SLPGC_FIX/top.txt"\n' > "$SB/bin/top-slow"
  printf '#!/bin/sh\ncat "$SLPGC_FIX/vm_stat.txt"\n' > "$SB/bin/vm_stat"
  cat > "$SB/bin/sysctl" <<'S'
#!/bin/sh
# stub sysctl: hw.memsize = 16 GiB (SLPGC_MEMSIZE overrides); vm.swapusage = a fixed line
case "$*" in
  *hw.memsize*) echo "${SLPGC_MEMSIZE:-17179869184}" ;;
  *) echo "total = 2048.00M  used = 1500.50M  free = 547.50M  (encrypted)" ;;
esac
S
  cat > "$SB/bin/kill" <<'S'
#!/bin/sh
# stub kill: logs the argv; runs $SLPGC_FIX/after-kill.sh once after the first signal (something changes between two kills of a batch)
echo "$*" >> "$SLPGC_LOGS/kill.log"
if [ -x "$SLPGC_FIX/after-kill.sh" ]; then "$SLPGC_FIX/after-kill.sh"; rm -f "$SLPGC_FIX/after-kill.sh"; fi
S
  printf '#!/bin/sh\necho "$*" >> "$SLPGC_LOGS/osascript.log"\n' > "$SB/bin/osascript"
  printf '#!/bin/sh\necho "2026-09-30 memorystatus: fixture line"\n' > "$SB/bin/log"
  cat > "$SB/bin/paseo" <<'S'
#!/bin/sh
# stub paseo: logs argv, then plays the daemon (removes the record it is asked to delete).
# Wants the exact argv slp-gc must use: <group> <cmd> --home <dir> -- <id>   (or agent inspect --home <dir> --json -- <id>)
echo "$*" >> "$SLPGC_LOGS/paseo.log"
echo "PASEO_HOME=$PASEO_HOME" >> "$SLPGC_LOGS/paseo.env"
[ "$1" = --version ] && { echo "0.10.2-stub"; exit 0; }
[ -z "$SLPGC_PASEO_HANG" ] || exec sleep 30
case "$1 $2" in
  "agent inspect")   # agent inspect --home <dir> --json -- <uuid>: prints $SLPGC_FIX/inspect-<uuid>.json (else fails)
    [ "$3" = --home ] && [ "$5" = --json ] && [ "$6" = -- ] && [ "$#" = 7 ] || { echo "bad argv: $*" >&2; exit 2; }
    echo "warning: stderr noise that must not reach the JSON parser" >&2
    [ -f "$SLPGC_FIX/inspect-$7.json" ] || exit 1; cat "$SLPGC_FIX/inspect-$7.json"; exit 0 ;;
  "agent send")   # agent send --home <dir> --no-wait --prompt-file <file> -- <uuid>: logs one arg per line, the prompt file mode and text
    [ "$3" = --home ] && [ "$5" = --no-wait ] && [ "$6" = --prompt-file ] && [ "$8" = -- ] && [ "$#" = 9 ] || { echo "bad argv: $*" >&2; exit 2; }
    { echo "SEND"; for a in "$@"; do echo "ARG:$a"; done; echo "END"; } >> "$SLPGC_LOGS/send-argv.log"
    m="$(stat -f %Lp "$7" 2>/dev/null || stat -c %a "$7" 2>/dev/null)"; echo "$m $7" >> "$SLPGC_LOGS/send-file.log"
    { echo "=== to $9"; cat "$7"; } >> "$SLPGC_LOGS/send-msgs.log"
    [ -z "$SLPGC_SEND_HANG" ] || exec sleep 30
    [ -z "$SLPGC_SEND_FAIL" ] || { echo "send refused" >&2; exit 1; }
    exit 0 ;;
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

# a Supervisor-ish record for the delivery tests: fx_sup <id> <provider> <MISSING (no key, the live open shape)|null|false|0|7|ISO> <lastUserMessageAt|null> <lastActivityAt> [attentionReason]
fx_sup() {
  local id="$1" prov="$2" arch="$3" lum="$4" lact="$5" att="${6:-null}"
  local archkv;
  case "$arch" in MISSING) archkv="" ;; false) archkv='"archivedAt":false,' ;; 0|7) archkv="\"archivedAt\":$arch,";; null) archkv='"archivedAt":null,' ;; *) archkv="\"archivedAt\":\"$arch\"," ;; esac
  [ "$lum" = null ] || lum="\"$lum\""; [ "$att" = null ] || att="\"$att\""
  mkdir -p "$FX_PHOME/agents/slug-sup"
  cat > "$FX_PHOME/agents/slug-sup/$id.json" <<J
{"id":"$id","provider":"$prov","cwd":"/tmp/fx","createdAt":"$(fx_iso 4000000)","updatedAt":"$(fx_iso 100)","lastStatus":"idle","title":"SECRET-PROMPT-TITLE","labels":{},"internal":false,
 $archkv"lastUserMessageAt":$lum,"lastActivityAt":"$5","attentionReason":$att,"runtimeInfo":{"sessionId":"sess-$id"}}
J
}

# run slp-gc inside the sandbox environment
fx_gc() {  # fx_gc <args...>
  env -i PATH="/usr/bin:/bin:/usr/local/bin" SLP_GC_TEST=1 SLP_GC_TEST_HOOK="${FX_HOOK:-}" HOME="$FX_HOME" TMPDIR="$FX_TMP" \
    PASEO_HOME="$FX_PHOME" PASEO_AGENT_ID="${FX_INVOKER:-$A_INVOKER}" CLAUDE_CONFIG_DIR="$FX_SB/cfg" \
    SLP_GC_STATE_DIR="$FX_STATE" SLP_GC_CONFIG="$FX_SB/slp-gc.conf" SLP_GC_NOW="$FX_NOW" \
    SLP_GC_PS="$FX_BIN/ps" SLP_GC_PSENV="$FX_BIN/psenv" SLP_GC_TOP="$FX_BIN/top" SLP_GC_LSOF="$FX_BIN/lsof" \
    SLP_GC_VMSTAT="$FX_BIN/vm_stat" SLP_GC_SYSCTL="$FX_BIN/sysctl" SLP_GC_KILL="$FX_BIN/kill" \
    SLP_GC_OSASCRIPT="$FX_BIN/osascript" SLP_GC_PASEO="$FX_BIN/paseo" \
    SLPGC_FIX="$FX_FIX" SLPGC_LOGS="$FX_LOGS" SLPGC_PASEO_HANG="${SLPGC_PASEO_HANG:-}" SLPGC_ADD_SELF="${SLPGC_ADD_SELF:-}" SLPGC_MEMSIZE="${SLPGC_MEMSIZE:-}" SLPGC_TRACE="${FX_TRACE:-}" SLP_GC_SKIP_RETENTION="$([ "${FX_RETENTION:-}" = on ] && echo 0 || echo 1)" \
    SLP_GC_CLI_TIMEOUT="${SLP_GC_CLI_TIMEOUT:-5}" ${FX_EXTRA_ENV:-} \
    "$FX_GC" "$@"   # slpgc-sandboxed
}
# minimal-environment tick (env -i, PATH=/usr/bin:/bin): the notifier, CLI and kill overrides are deliberately unset
fx_gc_min() {
  env -i PATH=/usr/bin:/bin SLP_GC_TEST=1 HOME="$FX_HOME" TMPDIR="$FX_TMP" SLP_GC_STATE_DIR="$FX_STATE" SLP_GC_CONFIG=/nonexistent PASEO_HOME="$FX_PHOME" \
    SLP_GC_PS="$FX_BIN/ps" SLP_GC_PSENV="$FX_BIN/psenv" SLP_GC_TOP="$FX_BIN/top" SLP_GC_LSOF="$FX_BIN/lsof" SLP_GC_VMSTAT="$FX_BIN/vm_stat" \
    SLP_GC_SYSCTL="$FX_BIN/sysctl" SLPGC_FIX="$FX_FIX" "$FX_GC" "$@"   # slpgc-sandboxed
}
# C6 canary (FX_CANARY_PASEO_CLI is passed through as the ambient PASEO_CLI): SLP_GC_TEST=1 with the notifier/CLI/kill overrides unset and logging osascript/paseo/kill first on PATH
fx_gc_canary() {
  env -i PATH="$FX_BIN:/usr/bin:/bin" SLP_GC_TEST=1 HOME="$FX_HOME" TMPDIR="$FX_TMP" SLP_GC_STATE_DIR="$FX_STATE" SLP_GC_CONFIG="$FX_SB/slp-gc.conf" \
    PASEO_HOME="$FX_PHOME" PASEO_AGENT_ID="${FX_INVOKER:-$A_INVOKER}" SLP_GC_NOW="$FX_NOW" \
    SLP_GC_PS="$FX_BIN/ps" SLP_GC_PSENV="$FX_BIN/psenv" SLP_GC_TOP="$FX_BIN/top" SLP_GC_LSOF="$FX_BIN/lsof" SLP_GC_VMSTAT="$FX_BIN/vm_stat" \
    SLP_GC_SYSCTL="$FX_BIN/sysctl" SLPGC_FIX="$FX_FIX" SLPGC_LOGS="$FX_LOGS" SLP_GC_SKIP_RETENTION=1 ${FX_CANARY_PASEO_CLI:+PASEO_CLI="$FX_CANARY_PASEO_CLI"} "$FX_GC" "$@"   # slpgc-sandboxed
}
# no SLP_GC_TEST: proves the test overrides are ignored. Read-only `report` only; anything else is refused here.
fx_gc_bare() {
  case " $* " in *" report "*) ;; *) echo "fx_gc_bare: report only" >&2; return 2 ;; esac
  case " $* " in *" --apply "*) echo "fx_gc_bare: no --apply" >&2; return 2 ;; esac
  env -i PATH="$FX_BIN:/usr/bin:/bin" HOME="$FX_HOME" TMPDIR="$FX_TMP" SLP_GC_STATE_DIR="$FX_STATE" PASEO_HOME="$FX_PHOME" \
    SLP_GC_PS="$FX_BIN/ps" SLP_GC_PSENV="$FX_BIN/psenv" SLP_GC_TOP="$FX_BIN/top" SLP_GC_KILL="$FX_BIN/kill" SLP_GC_PASEO="$FX_BIN/paseo" SLP_GC_NOW=1 \
    SLPGC_FIX="$FX_FIX" SLPGC_LOGS="$FX_LOGS" "$FX_GC" "$@"   # slpgc-sandboxed
}

# snapshot: path, type, mode, symlink target, sha256, mtime - for every entry under a tree (one perl process)
fx_snapshot() {
  perl -MFile::Find -MDigest::SHA -e '
    my $root = shift; my @e;
    find({ no_chdir => 1, wanted => sub { push @e, $File::Find::name } }, $root);
    for my $p (sort @e) {
      my @s = lstat($p); my ($t, $l, $h) = ("f", "-", "-");
      if (-l _) { $t = "l"; $l = readlink($p); } elsif (-d _) { $t = "d"; }
      else { $h = Digest::SHA->new(256)->addfile($p, "b")->hexdigest; }
      (my $r = $p) =~ s/^\Q$root\E//;
      $r =~ s/([^A-Za-z0-9_.\/-])/sprintf("\\x%02x", ord($1))/ge; $l =~ s/([^A-Za-z0-9_.\/-])/sprintf("\\x%02x", ord($1))/ge;
      printf "%s %s %o %s %s %d\n", $r, $t, $s[2] & 07777, $l, $h, $s[9];
    }' "$1"
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

# --- B1b fixtures: orphaned agent descendants, test-runner subtrees, ledger -----------------------
# Appended to a fresh sandbox (kept out of make_sandbox so the base process counts stay put).
#   300 node (vitest 3)  under claude 120 (live agent), 5000 MB      301 node (vitest 4) under 120, 500 MB
#   310 ppid 1, retitled, EMPTY env, ledger row matches              311 same, but the ledger lstart differs
#   312 ppid 1, argv vitest, env PASEO_HOME + PASEO_AGENT_ID         313 OrbStack (.app) ppid 1 with PASEO env, 9000 MB
#   314 ppid 1, ledger match, orphaned 5 min ago     350 ppid 1 nohup dev server, ledger match, owner A_LIVE still live
#   340-343 workers under claude 120 (5000 MB): Xcode swift-frontend, mytool, a benign argv whose real exe is in an .app, an .app node                              315 ppid 1, ledger match, comm mytool (not allowlisted)
#   316 ppid 1, env proof but another PASEO_HOME                     317 ppid 1, retitled, no ledger/env, cwd under the worktrees dir
fx_orphans() {
  local P="$FX_PHOME" F="$FX_FIX" L2="Wed Sep 30 09:00:00 2026" L3="Wed Sep 30 09:30:00 2026" OB="/Applications/OrbStack.app/Contents/MacOS/OrbStack Helper"
  {
    fx_psrow 300 120 01:00:00 5000000 "$L2" "node (vitest 3)"
    fx_psrow 301 120 01:00:00 500000 "$L2" "node (vitest 4)"
    fx_psrow 310 1 01:00:00 4500000 "$L2" "node (vitest 3)"
    fx_psrow 311 1 01:00:00 200000 "$L3" "node (vitest 3)"
    fx_psrow 312 1 02:00:00 2000000 "$L2" "node /w/node_modules/.bin/vitest run"
    fx_psrow 313 1 03:00:00 9000000 "$L2" "$OB"
    fx_psrow 314 1 05:00 5000000 "$L2" "node (vitest 3)"
    fx_psrow 315 1 01:00:00 200000 "$L2" "mytool --serve"
    fx_psrow 316 1 01:00:00 200000 "$L2" "node /w/other.js"
    fx_psrow 317 1 01:00:00 200000 "$L2" "node (vitest 3)"
    fx_psrow 340 120 01:00:00 5000000 "$L2" "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend"
    fx_psrow 341 120 01:00:00 5000000 "$L2" "mytool --serve"
    fx_psrow 342 120 01:00:00 5000000 "$L2" "node /w/srv.js"
    fx_psrow 343 120 01:00:00 5000000 "$L2" "/Applications/Xcode.app/Contents/Developer/usr/bin/node /w/x.js"
    fx_psrow 350 1 03:00:00 100000 "$L2" "node /w/devserver.js"
    fx_psrow 360 111 01:00:00 10000 "$L2" "node $P/worktrees/y/run.js"
  } >> "$F/ps.txt"
  sed -n '/^ *3[0-9][0-9] /p' "$F/ps.txt" >> "$F/ps.recheck"   # the -p re-read stub answers from ps.recheck
  {
    echo "  300 node (vitest 3)"
    echo "  301 node (vitest 4)"
    echo "  310 node (vitest 3)"
    echo "  311 node (vitest 3)"
    echo "  312 node PATH=/usr/bin PASEO_AGENT_ID=$A_YOUNG PASEO_HOME=$P PASEO_AGENT_CWD=/w"
    echo "  313 $OB PATH=/usr/bin PASEO_AGENT_ID=$A_YOUNG PASEO_HOME=$P"
    echo "  314 node (vitest 3)"
    echo "  315 mytool --serve PATH=/usr/bin PASEO_AGENT_ID=$A_YOUNG PASEO_HOME=$P"
    echo "  316 node PATH=/usr/bin PASEO_AGENT_ID=$A_YOUNG PASEO_HOME=/somewhere/else"
    echo "  317 node (vitest 3)"
    echo "  350 node PATH=/usr/bin PASEO_AGENT_ID=$A_LIVE PASEO_HOME=$P"
  } >> "$F/env.txt"
  printf '%s\n' '300    5000M  100M' '301    500M   50M' '310    4500M  50M' '311    200M   50M' '312    2000M  50M' '313    9000M  50M' \
    '314    5000M  50M' '315    200M   50M' '316    200M   50M' '317    200M   50M' \
    '340    5000M  50M' '341    5000M  50M' '342    5000M  50M' '343    5000M  50M' '350    100M   10M' '360    10M    1M' >> "$F/top.txt"

  # the lineage ledger record wrote (pid, lstart, comm, owner, first-seen, orphaned-at); 311's lstart is stale, 314 was orphaned 5 min ago,
  # 350 belongs to the live agent A_LIVE, 312 has no row (env proof only: record adds one)
  printf '310\t%s\tnode\t%s\t1789990000\t%s\t/opt/homebrew/bin/node\n311\t%s\tnode\t%s\t1789990000\t%s\t/opt/homebrew/bin/node\n314\t%s\tnode\t%s\t1789990000\t%s\t/opt/homebrew/bin/node\n315\t%s\tmytool\t%s\t1789990000\t%s\t/usr/local/bin/mytool\n350\t%s\tnode\t%s\t1789990000\t%s\t/opt/homebrew/bin/node\n' \
    "$L2" "$A_YOUNG" $((FX_NOW - 3600)) "$L2" "$A_YOUNG" $((FX_NOW - 3600)) "$L2" "$A_YOUNG" $((FX_NOW - 300)) \
    "$L2" "$A_YOUNG" $((FX_NOW - 3600)) "$L2" "$A_LIVE" $((FX_NOW - 7200)) > "$FX_STATE/lineage.tsv"
  local n
  for n in 300 301 310 311 312 314 350; do printf '/opt/homebrew/bin/node\n' > "$F/txt.$n"; done
  printf '/usr/local/bin/mytool\n' > "$F/txt.315"
  printf '/Applications/Foo.app/Contents/MacOS/node\n' > "$F/txt.342"   # argv is harmless, the real executable is inside an .app
  chmod 600 "$FX_STATE/lineage.tsv"
  P="$(cd -P "$P" && pwd -P)"
  printf '%s' "$P/worktrees/abcd1234/dirty" > "$F/cwd.317"
  printf '%s' "$P/worktrees/abcd1234/dirty" > "$F/cwd.310"
}

# lean variant for kill tests: B1b fixtures without the legacy garbage records / legacy orphans (fewer actions, fewer rechecks)
fx_lean() {
  fx_orphans
  rm -f "$FX_PHOME"/schedules/0000000[ab].json
  find "$FX_PHOME/agents" -type f \( -name "$A_GC1.json" -o -name "$A_GC2.json" \) -exec rm -f {} +
  sed -E -i.b '/^ *(122|125|130|190) /d' "$FX_FIX/ps.txt" "$FX_FIX/ps.recheck"; rm -f "$FX_FIX/ps.txt.b" "$FX_FIX/ps.recheck.b"
}

# more orphan cases (each test that needs them calls fx_more after fx_orphans; ledger rows: pid lstart comm owner first orphaned exe)
#   318 retitled `node`, real exe inside OrbStack.app   319 exe differs from the one recorded (poisoned row)
#   351 owner A_GC1 (an archived, otherwise garbage agent)   352 owner pid:190@... (the invoker's child)   353 worker under claude 190, 5000 MB
#   371 owner A_CLOSEDU (unarchived, no child: not dead for a ledger-only proof)   372 owner "garbage" (bad syntax)   373 first-seen in the far future
fx_more() {
  local F="$FX_FIX" L2="Wed Sep 30 09:00:00 2026" o=$((FX_NOW - 3600))
  {
    fx_psrow 318 1 03:00:00 200000 "$L2" "node (helper)"
    fx_psrow 319 1 03:00:00 200000 "$L2" "node old.js"
    fx_psrow 351 1 03:00:00 200000 "$L2" "node z.js"
    fx_psrow 352 1 03:00:00 200000 "$L2" "node inv.js"
    fx_psrow 353 190 01:00:00 5000000 "$L2" "node sub.js"
    fx_psrow 371 1 03:00:00 200000 "$L2" "node closedu.js"
    fx_psrow 372 1 03:00:00 200000 "$L2" "node bad1.js"
    fx_psrow 373 1 03:00:00 200000 "$L2" "node bad2.js"
    fx_psrow 374 1 03:00:00 200000 "$L2" "node unknown-owner.js"
    fx_psrow 375 1 03:00:00 200000 "$L2" "node second.js"
    fx_psrow 376 1 03:00:00 200000 "$L2" "node stale-owner.js"
    fx_psrow 377 1 03:00:00 200000 "$L2" "node contradict.js"
  } | tee -a "$F/ps.txt" >> "$F/ps.recheck"
  local n; for n in 318 319 351 352 353 371 372 373 374 375 376; do echo "  $n node (noenv)" >> "$F/env.txt"; done
  printf '%s\n' '318    200M   10M' '319    200M   10M' '351    200M   10M' '352    200M   10M' '353    5000M  10M' '371    200M   10M' '372    200M   10M' '373    200M   10M' '374    200M   10M' '375    200M   10M' '376    200M   10M' '377    200M   10M' >> "$F/top.txt"
  echo "  377 node PATH=/usr/bin PASEO_AGENT_ID=$A_LIVE PASEO_HOME=$FX_PHOME" >> "$F/env.txt"
  printf '/Applications/OrbStack.app/Contents/MacOS/OrbStack\n' > "$F/txt.318"
  printf '/usr/local/bin/node\n' > "$F/txt.319"     # the ledger recorded /opt/homebrew/bin/node
  for n in 351 352 353 371 372 373 374 375 376 377; do printf '/opt/homebrew/bin/node\n' > "$F/txt.$n"; done
  {
    printf '318\t%s\tnode\t%s\t1789990000\t%s\t/Applications/OrbStack.app/Contents/MacOS/OrbStack\n' "$L2" "$A_YOUNG" "$o"
    printf '319\t%s\tnode\t%s\t1789990000\t%s\t/opt/homebrew/bin/node\n' "$L2" "$A_YOUNG" "$o"
    printf '351\t%s\tnode\t%s\t1789990000\t%s\t/opt/homebrew/bin/node\n' "$L2" "$A_GC1" "$o"
    printf '352\t%s\tnode\tpid:190@%s\t1789990000\t%s\t/opt/homebrew/bin/node\n' "$L2" "$L2" "$o"
    printf '371\t%s\tnode\t%s\t1789990000\t%s\t/opt/homebrew/bin/node\n' "$L2" "$A_CLOSEDU" "$o"
    printf '372\t%s\tnode\tnot-a-uuid\t1789990000\t%s\t/opt/homebrew/bin/node\n' "$L2" "$o"
    printf '374\t%s\tnode\t%s\t1789990000\t%s\t/opt/homebrew/bin/node\n' "$L2" "$A_MISSING" "$o"
    printf '375\t%s\tnode\t%s\t1789990000\t%s\t/opt/homebrew/bin/node\n' "$L2" "$A_YOUNG" "$o"
    printf '376\t%s\tnode\t%s\t1789990000\t%s\t/opt/homebrew/bin/node\n' "$L2" "$A_STALE" "$o"
    printf '377\t%s\tnode\t%s\t1789990000\t%s\t/opt/homebrew/bin/node\n' "$L2" "$A_YOUNG" "$o"
    printf '373\t%s\tnode\t%s\t2999999999\t2999999999\t/opt/homebrew/bin/node\n' "$L2" "$A_YOUNG"
  } >> "$FX_STATE/lineage.tsv"
}
