# Contributing

`scripts/validate.sh` enforces the plugin's core invariants. Run it before
pushing: `bash scripts/validate.sh`.

Invariants it checks:

- SKILL.md frontmatter: valid YAML, exactly `name`/`description`,
  `name == "supervisor"`, one-line description mentioning `create_agent`,
  supervisor, orchestrate, delegate.
- The `🕒` eval grader regexes are proven against emoji-tree positive and negative
  samples (`scripts/test-room-state-graders.py`).
- Room files (`skills/supervisor/SKILL.md`, `PROTOCOL.md`, `roles/lead.md`,
  `roles/peer.md`) exist and keep their contract phrases: `create_agent`,
  the ban on the built-in `Agent` tool, `list_profiles`, the heartbeat
  create/delete, the intent record / on-course checks / emergency brake,
  the Expensive-peer (opus) gut-feeling ban, `Review peer`,
  the debate signals, the recap contract, `$ARGUMENTS`.
- Wait / state rules (static): `SKILL.md` names `slp-wait`, carries the three
  room-state prefixes (`🕒 Working`, `✅ Done:`, `❓ Waiting on you:`), the
  `🤖` (column 0) / `🦾` (`&emsp;&ensp;`-indented) tree form of the `🕒` block under its
  `-------------` line, the
  fixed-name `supervisor: room` find-or-create and adoption rule, and has no
  instruction to reply with a bare no-change line or to reuse a heartbeat via
  `list_schedules`; `PROTOCOL.md`, `lead.md`, and `peer.md` keep the
  Supervisor-only `slp-wait` rules and the Lead's DONE-only-with-no-Peer-running
  rule; `lead.md` names no `slp-wait`; the wait timeout is within 30-120 s.
- Room-state indent: to change it, edit `SEPARATOR` and `PEER_INDENT` in
  `scripts/test-room-state-graders.py` and replace the literal in the files its
  `consistency` checks list; `validate.sh` fails while any of them disagrees.
- `.claude-plugin/plugin.json` + `marketplace.json`: valid JSON, matching
  `name`, semver `version`, and `description`.
- `paseo/config.snippet.json`: exactly the `Supervisor`/`Lead`/`Cheap peer`/
  `Peer`/`Expensive peer`/`Review peer`/`Codex peer`/`Codex review peer`
  profiles; Supervisor and Lead on `claude`; Claude Peers on `claude-peer`
  (disables `create_agent`); Codex Peers on `codex-peer` (extends `codex`,
  `paseoTools.enabled: false`).
- `install.sh` (the one install/update script): valid syntax/lint; builds a
  Claude runtime per Lead/Peer seat (role as output style, the user's
  settings with this plugin disabled, every skill but `supervisor`) and the
  Codex launcher (`-c developer_instructions` before `app-server`); puts the
  token from `oauth-token` into the provider env, or drops the key without
  one; leaves no `@@` placeholder and keeps the config at mode 600; migrates
  a v1 config — resets the room's profiles/providers, removes v1 profiles
  and `claude-worker`, keeps the user's own, idempotent; `--skill-only`
  installs only the skill; piped, it installs from the repository tarball.
  Tests always pass `--no-reload`.
- Seats: every Lead/Peer profile runs full access (Claude
  `bypassPermissions`, Codex `full-access`); `claude-lead`/`claude-peer` set
  `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_OAUTH_TOKEN`, `codex-peer` uses its
  launcher; Peer providers keep
  `send_agent_prompt` and disable `create_agent` and schedule control.
- `slp-wait`: installed at `$HOME/.config/slp-room/bin/slp-wait` (0755),
  behaves per its contract (seconds 30-120, whole-scalar ID checks) against a stub `paseo`, and only the Supervisor
  may run it: `claude-lead` and `claude-peer` deny it by basename and by the
  rendered absolute path (Codex Peers by execpolicy). The rendered Supervisor
  prompt names that path (the `@@SLP_WAIT@@` token, replaced by
  `install.sh`), it exists in the temp install, and no token is left; the
  rendered Lead prompt names no `slp-wait`, and `claude-lead`'s other denies
  (whole `Bash(paseo:*)` included) stay main's.
- `README.md`: keeps `## Install`/`## Usage`/`## Troubleshooting` and
  mentions `/supervisor`.
- `.release-please-manifest.json`: `.["."]` matches plugin.json `.version`.

PRs need the `validate` check green before merge.

Run `claude plugin eval . --trust-plugin` after changing SKILL.md's description or rules.
The role files in `skills/supervisor/roles/` are read by Leads and Peers at
launch — keep them consistent with `PROTOCOL.md` when either changes. Never
loosen the provider denies to make a wait work: the Supervisor waits through
`slp-wait`, never `paseo wait` directly; Leads and Peers end their turns and
rely on notifications.

Commits must follow [Conventional Commits](https://www.conventionalcommits.org/):
`feat:` bumps minor, `fix:`/`docs:`/`chore:` bump patch, `feat!:` or a
`BREAKING CHANGE` footer bumps major. release-please opens/updates a
`chore(main): release X.Y.Z` PR from these commits; merging it bumps both
`.claude-plugin` JSON files, `version.txt`, tags `vX.Y.Z`, and publishes the
GitHub Release. Do not hand-edit versions.
