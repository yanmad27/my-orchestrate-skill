#!/usr/bin/env python3
"""Prove the ⏳ card-form grader regexes with positive and negative samples.

Reads each grader's `pattern:` (Python `re`, as the eval harness runs it) and
checks it against samples. Exit 1 on any mismatch.
"""
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
G = {
    "heartbeat": "evals/behaviour-room-state-heartbeat/graders/last-line-is-room-state.md",
    "interruption": "evals/behaviour-wait-interruption/graders/room-state-line.md",
    "handoff": "evals/behaviour-wait-handoff/graders/never-done.md",
    "midrun": "evals/behaviour-wait-person-midrun/graders/answer-then-ends-on-working.md",
    "norearm": "evals/behaviour-wait-person-midrun/graders/no-rearm-after-working.md",
}


def load(key):
    text = (ROOT / G[key]).read_text(encoding="utf-8")
    m = re.search(r"^pattern: '(.*)'$", text, re.M)
    return re.compile(m.group(1))


CARD_A = "◉ auth refactor · running\n  Now: reviewing token store diff · Peers: token store, token store diff"
CARD_B = "◉ billing export · STATUS: waiting on CI\n  Peers: csv writer (permission pending)"
CARD_C = "◉ search index · resuming\n  Scope: platform"
CARD_D = "◉ docs · idle"
CARD_E = "◉ docs · running\n  Queue: changelog pass"
HDR = "⏳ Working:\n"
BLOCKS_OK = [
    HDR + CARD_A,
    HDR + CARD_A + "\n\n" + CARD_B + "\n\n" + CARD_C,
    HDR + CARD_D,
    HDR + CARD_E,
    HDR + CARD_B + "\n\n" + CARD_D + "\n",
    HDR + CARD_A + "  \n\n" + CARD_D + "\n\n",
]
OLD_TREE = HDR + "[Lead] auth refactor (running)\n↳ [Peer] token store (running)"
BLOCKS_BAD = [
    OLD_TREE,
    HDR + "[Lead] docs (running)\n├─ [Peer] readme (running)",
    HDR + CARD_A + "\n\n\n" + CARD_D,
    HDR + CARD_A + "\n" + CARD_D,
    HDR + "◉ docs running",
    HDR + "◉ docs · running\n    Now: x",
    HDR + "◉ docs · running\n  Foo: bar",
    HDR + "◉ docs · running\n  Now: a\n  Peers: b",
    HDR + CARD_A + "\n↳ [Peer] token store (running)",
    HDR + "◉  · running",
    HDR + "◉ docs · running\n  Peers: readme · Now: checking",
    HDR + "◉ docs · running\n  Now: checking · Queue: publish",
    HDR + "◉ docs · running\n  Now: a · b",
    HDR + "◉ docs · running\n  Now: a · Peers: b · c",
]
TRAIL = "\n\nThat is the current state."
BLANK_OK = HDR + CARD_A + "\n\n  \n\t\n"

fails = 0


def check(name, cond, label):
    global fails
    if not cond:
        fails += 1
    print(("ok   " if cond else "FAIL ") + name + ": " + label)


def match(key, s):
    return load(key).search(s) is not None


PRE = "Working on it; nothing has changed since the last checkpoint.\n"
for key in ("heartbeat", "handoff"):
    for i, b in enumerate(BLOCKS_OK):
        check(key, match(key, PRE + b), f"positive {i}")
    for i, b in enumerate(BLOCKS_BAD):
        check(key, not match(key, PRE + b), f"negative {i}")
    check(key, not match(key, PRE + HDR + CARD_A + "\n" + "✅ Done: x"), "negative ✅ after")
    check(key, not match(key, PRE + "✅ Done: x\n" + HDR + CARD_A), "negative ✅ before")
    check(key, not match(key, PRE + "no state here"), "negative no block")
    check(key, match(key, PRE + BLANK_OK), "positive trailing blank lines")
    for i, b in enumerate(BLOCKS_OK):
        check(key, not match(key, PRE + b + TRAIL), f"negative trailing prose {i}")
        check(key, not match(key, PRE + b + "\nTRAIL"), f"negative trailing prose, no blank {i}")
check("heartbeat", not match("heartbeat", PRE + HDR + CARD_A + "\n❓ Waiting on you: x"), "negative ❓")
check("heartbeat", not match("heartbeat", PRE + HDR + CARD_A + "\n\n◉ half"), "negative malformed trailing card")

key = "interruption"
for i, b in enumerate(BLOCKS_OK):
    check(key, match(key, "Peer finished.\n" + b), f"positive {i}")
for i, b in enumerate(BLOCKS_BAD):
    check(key, not match(key, "Peer finished.\n" + b), f"negative {i}")
check(key, match(key, "Peer finished.\n" + BLANK_OK), "positive trailing blank lines")
for i, b in enumerate(BLOCKS_OK):
    check(key, not match(key, "Peer finished.\n" + b + TRAIL), f"negative trailing prose {i}")
check(key, match(key, "x\n✅ Done: shipped"), "positive ✅ row")
check(key, match(key, "x\n❓ Waiting on you: push?"), "positive ❓ row")
check(key, not match(key, "x\n✅ Done:"), "negative empty ✅")

key = "midrun"
ANS = "About two minutes.\n\n"
for i, b in enumerate(BLOCKS_OK):
    check(key, match(key, ANS + b), f"positive {i}")
    check(key, not match(key, ANS + b + TRAIL), f"negative trailing prose {i}")
for i, b in enumerate(BLOCKS_BAD):
    check(key, not match(key, ANS + b), f"negative {i}")
check(key, not match(key, HDR + CARD_A), "negative no answer first")
check(key, not match(key, ANS + "✅ Done: x"), "negative ✅ end")
check(key, not match(key, ANS + "❓ Waiting on you: x"), "negative ❓ end")
check(key, not match(key, ANS + "answer\n" + HDR + CARD_A + "\n" + HDR + CARD_D), "negative two blocks")

check(key, match(key, ANS + BLANK_OK), "positive trailing blank lines")

SEP = "x · " * 10000
BIGS = {
    "line-1 separators, bad line 2": HDR + "◉ " + SEP + "\n  Peers: a · Now: b",
    "line-2 detail separators": HDR + "◉ docs · running\n  Now: " + SEP,
    "line-2 peers separators": HDR + "◉ docs · running\n  Now: a · Peers: " + SEP,
    "line-1 separators, trailing prose": HDR + "◉ " + SEP + "\nprose",
}
for k in ("heartbeat", "handoff", "interruption", "midrun"):
    pre = ANS if k == "midrun" else PRE
    for name, big in BIGS.items():
        t0 = time.perf_counter()
        r = match(k, pre + big)
        dt = time.perf_counter() - t0
        check(k, (not r) and dt < 0.5, f"malformed 10000-separator sample ({name}) rejected in {dt:.3f}s (<0.5s)")

key = "norearm"
check(key, match(key, ANS + HDR + CARD_A), "positive no re-arm")
check(key, not match(key, ANS + HDR + CARD_A + "\nre-arm slp-wait"), "negative re-arm text")
check(key, not match(key, ANS + HDR + CARD_A + "\nslp-wait 110"), "negative slp-wait call")

print("FAILED" if fails else "ALL PASS", fails)
sys.exit(1 if fails else 0)
