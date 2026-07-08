---
name: high-level
description: Explore a topic, codebase, system, document, tool, workflow, or unfamiliar concept and explain it succinctly at a high level for a user who does not want or need deep internals. Use when the user asks for a plain-language overview, "what is this?", "how does this work at a high level?", "help me understand", "explain without overwhelming me", "summarize the architecture", "give me the mental model", or similar broad orientation.
---

# High Level

Use this skill to turn available evidence into a short, clear explanation. Favor orientation over completeness.

## Core Rule

Explain the thing well enough that the user can reason about it or decide what to inspect next. Do not teach every internal detail, enumerate every file, or introduce more concepts than the user needs.

## Workflow

1. Identify the user's real object of curiosity: a repo, subsystem, feature, protocol, document, process, tool, error, or external topic.
2. Gather just enough evidence from the best available resources:
   - Prefer user-provided context, local files, READMEs, docs, diagrams, tests, config, package manifests, command help, logs, and source entry points.
   - Use official or primary sources for public systems, protocols, APIs, or current facts when local context is missing or likely stale.
   - Ask a concise clarifying question only when the target is missing or the answer would otherwise be materially misleading.
3. Build a mental model before answering:
   - What problem does this solve?
   - What are the 3-5 main moving parts?
   - What flows between those parts?
   - What details can safely be ignored on a first pass?
4. Answer at the user's altitude. Start broad, then add one layer of useful structure. Stop before turning the answer into a deep dive.
5. Name uncertainty plainly. Say what the evidence suggests and what was not inspected.

## Exploration Guidance

- Skim before diving. Look for names, entry points, boundaries, repeated concepts, and dependency direction.
- For codebases, inspect the README/docs first, then the file tree, package/build config, main entry points, and tests or examples. Avoid an exhaustive file-by-file tour.
- For unfamiliar domains, prefer reliable explanations from primary sources, then translate them into simpler language.
- For large systems, group details by responsibility rather than by implementation location.
- If a term is unavoidable, define it in one short phrase the first time it appears.
- Use analogies sparingly and only when they reduce complexity without distorting the truth.

## Output Shape

Default to a compact answer:

1. One-sentence gist.
2. A short plain-language explanation, usually 2-4 bullets or one tight paragraph.
3. The main moving parts, capped at about five.
4. What matters most or what to inspect next.

Include source references when they help the user trust the explanation, especially for local files, docs, or web sources. Do not include a long bibliography.

## Guardrails

- Do not dump raw research notes.
- Do not over-index on internal names, acronyms, directory structure, class names, or implementation details.
- Do not hide complexity by pretending it does not exist. Compress it honestly.
- Do not keep expanding the answer unless the user asks for more depth.
- Do not end with many open-ended follow-up questions. Offer one useful next step only when it clearly helps.
