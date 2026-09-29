# supervisor eval suite

Run: `claude plugin eval . --trust-plugin --allow-tools Edit Write`
(Edit/Write must be granted so the `no-self-edit` case's checks are non-vacuous.)

Cases:

- `trigger-positive-*` (5): a prompt that should make the `supervisor` skill
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
  passes (waiting, where needed, with `slp-wait`), no `Bash` call may sleep,
  poll, or loop (`sleep`, `pgrep`, `ps`, `until`/`while`/`for … do`), call
  `paseo wait` directly, wrap `slp-wait` in a loop, pass it a timeout above
  570, or run it without a Bash `timeout` of at least 30000 ms — all
  `tool_used` with `input_match`, the same grader shape `trigger-positive-rename`
  uses to check `Skill` input.
- `behaviour-wait-interruption`: told that an `slp-wait` returned the
  "user doesn't want to proceed / interrupted" text plus a Lead report, the
  answer must call it an event (not a refusal) and re-arm or resume, and no
  `sleep`/`pgrep`/`paseo wait` runs.
- `behaviour-wait-no-rearm`: told that `slp-wait` returned at once with no
  timeout and no state change, the seat must not call `slp-wait` again
  (`tool_used` max 0) and must report or decide instead.
- `behaviour-room-state-{heartbeat,launch,done,decision}`: the Supervisor's
  final message ends with exactly one room-state line as its last line —
  any of the three forms for a heartbeat wake, `❓ Waiting on you:` for the
  precondition stop of a launch and for `DECISION_NEEDED`, `✅ Done:` for a
  finished room — and a heartbeat wake is never a bare `no change`.
  `behaviour-precondition-stop` also asserts the `❓` line after its stop
  message.
- `behaviour-lead-done-with-peer`: a Lead with a Peer still running, asked
  whether it is done, reports `STATUS`, never `DONE`.
- `behaviour-heartbeat-find-or-create`: monitoring setup never calls
  `list_schedules`, `delete_heartbeat`, `delete_schedule`, or the CLI
  `paseo heartbeat create` / `paseo schedule delete`.

The sandbox has no Paseo tools, so the wait, room-state, DONE, and heartbeat
cases can only exercise the parts a free grader sees: what the model would
call, and the shape of its final message. The rules themselves are guarded
by `scripts/validate.sh` and exercised for real only on Paseo.

The recap contract (the Supervisor opens its report with one line per Lead
and its Peers, built from each Peer's `RECAP:` line) and the whole
Lead ⇄ Peer debate protocol are post-delegation behaviour. The free sandbox
has no `create_agent`, so the skill stops at the precondition and no Lead or
Peer ever runs — a positive eval for them can never go green here. They are
guarded instead by `scripts/validate.sh` (`ROOM_PHRASES`), which asserts the
contract wording stays in `SKILL.md`, `PROTOCOL.md`, and `roles/*.md` on
every CI run, and exercised for real only on Paseo.

Target: 100% pass rate on the `trigger-positive`/`trigger-negative` cases.
All graders are free (`tool_used`/`regex`) — no judge-model cost.

## Latest run (2026-09-22, v1.3.0 — the `orchestrate` skill, before the SLP rename)

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
