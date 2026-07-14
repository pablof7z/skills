---
title: Skills Project Contribution Workflow
slug: skills-project-contribution-workflow
topic: workflow
summary: Every non-trivial change in the skills project must point to a GitHub issue clarifying the need or want (not the implementation plan) and must be delivered thro
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

# Skills Project Contribution Workflow

## Skills Project Contribution Workflow

Every non-trivial change in the skills project must point to a GitHub issue clarifying the need or want (not the implementation plan) and must be delivered through a PR that is merged. Changes to the skills repo are developed in an isolated WorktreeGuard worktree based on `origin/main`, not the protected checkout; the protected checkout's pre-existing untracked drafts remain untouched during skill development. An independent `skill-creator` forward test runs against a synthetic target skill in a temporary directory and cannot edit the repository.

<!-- citations: [^019f5-9b7ce] [^019f5-b920c] -->
