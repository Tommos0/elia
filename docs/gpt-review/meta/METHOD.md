# How this review was performed

[Start](../README.md) · [Validation](VALIDATION.md) · [Sources](SOURCES.md) · [Findings](../FINDINGS.md)

## Objective and snapshot

The requested deliverable is a repository review that people and development agents can use, including an efficient parent/subagent reading route. The repository was cloned from `https://github.com/Tommos0/elia.git`. The reviewed `master` commit is **`5be0bd873bd2716529de25541efb1825495cd12e`**, dated **2026-11-15 08:57:12 UTC**. This is a broad review of that snapshot, not a review restricted to the final commit. [Commit](https://github.com/Tommos0/elia/commit/5be0bd873bd2716529de25541efb1825495cd12e), [recorded metadata](../evidence/review-metadata.json).

The actual source clone is `/workspace/scratch/50ab67582c2b/elia`. It was left clean and unchanged. The archive contains review material rather than duplicating the repository and Git history. To obtain the same source independently, run the following from a directory where a new `elia` folder is appropriate:

```sh
git clone https://github.com/Tommos0/elia.git
git -C elia checkout --detach 5be0bd873bd2716529de25541efb1825495cd12e
git -C elia rev-parse HEAD
git -C elia status --short
```

The detach command applies to the newly cloned folder. Do not use it to replace a developer's in-progress checkout. On a later revision, compare the actual source against the pinned evidence before accepting a finding as current.

## Review sequence

1. **Orient from the repository's own contracts.** Read `AGENTS.md`, setup/layout documentation, relevant contributor guides and the specification index. Map application supervision, sessions, tools, tasks, provider requests, saved data, browser surfaces and deployment.
2. **Divide by boundary.** Delegate core sessions/tasks/persistence, command/file isolation, and web/terminal/push to three focused reviewers. The parent covers providers, compaction, setup and deployment, and integrates the shared architecture and priorities.
3. **Trace claims across layers.** Follow inputs to effects, including actual filesystem targets, process lifetime, provider payloads and served asset bytes. Read the closest test and owning requirement. Look specifically for tests that check a label or tracked revision while the observable behavior depends on a different identity or ignored file.
4. **Challenge possible findings.** Check counterexamples and stated design intent. Inspect primary framework/runtime source where a lifecycle or transport assumption matters. Use a second reviewer for the setup/deploy and compaction/restart chains and a final cross-report consistency pass.
5. **Run only available, bounded checks.** Inventory the exact Git objects; check shell/JavaScript/JSON syntax and test partition planning; demonstrate narrow filesystem and Git premises in disposable fixtures. Attempting the application gate established that Mix was unavailable. No application test result is inferred from these checks.
6. **Package for reuse.** Separate human summary, domain reasoning, parent brief, bounded child routes, assignable work, evidence and sources. Check internal links, IDs, counts, pinned paths/line bounds and archive integrity before delivery.

Source inspection was targeted rather than an assertion that every line was read. The [source ledger](source-ledger.json) records full, targeted and inherited reads. The [inventory](../evidence/repository-inventory.json) enumerates all tracked paths and hashes; that is a machine inventory, not manual-review coverage.

## Evidence model

| Label | Meaning in this package | What it does not establish |
| --- | --- | --- |
| Source-confirmed | An inspected call chain supports the stated trigger and consequence | An executed application reproduction, frequency in production, or complete security coverage |
| Primitive reproduced | A bounded filesystem/Git premise was run against generated dummy data | Execution of Elia's tool, jail, deployment or browser flow |
| Runtime pending | A specific ExUnit, process, browser or real-jail acceptance test remains to be run | A passing or failing result for that future test |
| Follow-up / open question | A design choice or unverified lead deserves a bounded next investigation | An additional confirmed finding |

All 17 findings have high confidence in the source reasoning and `runtime_reproduced: false`. P1/P2 rank development work for this local developer harness; they are not CVSS ratings. P1 means repair before depending on the affected boundary or workflow. P2 means a concrete defect to schedule with a focused regression. W01's exposure depends on its explicitly stated known-ID and browser/proxy preconditions. Security claims retain the distinction between an absolute refusal and the ordinary approval policy, which can include per-chat auto-approval.

## What was treated as intentional

The project is a single-user local harness with no built-in login; network access and a user-disabled jail are deliberate policy choices. A stopped child turn remains an unfinished task. Elia's own configured worktrees can run concurrently, while shared-workspace writers serialize. The parent integrates child work and the user deploys it. These rules are not renamed defects merely because a different product might choose another design. [Repository instructions](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/AGENTS.md), [subtasks](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/subtasks.md), [terminal scope](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/terminal.md).

Historical project reviews were read for context. Their measurements, completed-work labels and proposals were not adopted as this review's measurements. Current source and owning requirements take precedence over a draft plan when describing implemented behavior. [Documentation drift](../review/TESTING-AND-QUALITY.md), [open questions](../review/OPEN-QUESTIONS.md).

## Instructions, authority and operational scope

The user requested review, cloning and a zip. No application code, tests or specs were changed; no upstream issue, PR, message, commit, merge or deployment was created. Consequently the repository's requirement to obtain specification approval before implementing behavior changes did not block this read-only review. This package does not grant future approval to implement its recommendations.

The repository's `spawn_task` planning/implementation rules describe Elia's own development workflow. The review used independent read-only reviewers to challenge source findings; it did not ask Elia to run implementation subtasks. Future AI routes preserve the parent-owned specification step and serialized-test requirement. Available review tooling used Git/source inspection rather than Elia's in-application file tools; it did not bypass an Elia approval gate or change a live workspace.

No real saved conversations, API keys, user settings or external project files were inspected. Symlink and rollback probes used only generated sentinels and a disposable Git repository. No provider request, paid model call, real exploit, browser handshake or deployment was attempted.

## Limits and possible omissions

Elixir/Erlang/Mix were absent. No compilation, type/dialyzer analysis, ExUnit suite, browser accessibility walkthrough, actual performance benchmark, live-provider compatibility run or real-jail exploit was completed. No vulnerability database audit of all transitive dependencies was performed. Large files and cross-cutting behavior received targeted reads, not a formal proof or exhaustive security audit.

Read-only GitHub queries found zero returned issues/PRs and zero Actions runs for the requested queries; the checked-in inventory contains no workflow files. Those are retrieval observations, not proof that no external/private CI or development discussion exists. Public web retrieval failed; local Git objects and GitHub primary-source reads supplied the review evidence. [Exact observations](../evidence/review-metadata.json).

The highest-value next step is to execute the specified regression designs on the pinned baseline and then on an approved repair. A refutation with precise evidence should update the finding, not be hidden to preserve this report's count.
