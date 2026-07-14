---
title: WorktreeGuard
slug: worktree-guard
topic: workflow
summary: WorktreeGuard is the plugin that blocks editing, branch-switching, or state mutation in a protected base checkout, while allowing mutations in Git worktrees out
tags:
  - capture
volatility: warm
confidence: medium
created: 2026-07-14
updated: 2026-07-14
verified: 2026-07-14
compiled-from: conversation
sources:
  - session:019f602b-b99a-7061-8567-f8a022393c67
  - session:019f605a-3fbe-7601-ac55-e5016574213a
---

# WorktreeGuard

## Purpose

WorktreeGuard is the plugin that blocks editing, branch-switching, or state mutation in a protected base checkout, while allowing mutations in Git worktrees outside that base.

<!-- citations: [^019f6-1db11] -->
## Linked-Worktree Commands

WorktreeGuard allows `git -C <linked-worktree>` commands, and its regression suite covers 66 policy decisions across both Codex and Claude harnesses (132 checked hook outcomes), including exact checks that every denial contains the tenex-edge channel guidance.

<!-- citations: [^019f6-4c257] [^019f6-2bba8] [^019f6-6ad49] -->
## Failure Mode — Missing workdir

When the Codex hook payload loses the `workdir` field (operation_workdir is empty), WorktreeGuard recovers a missing Codex hook `workdir` field so that linked-worktree operations are correctly allowed, while ambiguous cases remain conservatively denied.

<!-- citations: [^019f6-e8aa8] [^019f6-2bba8] -->

## Worktree Creation

The bundled `wtg` CLI no longer exposes a `create-worktree` subcommand; the guard-approved path for creating worktrees is native `git worktree add`. <!-- [^019f6-5a526] -->

## Requesting Base Access

When base access is truly required, WorktreeGuard can be bypassed via `wtg request-base-access --repo <repo> --reason <why> --scope session` to request human approval. <!-- [^019f6-c5cbd] -->

## Reporting Suspected False Positives

When an agent encounters a blocked action it believes should have worked (a suspected WorktreeGuard false positive / bug), and it has access to the tenex-edge fabric, it joins the `skills.worktree-guard` channel to report the suspected bug as an untagged note rather than tagging any agent. The tenex-edge fabric reporting step is conditional — the agent only attempts to join `skills.worktree-guard` when tenex-edge is available. Ordinary (non-suspected-false-positive) denials still follow the normal worktree/base-access path and do not trigger the fabric reporting step. <!-- [^019f6-958a6] -->

## Installation

WorktreeGuard is a plugin installed in both Codex and Claude with versioned caches and stable system shims that point to the deployed cache artifacts. <!-- [^019f6-2750f] -->
