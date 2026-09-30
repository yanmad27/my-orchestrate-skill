#!/usr/bin/env python3
"""Prove the 🕒 emoji-tree grader regexes with positive and negative samples.

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


E = "\u2003"
L2, P4 = E * 2, E * 4
CARD_A = L2 + "🤖 auth refactor · reviewing token store diff\n" + P4 + "🦾 token store · reading the store\n" + P4 + "🦾 token store diff · checking the diff"
CARD_B = L2 + "🤖 billing export · STATUS: waiting on CI\n" + P4 + "🦾 csv writer · writing rows (permission pending)"
CARD_C = L2 + "🤖 search index · resuming"
CARD_D = L2 + "🤖 docs · idle"
CARD_E = L2 + "🤖 docs · running the changelog pass · then publish"
HDR = "🕒 Working\n"
BLOCKS_OK = [
    HDR + CARD_A,
    HDR + CARD_A + "\n" + CARD_B + "\n" + CARD_C,
    HDR + CARD_D,
    HDR + CARD_E,
    HDR + CARD_B + "\n" + CARD_D + "\n",
    HDR + CARD_A + "  \n" + CARD_D + "\n\n",
]
OLD_CARDS = "⏳ Working:\n◉ auth refactor · running\n  Now: reviewing diff · Peers: token store\n\n◉ billing export · STATUS: waiting on CI\n  Peers: csv writer (permission pending)"
BLOCKS_BAD = [
    OLD_CARDS,
    "⏳ Working:\n" + CARD_A,
    HDR + "◉ docs · running\n  Now: x",
    HDR + "[Lead] auth refactor (running)\n↳ [Peer] token store (running)",
    HDR + "[Lead] docs (running)\n├─ [Peer] readme (running)",
    "🕒 Working:\n" + CARD_A,
    HDR + CARD_A + "\n\n" + CARD_D,
    HDR + "\n" + CARD_D,
    HDR + "  🤖 docs · running",
    HDR + "🤖 docs · running",
    HDR + "\u00a0\u00a0🤖 docs · running",
    HDR + L2 + "🤖 docs · running\n    🦾 readme · editing",
    HDR + L2 + "🤖 docs · running\n" + E * 3 + "🦾 readme · editing",
    HDR + L2 + "🤖 docs · running\n" + E * 5 + "🦾 readme · editing",
    HDR + L2 + "🤖 docs · running\n" + P4 + "🦾 readme",
    HDR + L2 + "🤖 docs running",
    HDR + L2 + "🤖  · running",
    HDR + L2 + "🤖 docs · ",
    HDR + P4 + "🦾 readme · editing\n" + CARD_D,
    HDR + L2 + "🤖 docs · running\n" + L2 + "🦾 readme · editing",
    HDR + L2 + "🤖 docs · running\n" + P4 + "🤖 docs · running",
    HDR + L2 + "🤖 docs · running\n" + P4 + "Peers: readme",
    HDR + L2 + "🤖 docs · running\n  Now: checking",
    HDR + CARD_A + "\n" + P4 + "◉ card",
    "prefix " + HDR + CARD_A,
    "**" + HDR + CARD_A,
    "```text\n" + HDR + CARD_A,
    "```\n" + HDR + CARD_A,
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
check("heartbeat", not match("heartbeat", PRE + HDR + CARD_A + "\n" + L2 + "🤖 half"), "negative malformed trailing Lead row")

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
    "Lead separators, bad Peer row": HDR + L2 + "🤖 " + SEP + "\n" + P4 + "🦾 a",
    "Lead description separators, trailing prose": HDR + L2 + "🤖 docs · " + SEP + "\nprose",
    "Peer name separators, trailing prose": HDR + CARD_D + "\n" + P4 + "🦾 " + SEP + "\nprose",
    "Peer description separators, trailing prose": HDR + CARD_D + "\n" + P4 + "🦾 a · " + SEP + "\nprose",
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
