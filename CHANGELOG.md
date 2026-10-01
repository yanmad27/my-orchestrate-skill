# Changelog

## [2.4.0](https://github.com/yanmad27/paseo-slp/compare/v2.3.0...v2.4.0) (2026-10-01)


### Features

* deliver slp-gc memory alerts to the most recently used Supervisor, with person-approved cleanup ([#48](https://github.com/yanmad27/paseo-slp/issues/48)) ([fcc0040](https://github.com/yanmad27/paseo-slp/commit/fcc0040b9c4f0dd89f47ff8469db0e35d765ba27))
* render the Supervisor 🕒 Working room state as a 🤖 Lead / 🦾 Peer emoji tree ([#46](https://github.com/yanmad27/paseo-slp/issues/46)) ([c509778](https://github.com/yanmad27/paseo-slp/commit/c509778671c9d453cad6f74a4ccbad192fa96f96))

## [2.3.0](https://github.com/yanmad27/paseo-slp/compare/v2.2.0...v2.3.0) (2026-09-30)


### Features

* ↳ connector in the ⏳ room-state tree ([#42](https://github.com/yanmad27/paseo-slp/issues/42)) ([26541bc](https://github.com/yanmad27/paseo-slp/commit/26541bc6137da89267679828bf99d71ca57cbeed))
* box-drawing connectors (├─/└─) in the ⏳ room-state tree ([#41](https://github.com/yanmad27/paseo-slp/issues/41)) ([a7d82f7](https://github.com/yanmad27/paseo-slp/commit/a7d82f72ab43b975d8aa970f4161848ce658a37d))
* one compact ◉ card per Lead in the ⏳ room-state block ([#43](https://github.com/yanmad27/paseo-slp/issues/43)) ([278990b](https://github.com/yanmad27/paseo-slp/commit/278990b44cf8b02b12cc138418e10d5c425e0354))
* render the Supervisor ⏳ Working room state as a Lead/Peer tree ([#40](https://github.com/yanmad27/paseo-slp/issues/40)) ([ad2f3c9](https://github.com/yanmad27/paseo-slp/commit/ad2f3c9797b69930c501bd9b87343edd59f4c365))
* SLP_CLAUDE_AUTH_TOKEN as the primary custom-endpoint key input (SLP_CLAUDE_API_KEY kept as an alias) ([#38](https://github.com/yanmad27/paseo-slp/issues/38)) ([d734daa](https://github.com/yanmad27/paseo-slp/commit/d734daaa9aa08c2c5136d5d15c4486030a3ab585))
* slp-gc, a standalone Paseo GC and memory guard with a report-only launchd agent ([#44](https://github.com/yanmad27/paseo-slp/issues/44)) ([fddc7a3](https://github.com/yanmad27/paseo-slp/commit/fddc7a31b63487737e4577baa12abacd02bc05a2))

## [2.2.0](https://github.com/yanmad27/paseo-slp/compare/v2.1.0...v2.2.0) (2026-09-29)


### Features

* custom Anthropic-compatible endpoint as a second auth path for Claude seats ([#35](https://github.com/yanmad27/paseo-slp/issues/35)) ([3e463b3](https://github.com/yanmad27/paseo-slp/commit/3e463b3367b25bdbd288e0124bc477e7b4f0ae9c))

## [2.1.0](https://github.com/yanmad27/paseo-slp/compare/v2.0.1...v2.1.0) (2026-09-29)


### Features

* Supervisor-only running indicator, room-state line, and Lead DONE only with no Peer running ([#33](https://github.com/yanmad27/paseo-slp/issues/33)) ([fd5f648](https://github.com/yanmad27/paseo-slp/commit/fd5f6481b16bff1bdab1bc4e5beb2f29e82436f7))

## [2.0.1](https://github.com/yanmad27/paseo-slp/compare/v2.0.0...v2.0.1) (2026-09-29)


### Bug Fixes

* ask for the Claude token in install.sh instead of a clipboard dance ([#31](https://github.com/yanmad27/paseo-slp/issues/31)) ([121e2f1](https://github.com/yanmad27/paseo-slp/commit/121e2f16b4fc8ba2425356eb40ea516f33149a8e))

## [2.0.0](https://github.com/yanmad27/paseo-slp/compare/v1.9.0...v2.0.0) (2026-09-29)


### ⚠ BREAKING CHANGES

* /orchestrate is replaced by the Supervisor (profile or /supervisor); the project, marketplace, and plugin are renamed to paseo-slp (paseo-slp@paseo-slp); v1 worker profiles and the claude-worker provider are replaced, and install.sh now owns and resets the room's Paseo profiles and providers.

### Features

* paseo-slp — replace /orchestrate with a Supervisor → Lead → Peer room ([#29](https://github.com/yanmad27/paseo-slp/issues/29)) ([97d8596](https://github.com/yanmad27/paseo-slp/commit/97d8596551d0cab3b7a8eee6872fdd2e562544b5))

## [1.9.0](https://github.com/yanmad27/my-orchestrate-skill/compare/v1.8.0...v1.9.0) (2026-09-28)


### Features

* **orchestrate:** add committee, plan review and Codex advisor profile ([#25](https://github.com/yanmad27/my-orchestrate-skill/issues/25)) ([7aa099e](https://github.com/yanmad27/my-orchestrate-skill/commit/7aa099e42265909c859297337c8efa76767c353f))
* **orchestrate:** replace heartbeat watchdog with a token-free poller ([#23](https://github.com/yanmad27/my-orchestrate-skill/issues/23)) ([44beb32](https://github.com/yanmad27/my-orchestrate-skill/commit/44beb326322857cd594551d56d2730b7e6f54e0f))

## [1.8.0](https://github.com/yanmad27/my-orchestrate-skill/compare/v1.7.0...v1.8.0) (2026-09-24)


### Features

* **orchestrate:** run lead and worker profiles in bypassPermissions mode ([#20](https://github.com/yanmad27/my-orchestrate-skill/issues/20)) ([7fffb2f](https://github.com/yanmad27/my-orchestrate-skill/commit/7fffb2fa91e6d5216a1939e39e11ff2747899d91))
* **orchestrate:** size worker tasks to fit the 200k context ([#22](https://github.com/yanmad27/my-orchestrate-skill/issues/22)) ([ff6c4d7](https://github.com/yanmad27/my-orchestrate-skill/commit/ff6c4d7fffa61be9d87d21e05ea7f612c0a22980))

## [1.7.0](https://github.com/yanmad27/my-orchestrate-skill/compare/v1.6.0...v1.7.0) (2026-09-23)


### Features

* **orchestrate:** move opus profiles to Claude Opus 5.5 ([#17](https://github.com/yanmad27/my-orchestrate-skill/issues/17)) ([3e045eb](https://github.com/yanmad27/my-orchestrate-skill/commit/3e045ebb59c0bca1a6e55f643b82d16f3f0ad55d))

## [1.6.0](https://github.com/yanmad27/my-orchestrate-skill/compare/v1.5.0...v1.6.0) (2026-09-22)


### Features

* **orchestrate:** review runs on opus, pin opus profiles to Opus 5 ([#15](https://github.com/yanmad27/my-orchestrate-skill/issues/15)) ([67b81d0](https://github.com/yanmad27/my-orchestrate-skill/commit/67b81d001a0d174099d5a20cec1563f930ad1479))

## [1.5.0](https://github.com/yanmad27/my-orchestrate-skill/compare/v1.4.0...v1.5.0) (2026-09-22)


### Features

* **orchestrate:** Lead recaps each subagent's work in the final report ([#13](https://github.com/yanmad27/my-orchestrate-skill/issues/13)) ([8c39849](https://github.com/yanmad27/my-orchestrate-skill/commit/8c398492fadf208f5e65e89c9219c459d5cfa7a6))

## [1.4.0](https://github.com/yanmad27/my-orchestrate-skill/compare/v1.3.0...v1.4.0) (2026-09-22)


### Features

* **orchestrate:** hard never-poll rule for Lead and workers ([#11](https://github.com/yanmad27/my-orchestrate-skill/issues/11)) ([85cfbd0](https://github.com/yanmad27/my-orchestrate-skill/commit/85cfbd08ea7971829781c95d5ceb4053af85e139))


### Bug Fixes

* **orchestrate:** rename Experienced worker tier to Expensive worker ([#8](https://github.com/yanmad27/my-orchestrate-skill/issues/8)) ([f8aec7e](https://github.com/yanmad27/my-orchestrate-skill/commit/f8aec7ef6744a7818a65461fe07a9aa04a9d229c))

## [1.3.0](https://github.com/yanmad27/my-orchestrate-skill/compare/v1.2.1...v1.3.0) (2026-09-22)


### Features

* **orchestrate:** add Experienced worker (opus) tier selectable by Jev ([3b82346](https://github.com/yanmad27/my-orchestrate-skill/commit/3b823467783662a15d86925eb2a91b4761abf308))
* **orchestrate:** route worker tier and escalation via ask-jev ([f5a43c5](https://github.com/yanmad27/my-orchestrate-skill/commit/f5a43c59fd970ffd1dee19443ef8723be83d57b7))

## [1.2.1](https://github.com/yanmad27/my-orchestrate-skill/compare/v1.2.0...v1.2.1) (2026-09-21)


### Bug Fixes

* add missing id to managed agent profiles ([b25b3dc](https://github.com/yanmad27/my-orchestrate-skill/commit/b25b3dc03ef57170409c48c94bb6f5f6abd50eba))
* add missing id to managed agent profiles ([8e675f3](https://github.com/yanmad27/my-orchestrate-skill/commit/8e675f30ff688ca845d1edc8e0982b59660e8c52))
