---
name: grill-with-docs
description: Compose /grilling + /domain-modeling to stress-test a design and capture the decisions as ADRs/glossary/docs in the same session. Explicit-only; distinct from /grilling, which interviews without writing docs.
disable-model-invocation: true
---

# Grill with Docs (explicit `/grill-with-docs` only)

Vendored composition skill (MIT, Matt Pocock — see `.claude/skills/ATTRIBUTIONS.md`). Runs a `/grilling` session while also invoking the `/domain-modeling` skill, so design stress-testing and doc/ADR/glossary capture happen together.

`disable-model-invocation: true` (mirroring `allow_implicit_invocation: false` in `agents/openai.yaml`) is deliberate: this compositional entry must be invoked explicitly as `/grill-with-docs` and must not auto-route, so it does not collide with `/grilling`. Use `/grilling` for pure stress-testing without doc capture; use `/grill-with-docs` when the decisions should also be written down as durable docs.
