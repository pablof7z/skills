---
title: Agent Skill Feedback
slug: agent-skill-feedback
topic: skills-feedback
summary: The agent-skill-feedback skill allows agents to provide feedback on skills they are using when a skill can be improved, specifically when the skill is confusing
tags:
  - capture
volatility: warm
confidence: medium
created: 2026-07-13
updated: 2026-07-13
verified: 2026-07-13
compiled-from: conversation
sources:
  - session:019f5a0e-b266-7f52-aa62-74683239dab4
  - session:019f5aea-906d-7321-885d-42735b77b4da
---

# Agent Skill Feedback

## Overview

The agent-skill-feedback skill allows agents to provide feedback on skills they are using when a skill can be improved, specifically when the skill is confusing. Feedback notes are stored under `~/.agents/skills/<skill-slug>/meta-feedback/`. The skill's internal metadata name is `meta-feedback` (renamed from `capture-skill-feedback`). The skill description is kept concise at 44 words. Matching UI metadata is provided via `agents/openai.yaml`.

<!-- citations: [^019f5-7460c] [^019f5-1fc86] -->
## Feedback Note Format

Feedback note file names use the sluggified title of the skill. Feedback notes enforce strict title rules to prevent drift. The feedback skill uses frontmatter. A deterministic recorder script ships with the skill to create and append feedback notes and reject duplicate incidents, producing valid `skill-feedback/v1` output.

<!-- citations: [^019f5-70567] [^019f5-ecd85] -->

## Quality and Validation

The `meta-feedback` skill's procedural guidance spans 175 lines, kept under the recommended size limit. Malformed UTF-8 punctuation (em dash) has been fixed. The skill passes the official skill-creator validator, behavioral tests, compilation, and an independent forward test. <!-- [^019f5-48cf8] -->
