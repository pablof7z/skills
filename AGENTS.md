Every non-trivial change must point to a GitHub issue that clarifies the need or want, not the implementation plan, and must be delivered through a PR that is merged.

Keep hand-maintained code files below a soft limit of 300 lines of code (LOC). Crossing the soft limit is a prompt to extract cohesive responsibilities, reduce duplication, or explain why keeping the code together is clearer.

Hand-maintained code files must not exceed the hard limit of 600 LOC. Split a file before merging any change that would leave it above the hard limit. Generated code, vendored code, machine-produced data, and formats that cannot be split safely are exempt; document any non-obvious exemption in the PR.

Before ending a session or handing off in-progress work to another agent, tag @chief-of-staff via `mosaico channel send`/`reply`. This applies especially when leaving a git worktree behind, punting a blocker to someone else, or stopping with a PR not yet merged.
