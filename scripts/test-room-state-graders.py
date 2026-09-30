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


SEPARATOR = "\n-------------\n"
PEER_INDENT = "&emsp;&ensp;"
LEAD = ""
RAW = "\u2003\u2002"  # negative fixtures only: raw Unicode spaces are not the taught form
TITLE = "🕒 Working"
HDR = TITLE + SEPARATOR
CARD_A = LEAD + "🤖 auth refactor · reviewing token store diff\n" + PEER_INDENT + "🦾 token store · reading the store (permission pending)\n" + PEER_INDENT + "🦾 token store diff · checking the diff"
CARD_B = LEAD + "🤖 billing export · STATUS: waiting on CI\n" + PEER_INDENT + "🦾 csv writer · writing rows (permission pending)"
CARD_C = LEAD + "🤖 search index · resuming"
CARD_D = LEAD + "🤖 docs · idle"
CARD_E = LEAD + "🤖 docs · running the changelog pass · then publish"
BLOCKS_OK = [
    HDR + CARD_A,
    HDR + CARD_A + "\n" + CARD_B + "\n" + CARD_C,
    HDR + CARD_D,
    HDR + CARD_E,
    HDR + CARD_B + "\n" + CARD_D + "\n",
    HDR + CARD_A + "  \n" + CARD_D + "\n\n",
]
OLD_CARDS = "⏳ Working:\n◉ auth refactor · running\n  Now: reviewing diff · Peers: token store\n\n◉ billing export · STATUS: waiting on CI\n  Peers: csv writer (permission pending)"
WRONG_PEER_INDENTS = [
    w for w in (
        "&emsp;&emsp;", "&ensp;&emsp;", "&emsp;", "&ensp;", "&emsp;" * 4, "&emsp;&emsp;&ensp;",
        PEER_INDENT + "&ensp;", PEER_INDENT + PEER_INDENT, "&amp;" + PEER_INDENT[1:],
        "&emsp; &ensp;", "&nbsp;&nbsp;", RAW, "  ", "    ", "\t", "\u00a0\u00a0",
    ) if w != PEER_INDENT
]
ROW = "🦾 readme · editing"
BLOCKS_BAD = [
    OLD_CARDS,
    "⏳ Working:\n" + CARD_A,
    TITLE + "\n" + CARD_A,
    TITLE + ":" + SEPARATOR + CARD_A,
    TITLE + "\n---\n" + CARD_A,
    TITLE + "\n" + "-" * 14 + "\n" + CARD_A,
    TITLE + "\n" + "-" * 12 + "\n" + CARD_A,
    TITLE + "\n=============\n" + CARD_A,
    TITLE + "\n\n-------------\n" + CARD_A,
    TITLE + "\n-------------\n\n" + CARD_A,
    TITLE + "\n ------------\n" + CARD_A,
    HDR + "  🤖 docs · running",
    HDR + "&emsp;🤖 docs · running",
    HDR + PEER_INDENT + "🤖 docs · running",
    HDR + PEER_INDENT + "🤖 docs · running\n" + PEER_INDENT + ROW,
    HDR + RAW + "🤖 docs · running",
    HDR + "\u00a0\u00a0🤖 docs · running",
    HDR + "\t🤖 docs · running",
    HDR + "🤖 docs · running\n" + ROW,
    HDR + "🤖 docs · running\n🦾 readme",
    HDR + "🤖 docs · running\n" + LEAD + ROW + "\n" + PEER_INDENT + ROW,
    HDR + "◉ docs · running\n  Now: x",
    HDR + "[Lead] auth refactor (running)\n↳ [Peer] token store (running)",
    HDR + "[Lead] docs (running)\n├─ [Peer] readme (running)",
    "🕒 Working:" + SEPARATOR + CARD_A,
    HDR + CARD_A + "\n\n" + CARD_D,
    HDR + "\n" + CARD_D,
    HDR + "🤖 docs running",
    HDR + "🤖  · running",
    HDR + "🤖 docs · ",
    HDR + PEER_INDENT + ROW + "\n" + CARD_D,
    HDR + "🤖 docs · running\n" + PEER_INDENT + "🤖 docs · running",
    HDR + "🤖 docs · running\n" + PEER_INDENT + "Peers: readme",
    HDR + "🤖 docs · running\n  Now: checking",
    HDR + CARD_A + "\n" + PEER_INDENT + "◉ card",
    "prefix " + HDR + CARD_A,
    "**" + HDR + CARD_A,
    "```text\n" + HDR + CARD_A,
    "```\n" + HDR + CARD_A,
    "```text\n" + HDR + CARD_A + "\n```",
    "```\n" + HDR + CARD_A + "\n```",
]
for opener in ("```markdown", "````", "~~~", "~~~text", "```text", "   ```text", "```"):
    BLOCKS_BAD.append(opener + "\n" + HDR + CARD_A)
    BLOCKS_BAD.append("intro\n" + opener + "\r\n" + HDR + CARD_A)
for w in WRONG_PEER_INDENTS:
    BLOCKS_BAD.append(HDR + "🤖 docs · running\n" + w + ROW)
    BLOCKS_BAD.append(HDR + CARD_A + "\n" + CARD_B.replace(PEER_INDENT, w))
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
check("heartbeat", not match("heartbeat", PRE + HDR + CARD_A + "\n" + LEAD + "🤖 half"), "negative malformed trailing Lead row")

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
    "Lead separators, bad Peer row": HDR + LEAD + "🤖 " + SEP + "\n" + PEER_INDENT + "🦾 a",
    "Lead description separators, trailing prose": HDR + LEAD + "🤖 docs · " + SEP + "\nprose",
    "Peer name separators, trailing prose": HDR + CARD_D + "\n" + PEER_INDENT + "🦾 " + SEP + "\nprose",
    "Peer description separators, trailing prose": HDR + CARD_D + "\n" + PEER_INDENT + "🦾 a · " + SEP + "\nprose",
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




# Consistency: every file that teaches, exemplifies or grades the block must use
# SEPARATOR and PEER_INDENT as defined above, and no indent for 🤖 rows.
DOCS = [
    "skills/supervisor/PROTOCOL.md",
    "skills/supervisor/SKILL.md",
    "README.md",
    "CONTRIBUTING.md",
    "evals/README.md",
]
ENTITY = r"&[A-Za-z0-9#]+;"
ALLOWED = set(re.findall(ENTITY, PEER_INDENT))
EXPECT = {"🤖": LEAD, "🦾": PEER_INDENT}
RAW_SPACES = re.compile("[\\u2002\\u2003]")


SEP_LINE = SEPARATOR.strip("\n")


def check_file(rel, text):
    check("consistency", not RAW_SPACES.search(text), f"{rel} has no raw U+2002/U+2003")
    runs = sorted({r for r in re.findall(r"(?:&[A-Za-z0-9#]+;)+", text) if r != PEER_INDENT})
    check("consistency", not runs, f"{rel} writes every entity run as PEER_INDENT (others: {runs})")
    dashes = sorted({d for d in re.findall(r"`(-{3,})`", text) if d != SEP_LINE})
    check("consistency", not dashes, f"{rel} writes every quoted dash line as SEPARATOR (others: {dashes})")
    counts = sorted({n for n in re.findall(r"(\d+) dashes", text) if int(n) != len(SEP_LINE)})
    check("consistency", not counts, f"{rel} states {len(SEP_LINE)} dashes wherever it gives a count (others: {counts})")


for rel in DOCS:
    text = (ROOT / rel).read_text(encoding="utf-8")
    check_file(rel, text)
    check("consistency", PEER_INDENT in text, f"{rel} mentions PEER_INDENT {PEER_INDENT}")
    rows = re.findall(r"^((?:&[A-Za-z0-9#]+;)*)([🤖🦾]) ", text, re.M)
    wrong = [(p, m) for p, m in rows if p != EXPECT[m]]
    check("consistency", not wrong, f"{rel} tree rows use the constants (wrong: {wrong[:2]})")
    heads = [m.end() for m in re.finditer(r"^" + TITLE + r"(?=\n)", text, re.M)]
    check("consistency", all(text.startswith(SEPARATOR, h) for h in heads), f"{rel} follows every header row with SEPARATOR")
    if rel.endswith(("PROTOCOL.md", "SKILL.md", "CONTRIBUTING.md")):
        check("consistency", SEP_LINE in text, f"{rel} states the SEPARATOR line {SEP_LINE}")
    stray = re.findall(r"^[ \t ]+[🤖🦾] ", text, re.M)
    check("consistency", not stray, f"{rel} has no space-indented tree rows")
    if rel.endswith(("PROTOCOL.md", "SKILL.md")):
        check("consistency", {m for _, m in rows} == {"🤖", "🦾"}, f"{rel} exemplifies both 🤖 and 🦾 rows")
        check("consistency", TITLE + SEPARATOR + "🤖" in text, f"{rel} shows the header, SEPARATOR, then a 🤖 row")

SEP_PAT = TITLE + r"[ \t]*" + SEPARATOR.replace("\n", r"\n") + "🤖 "
for key, rel in G.items():
    text = (ROOT / rel).read_text(encoding="utf-8")
    check_file(rel, text)
    if key == "norearm":
        continue
    check("consistency", SEP_PAT in text, f"{rel} requires the SEPARATOR between the header and the first 🤖 row")
    rows = re.findall(r"\\n((?:&[A-Za-z0-9#]+;)*)([🤖🦾]) \\S", text)
    total = len(re.findall(r"[🤖🦾] \\S", text))
    good = [m for p, m in rows if p == EXPECT[m]]
    check("consistency", len(rows) == total and len(good) == total and {"🤖", "🦾"} <= set(good),
          f"{rel} indents its 🤖/🦾 rows by the constants ({len(good)}/{total})")

print("FAILED" if fails else "ALL PASS", fails)
sys.exit(1 if fails else 0)
