---
tags: [behaviour]
allowed_tools: [Skill, Agent, Bash, Read, Glob, Grep]
---

orchestrate: open a PR for the current branch and tell me when the CI check passes. You are the Supervisor: whenever you have to wait on a running room agent, do it with the room's slp-wait helper (110 s, one call per wait).
