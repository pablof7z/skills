---
name: prime-context
description: Load durable, sourced research about a topic into the current context. Use when the user says "prime context," asks an agent to investigate and remember a topic, wants prior topic research reused, or wants relevant discoveries preserved during the rest of the same session.
---

# Prime Context

Prime the calling agent with durable research owned by that agent. Delegate the
lookup and any missing research, then read the resulting notes yourself before
confirming what was loaded.

## Resolve ownership

1. Identify the calling agent before spawning a subagent. Prefer the stable
   `Agent` identity from runtime context; never use a session handle or the
   delegated subagent's identity.
2. Normalize the identity to lowercase `[a-z0-9._-]`, replacing other runs with
   `-`. Use `agent` only when no stable identity exists.
3. Resolve or create the caller's home with:

   ```bash
   ~/.agents/skills/agent-home/scripts/resolve-agent-home.sh <agent-id>
   ```

4. Use `<caller-home>/research` as the research root. Pass that exact absolute
   path to the subagent so it cannot accidentally write into its own home.

## Prime a topic

Derive a stable, lowercase hyphenated `topic-slug` from the subject. Keep it
broad enough that later research on the same subject lands together.

Spawn one subagent with the raw topic, caller identity, absolute research root,
topic slug, and current session identifier when available. Instruct it to:

1. Search the entire research root for prior entries that match the topic by
   directory name, `topic`, `aliases`, and note content. Do not assume an exact
   directory match is the only match. Treat a missing research root as no prior
   research, then create it before writing.
2. If relevant prior research exists, read it and return all relevant absolute
   note paths with a compact synthesis. Do not repeat the research merely to
   produce a fresh file.
3. If no relevant entry exists, investigate the topic. Prefer live primary
   sources and the real local surface the user named. Record uncertainty and
   distinguish sourced facts from inference. Verify that every cited source
   directly supports the finding attached to it.
4. Write the new research to:

   `<research-root>/<topic-slug>/<note-slug>/index.md`

   Choose a concise, specific `note-slug`; never overwrite an existing entry.
5. Return the exact written or reused paths and a compact synthesis.

Do not perform the delegated lookup in parallel with a second lookup. One
subagent owns the prior-entry decision and research write so two actors cannot
create duplicate notes.

## Note contract

Every note must contain YAML frontmatter followed by concise Markdown:

```markdown
---
topic: "Human-readable topic"
topic_slug: "stable-topic-slug"
slug: "specific-note-slug"
kind: "initial"
agent_id: "calling-agent-id"
session_id: "session-id-or-unknown"
created_at: "RFC-3339 timestamp"
updated_at: "RFC-3339 timestamp"
aliases:
  - "searchable alternate phrase"
sources:
  - title: "Source title"
    locator: "URL, absolute file path with lines, or exact command"
    type: "web"
    accessed_at: "RFC-3339 timestamp"
---

# Specific note title

## Findings

- Sourced finding.

## Relevance

- Why this matters to the investigated topic.

## Open questions

- Remaining uncertainty, or `None identified.`
```

Use `kind: "follow-up"` for later discoveries. Valid source types include
`web`, `file`, `command`, `document`, and `conversation`. Include at least one
source. Quote YAML strings when punctuation could make them ambiguous. Keep raw
excerpts short; synthesize instead of copying sources.

## Load and confirm

After the subagent returns:

1. Read every relevant note path yourself. Do not rely only on its synthesis.
2. Treat the topic as primed for the remainder of the current session.
3. Respond with two to five bullets confirming only the core understanding.
   Every bullet must contain between five and ten words. Keep each bullet terse;
   do not add explanations, citations, paths, or nested bullets.
4. Put the note path or paths on one short, unbulleted line after the bullets.
   Add one terse, unbulleted caveat only when research is stale or uncertain.
5. Do not dump the full research unless the user asks.

## Capture later discoveries

While the topic remains primed in the same session, notice materially relevant
new evidence encountered during other work. When it changes, extends, or
corrects the loaded understanding:

1. Create a sibling entry at
   `<research-root>/<topic-slug>/<new-note-slug>/index.md`.
2. Use `kind: "follow-up"`, the same `topic_slug`, the current session ID, and
   sources for the new evidence.
3. Keep the entry atomic: record only the new insight and its relationship to
   the primed topic. Do not duplicate an existing note.
4. Mention the captured follow-up in the next natural user-facing update.

Do not save incidental mentions, unsupported speculation, secrets, or private
credentials. Do not create project planning files; these are private agent
research notes only.
