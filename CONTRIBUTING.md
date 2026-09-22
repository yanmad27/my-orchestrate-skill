# Contributing

`scripts/validate.sh` enforces the plugin's core invariants. Run it before
pushing: `bash scripts/validate.sh`.

Invariants it checks:

- SKILL.md frontmatter: valid YAML, exactly `name`/`description`,
  `name == "orchestrate"`, one-line description mentioning `create_agent`,
  orchestrate, delegate.
- SKILL.md body keeps: `create_agent`, the ban on the built-in `Agent` tool,
  `list_profiles`, the Expensive-worker (opus) gut-feeling ban, `Reviewer`,
  `$ARGUMENTS`.
- `.claude-plugin/plugin.json` + `marketplace.json`: valid JSON, matching
  `name`, semver `version`, and `description`.
- `paseo/config.snippet.json`: exactly the `Lead`/`Cheap worker`/`Worker`/
  `Expensive worker`/`Reviewer` profiles and the `claude-worker` provider.
- `install.sh`: valid syntax/lint, works locally and piped.
- `README.md`: keeps `## Install`/`## Usage`/`## Troubleshooting` and
  mentions `/orchestrate`.
- `.release-please-manifest.json`: `.["."]` matches plugin.json `.version`.

PRs need the `validate` check green before merge.

Run `claude plugin eval . --trust-plugin` after changing SKILL.md's description or rules.

Commits must follow [Conventional Commits](https://www.conventionalcommits.org/):
`feat:` bumps minor, `fix:`/`docs:`/`chore:` bump patch, `feat!:` or a
`BREAKING CHANGE` footer bumps major. release-please opens/updates a
`chore(main): release X.Y.Z` PR from these commits; merging it bumps both
`.claude-plugin` JSON files, `version.txt`, tags `vX.Y.Z`, and publishes the
GitHub Release. Do not hand-edit versions.
