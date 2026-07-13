---
name: meta-feedback
description: Record evidence-based feedback after using another skill. Use when real use exposes unclear, missing, stale, inefficient, rigid, or ineffective guidance, a trigger misfire, or a skill-caused correction. Create or append canonical issues in the target skill's meta-feedback directory; exclude speculative reviews and general editing.
---

# Meta Feedback

Capture actual friction as evidence about a skill, not as a verdict on its quality. Keep the user's current task primary.

Limit this skill to recording feedback. Do not edit the target skill, triage feedback, change issue status, or claim that an observation proves a particular fix.

## Decide whether to capture

Capture feedback only when all of these are true:

- Actually use or attempt to use the target skill in the current work.
- Observe a concrete ambiguity, contradiction, omission, stale assumption, inefficient instruction, failed trigger, harmful constraint, or grounded improvement opportunity.
- Attribute the friction plausibly to the skill rather than an unrelated tool failure, missing permission, or failure to follow clear instructions.
- Describe the context, expected or desired behavior, observed behavior, and practical impact.

Treat a user correction as strong evidence only when the behavior being corrected plausibly followed from the skill.

Do not capture:

- Speculation produced by reviewing a skill without using it.
- A stylistic preference with no effect on behavior or outcome.
- A model mistake already addressed clearly by the skill.
- A tool or environment failure the skill could not reasonably anticipate.
- A missing, unreadable, malformed, or misnamed user input when the target skill does not explicitly promise to locate, repair, validate, or recover it. Treat this as a task-input failure even when the skill does not define a fallback.
- A generic edge case whose handling follows ordinary agent judgment rather than specialized behavior the skill claims to define.
- A content-free agreement with an existing issue.

## Locate the feedback directory

Read the target skill's `name` from its `SKILL.md` frontmatter and use that exact slug:

```text
~/.agents/skills/<skill-slug>/meta-feedback/
```

Require the target skill directory and its `SKILL.md` to exist. Do not fabricate a shadow skill directory merely to hold feedback.

Before writing, inspect every plausibly related issue in `meta-feedback/`. Do not infer issue identity from filenames alone.

## Choose between appending and creating

Append to an existing issue only when all three conditions hold:

1. The observations concern the same instruction, assumption, trigger boundary, or decision point.
2. They exhibit the same failure mode or missed opportunity.
3. They would plausibly be addressed by the same change.

Sharing a section, topic, or surface symptom is not sufficient. Create a separate issue when the underlying failure or likely correction is materially different.

Never create collision suffixes such as `-2`, `-new`, or `-alternative`. Read the candidate issue and either append to it or choose a genuinely distinct title.

## Write a canonical title

Treat the first valid title as the issue's permanent identity. Apply every rule:

- State one observable failure or missed capability.
- Use four to ten words.
- Use concise English ASCII text so every agent derives the same filename.
- Use sentence case without terminal punctuation.
- Use only letters, digits, spaces, and hyphens.
- Omit the target skill's name; the directory already supplies it.
- Omit dates, versions, agent names, severity labels, and incident-specific details.
- Avoid vague labels such as `feedback`, `issue`, `problem`, `confusing`, `bad`, `improve`, `misc`, and `other`.
- Describe the gap rather than prescribing a solution.

Good:

```text
Trigger excludes implicit continuation requests
Cleanup instruction has two possible scopes
Validation step assumes writable source files
```

Bad:

```text
Shape Product feedback 2
Improve the trigger
Confusing cleanup problem
```

Derive the filename mechanically:

1. Lowercase the title.
2. Replace every run of non-alphanumeric characters with one hyphen.
3. Remove leading and trailing hyphens.
4. Add `.md`.

Do not rename an existing issue while appending evidence. Correct an objective typo only when changing the frontmatter title and filename together, and only outside the ordinary capture workflow.

## Use the issue format

Create each issue with exactly this frontmatter:

```yaml
---
schema: "skill-feedback/v1"
title: "Trigger excludes implicit continuation requests"
skill: "shape-product"
status: "open"
created_at: "2026-07-13T07:20:00Z"
---
```

Use UTC timestamps. Reporters may create only `open` issues and must not alter the status of existing issues.

Follow the frontmatter with:

```markdown
# Trigger excludes implicit continuation requests

## Problem

Describe the stable skill-level gap in one to three sentences. Keep incident-specific evidence in observations.

## Observations

### 2026-07-13T07:20:00Z — agent-name

- Incident: `stable-local-identifier`
- Skill revision: `sha256:<SKILL.md-content-hash>`
- Context: What the agent was trying to accomplish.
- Expected behavior: What guidance or behavior was needed.
- Observed behavior: What the skill instructed, omitted, or caused.
- Impact: The resulting error, uncertainty, rework, cost, or missed capability.
- Workaround: What the agent did instead, or `None`.
- Suggested direction: An optional possibility, clearly separated from the evidence.
```

Keep the canonical problem neutral and stable. Never rewrite it to incorporate each new incident.

## Accumulate evidence correctly

- Add one observation per independent incident, not one per observing agent.
- Reuse an available incident identifier so the same run cannot masquerade as independent evidence.
- Make every observation self-contained enough for a maintainer to understand without the original conversation.
- Record the target `SKILL.md` revision because later observations may refer to different text.
- Add evidence even when an issue is marked resolved, but do not change its status; later review can decide whether it regressed.
- Do not add or maintain an observation counter. Derive weight from distinct observation entries and their evidence.
- Quote only the minimum necessary instruction text. Paraphrase user context and remove secrets, personal data, private paths, credentials, and unrelated content.

## Record the feedback

Prefer the bundled `scripts/record_feedback.py` because it validates titles, computes the skill revision, prevents duplicate incident identifiers, locks concurrent writes, and writes atomically.

Create a temporary JSON payload using a file-writing tool rather than interpolating untrusted text into a shell command:

```json
{
  "skill": "shape-product",
  "title": "Trigger excludes implicit continuation requests",
  "problem": "The trigger describes explicit references to prior work but omits common implicit continuation language.",
  "agent": "agent-name",
  "incident": "stable-local-identifier",
  "context": "The user requested continuation of an earlier requirements discussion.",
  "expected": "The skill should be selected for an implicit continuation request.",
  "observed": "The trigger did not cover the user's continuation language.",
  "impact": "The agent began discovery again and repeated settled questions.",
  "workaround": "The user explicitly named the skill.",
  "suggestion": "Cover common implicit continuation phrases in the trigger description."
}
```

Run from this skill's directory:

```bash
python3 scripts/record_feedback.py --payload /path/to/payload.json
```

Set `AGENT_SKILLS_ROOT` or pass `--skills-root` only when the environment intentionally stores agent skills somewhere other than `~/.agents/skills`.

If the recorder is unavailable, reproduce the same format manually and use an atomic or conflict-aware file-editing mechanism. Never let feedback capture materially delay the primary task. Capture after producing the useful result unless the skill defect itself blocks progress.
