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
  passes (the Supervisor waits, where needed, with `slp-wait`, 110 s), no
  `Bash` call may sleep, poll, or loop (`sleep`, `pgrep`, `ps`,
  `until`/`while`/`for … do`), call `paseo wait` directly, wrap `slp-wait` in
  a loop, pass it seconds other than 110 or above 120, or run it without the
  matching Bash `timeout` (exactly 140000 for 110; seconds×1000+30000 for any
  30–120, enumerated in `slp-wait-timeout-pair`) — all `tool_used` with
  `input_match`, the same grader shape `trigger-positive-rename` uses to
  check `Skill` input.
- `behaviour-wait-interruption`: told (as the Supervisor) that an `slp-wait`
  returned the "user doesn't want to proceed / interrupted" text because a
  Peer finished, the reply must call it an event (not a refusal), inspect or
  handle before it re-arms, and print a room-state block; no
  `sleep`/`pgrep`/`paseo wait` runs.
- `behaviour-wait-person-midrun`: a person asks a question while room work
  runs and the wait was interrupted; the reply text (not thinking) must give
  a visible answer first and END on the `🕒 Working` tree block — never `✅`/`❓`,
  and no `slp-wait` re-arm after it (text or Bash call): the heartbeat
  restarts the spin (normally within 2 minutes, rarely up to about 4).
- `behaviour-wait-handoff`: nothing in the room runs, but a Lead's latest
  report is a STATUS and its Peer just finished — the Supervisor re-reads
  the Lead's status and waits on it or prompts it (a `🕒` state, never
  `✅ Done`).
- `behaviour-wait-no-rearm`: told that `slp-wait` returned at once with no
  timeout and no state change, the Supervisor must not call `slp-wait` again
  (`tool_used` max 0) and must report or decide instead.
- `behaviour-room-state-{heartbeat,launch,done,decision}`: the Supervisor's
  final message carries the room-state block — a heartbeat wake with a running
  Lead shows `🕒` (never `✅`/`❓`, never a bare `no change`; the `🕒` is what
  precedes the re-arm), `❓ Waiting on you:` last for the precondition stop of
  a launch and for `DECISION_NEEDED`, `✅ Done:` last for a finished room.
  `behaviour-precondition-stop` also asserts the `❓` line after its stop
  message.
- `behaviour-lead-done-with-peer`: a Lead with a Peer still running, asked
  whether it is done, reports `STATUS`, never `DONE`.
- `behaviour-heartbeat-find-or-create`: monitoring setup never calls
  `list_schedules`, `delete_heartbeat`, `delete_schedule`, or the CLI
  `paseo heartbeat create` / `paseo schedule delete`; any `create_heartbeat`
  carries the fixed name `supervisor: room`, and the reply states that call
  (a regex on the reply, since the tool is unavailable).
- `behaviour-heartbeat-adoption`: a previous Supervisor, whose ID differs
  from the Supervisor's own, is still live; no `delete_heartbeat`,
  `delete_schedule`, or CLI schedule delete, the reply does not say it will
  create its own heartbeat (`create_heartbeat`), and it ends with a
  `❓ Waiting on you:` line.

The sandbox has no Paseo tools (and this suite builds no mocks of them), so
the wait, room-state, DONE, heartbeat, and adoption cases can only exercise the
parts a free grader sees: what the model would call, and what its message
states — where a tool cannot be called, the reply's stated action is graded
with a regex, which a fluent wrong answer can still satisfy. Negative
`tool_used` graders (max 0) are vacuous when the model calls nothing, and the
timeout/seconds pairing is only checked when a `slp-wait` call is made. The adoption grader (`no-own-heartbeat`) catches common affirmative
phrasings of "I will create my own heartbeat" only; free text cannot be
matched airtight. The rules themselves are guarded
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
