# orchestrate eval suite

Run: `claude plugin eval . --trust-plugin --allow-tools Edit Write`
(Edit/Write must be granted so the `no-self-edit` case's checks are non-vacuous.)

Cases:

- `trigger-positive-*` (4): a prompt that should make the `orchestrate` skill
  fire — `tool_used: Skill` grader, matched by regex against the skill name.
- `trigger-negative-*` (3): a prompt that should NOT fire it — same grader
  with `min: 0, max: 0, arm: both` (this plugin has no `not_tool_used` type;
  `tool_used` with a zero range is the documented substitute).
- `behaviour-precondition-stop`: no Paseo `create_agent` tool exists in the
  eval sandbox, so the skill must print its exact stop message and never call
  the built-in `Agent` tool.
- `behaviour-no-self-edit`: given a delegation prompt, the skill must not
  call `Edit`/`Write` itself before delegating.
- `behaviour-no-polling`: given a prompt to open a PR and report when CI
  passes, no `Bash` call may match a sleep/poll-loop pattern
  (`\bsleep\b|\bpgrep\b|\buntil\b.*\bdo\b|\bfor\b.*\bsleep\b`) — `tool_used`
  with `input_match`, the same grader shape `trigger-positive-rename` uses
  to check `Skill` input.

The subagent-recap contract (Lead opens its report with a one-line recap per
worker, built from each worker's `RECAP:` line) is a post-delegation output
behaviour. The free sandbox has no `create_agent`, so the skill stops at the
precondition and no worker ever runs — a positive "must emit recap" eval can
never go green here. It is guarded instead by `scripts/validate.sh`
(`BODY_PHRASES`), which asserts the recap wording stays in `SKILL.md` on every
CI run, and exercised for real only on Paseo.

The watchdog (`skills/orchestrate/watchdog.mjs`, SUPERVISION) is post-delegation
too, so this sandbox never reaches it. `scripts/test-watchdog.mjs` covers its
logic instead: it runs the poller against a fake `paseo` CLI and checks stall
alerts and their repeat, pending permissions, no delivery into a lead turn,
lost finish notifications (fast path and `ALL ENDED` backstop), archived and
earlier-task workers, exit conditions, and idempotent `start`/`stop`. It runs
from `scripts/validate.sh` on every CI run.

Target: 100% pass rate on the `trigger-positive`/`trigger-negative` cases.
All graders are free (`tool_used`/`regex`) — no judge-model cost.

## Latest run (2026-09-22, v1.3.0, Claude Code 2.1.270)

8/9 cases at threshold 1.0, overall score 0.926, mean Δ +0.426, $5.99, 191s.

| case                          | score | Δ    |
| ------------------------------ | ----- | ---- |
| trigger-positive-rate-limiting | 1.00  | +1.00 |
| trigger-positive-vi-delegate   | 1.00  | +1.00 |
| trigger-positive-rename        | 1.00  | +1.00 |
| trigger-positive-parallel      | 0.33  | +0.33 |
| trigger-negative-bash-explain  | 1.00  | 0.00 |
| trigger-negative-haiku         | 1.00  | 0.00 |
| trigger-negative-merge-squash  | 1.00  | 0.00 |
| behaviour-precondition-stop    | 1.00  | +0.50 |
| behaviour-no-self-edit         | 1.00  | 0.00 |
| behaviour-no-polling           | not yet run | — |

`trigger-positive-parallel` ("split this across agents and run in parallel: update
README, add tests, fix lint") failed below threshold: 2/3 with-plugin runs never
called the `Skill` tool at all. The trace shows the model Globbing the (empty) eval
sandbox for README/test/lint files first, finding nothing, and stopping to ask the
user where the project is — it never got as far as choosing a skill. See the PR that
introduced this suite for a proposed `SKILL.md` description tweak.
