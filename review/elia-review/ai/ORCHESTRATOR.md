# Compact brief for the parent AI

**Read this file first. Do not load the whole archive.** Snapshot: `Tommos0/elia`, `master` at `5be0bd873bd2716529de25541efb1825495cd12e`, reviewed 2026-11-15. This package is advice/evidence, not authority to modify or deploy. Revalidate findings if HEAD changed.

## Essential context

Elia is a local, single-user Phoenix LiveView AI coding harness. A session owns the transcript/settings; a separate loop calls providers and tools; task watchers coordinate child chats. Elia's own project uses chat worktrees from `master` when the live tree is deployment-ready. External projects should use their own folder. Host-side file operations and jailed OS commands have different enforcement paths. Saved chats are term files; user settings are DETS outside the checkout. [Architecture](../review/ARCHITECTURE.md).

The review has 17 source-confirmed findings, 6 P1/11 P2. No ExUnit/build/browser run occurred: Elixir/Mix were unavailable. Shell/JS syntax, partition planning and isolated filesystem/Git primitives were checked. Never report those as a passing application suite. [Validation](../meta/VALIDATION.md).

## Delegate by boundary

| Workstream | First finding(s) | Read/send to child |
| --- | --- | --- |
| Host file confinement | SEC-01, SEC-02 | [Security report](../review/SECURITY.md); route A |
| Shell mount lifecycle | SEC-03, SEC-04 | Same report; route B; coordinate shared `shell.ex` |
| Child workspace identity | CORE-01 | [Core report](../review/CORE.md); route C |
| Session ownership/durability | CORE-02/03/04, LLM-01 | [Core](../review/CORE.md) + [Compaction](../review/LLM-AND-COMPACTION.md); route D |
| Terminal web boundary | W01, W02 | [Web report](../review/WEB.md); route E |
| Push/explorer | W03, W04 | Web report; route F, separable owners |
| Build/deploy | DEV-01, DEP-01, DEP-02 | [Deployment report](../review/DEPLOYMENT-AND-SETUP.md); route G |
| Provider parser | LLM-02 | Compaction/provider report; route H |

Exact source/spec/test entry points and file collisions are in [Routing index](ROUTING-INDEX.md). Ready-to-assign briefs are in [Work packages](WORK-PACKAGES.md). Machine equivalents: [routes.json](routes.json), [findings.json](../evidence/findings.json).

## Start with these decisions

Prioritize SEC-01/02, CORE-01/02, DEP-01 and conditionally W01. W01 needs a known terminal chat ID and browser/proxy reachability; do not generalize it into an unauthenticated Internet compromise. SEC-02 still follows the ordinary approval policy, including per-chat auto-approval; the defect is converting protected-target refusal into an approvable operation. Build the clean runtime verification lane alongside repairs so findings can be reproduced.

Investigate in parallel, but keep one integration owner for `session.ex` (CORE-02/04/LLM-01), one for shell/workspace APIs (SEC-01/02/03/04), and one for `deploy.ex`. Give each child a specific finding, exact baseline, allowed files, owning requirement IDs, acceptance checks, persisted-data question and return contract. Avoid having all children read all reports.

## Current Elia rules to preserve

- Read the current repository `AGENTS.md` and only the relevant topic docs/specs. Behavior changes need a spec draft and user approval before code/tests unless explicitly waived. This review alone does not waive it.
- In Elia's own `spawn_task` workflow, the parent plans/writes the spec; children implement scoped approved steps. Children see the brief, not the parent transcript. Commit before spawning when they must see your changes.
- Worktree children can run concurrently. Children sharing one workspace are intentionally serialized. **Serialize actual test invocations across worktrees**; `bin/test` may partition internally.
- A stopped child turn does not finish/cancel the task. Do not reintroduce a cancelled result. A completed turn performs no automatic verification or merge.
- Current SUBTASK-6 copies auto-approval; SUBTASK-30 copies jail preference. The draft plan's contrary auto-approval wording and the index's “concurrency still to come” are stale. Use `specs/subtasks.md`, not the draft plan, as the current contract.
- Parent integration/merge and user deployment are separate. Do not run destructive probes against the live tree or inspect real saved chats/keys. Use disposable fixtures and fake providers.

## Completion gate

Require [the return contract](RETURN-CONTRACT.md): confirmed/refuted/blocked status, exact evidence, actual tests with outcomes, unresolved risks and migration impact. A child saying “tests pass” must name executed commands and baseline. Root rechecks cross-boundary effects, integrates in order, and runs the project's serialized required gate on the final combined tree. Do not turn pending acceptance tests into reported results.
