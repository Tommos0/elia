# Subagent return contract

[Parent brief](ORCHESTRATOR.md) · [Routes](ROUTING-INDEX.md) · [Work packages](WORK-PACKAGES.md)

This template is for future investigation or implementation. The current review has not implemented any repair. Ask each child to return a compact result with links to detailed evidence, not its entire exploratory transcript.

```json
{
  "work_package": "C",
  "finding_ids": ["CORE-01"],
  "base_commit": "exact SHA actually inspected",
  "result": "confirmed | refuted | fixed | blocked",
  "summary": "One paragraph stating behavior and impact",
  "evidence": [{"path": "lib/...", "symbol": "function/arity", "lines": "start-end", "explanation": "why it supports the claim"}],
  "spec_ids": ["PROJ-12", "SUBTASK-23"],
  "spec_approval": "not needed for read-only review | reference to actual approval | pending",
  "changed_files": [],
  "tests": [{"command": "exact command", "status": "passed | failed | blocked | not run", "reason_or_log": "evidence location"}],
  "persisted_data": {"reads_writes": [], "compatibility": "unchanged | backward-compatible | migration required", "reason": "specific decision"},
  "commit": null,
  "integration_dependencies": [],
  "remaining_questions": [],
  "risks": []
}
```

## Evidence rules

- Confirm the actual tool workspace and process ownership, not just labels or metadata.
- Separate a static source deduction, a primitive probe and an executed application test.
- State the triggering preconditions, including real-jail availability, saved-state shape or browser-origin assumptions.
- Inspect the existing test that appears closest; explain the assertion it lacks or how it refutes the finding.
- Use dummy secrets, temporary Git repositories and `FakeLLM`/provider stubs. A reproduction must not call a paid model or modify the running live tree.
- Report counterevidence. A well-supported refutation is useful work.
- Do not silently choose a new persisted format, weaken containment, change stopped-child semantics or broaden deployment authority.

## Integration review by the parent

Check that a child based its patch on the approved spec and correct SHA, that acceptance assertions test the observable outcome, and that unrelated behavior has not changed. Review source and tests together. For overlapping session or shell changes, integrate one patch before rebasing the next; then run combined tests rather than treating independent branch results as an integration result.

Keep operationally different states distinct: “turn stopped,” “task finished,” “data saved,” “branch merged,” “candidate built,” and “revision loaded.” A success in one is not evidence of the others. This distinction underlies several findings in this review.
