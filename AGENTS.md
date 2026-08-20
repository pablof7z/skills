Keep hand-maintained code files below a soft limit of 300 lines of code (LOC). Crossing the soft limit is a prompt to extract cohesive responsibilities, reduce duplication, or explain why keeping the code together is clearer.

Hand-maintained code files must not exceed the hard limit of 600 LOC. Split a file before merging any change that would leave it above the hard limit. Generated code, vendored code, machine-produced data, and formats that cannot be split safely are exempt; document any non-obvious exemption in the commit/PR.
