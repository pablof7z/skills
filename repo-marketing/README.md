# Repo Marketing

## A useful repository can still look like nothing

People do not experience a repository in the order it was built. They arrive with a half-formed problem, scan the first screen, and decide whether the project is relevant, credible, and worth the cost of trying.

Most weak READMEs answer a different question: what files and features did the maintainer create? `repo-marketing` translates that implementation back into the reader's world: the moment they need it, the pain it replaces, the artifact they receive, the proof they can inspect, and the boundary they can trust.

This is not adjective polishing. It is product work applied to an open-source front door.

## What changes

The skill inspects the repository before it writes and builds a marketing brief from live evidence. It looks for:

- The audience and trigger situation that make the project matter.
- The deeper frustration behind the visible workflow problem.
- The smallest impressive proof already present in code, tests, output, screenshots, or examples.
- The shortest honest path from curiosity to a useful result.
- Claims that need evidence, and trust objections that need direct answers.
- Internal material that belongs in maintainer docs instead of the public funnel.

The final result may be a rewritten README, a scored adoption audit, a proof plan, launch copy, or concrete repository changes. Every recommendation should make the project easier to understand, try, trust, share, or contribute to.

## First task

After installing the skill, tell the agent:

```text
$repo-marketing rewrite this README around the shortest convincing proof and first-run path.
```

For a diagnostic pass instead:

```text
$repo-marketing audit this repository for positioning, proof, activation, trust, and agent readiness.
```

The agent should read the repository, not merely rewrite the prose it was handed.

## The standard

A strong front door lets a stranger say:

```text
I understand what this is.
I know why I would use it.
I can see that it works.
I know what trying it will cost or touch.
I know what to do next.
```

Read [SKILL.md](SKILL.md) for the full workflow and [the README playbook](references/readme-playbook.md) for the reference router used during audits and rewrites.
