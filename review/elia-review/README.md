# Elia — repository review

**Start here.** This package reviews [Tommos0/elia](https://github.com/Tommos0/elia) at commit [`5be0bd873bd2716529de25541efb1825495cd12e`](https://github.com/Tommos0/elia/commit/5be0bd873bd2716529de25541efb1825495cd12e), cloned from `master` on **15 November 2026**. It is a review of the whole project at that snapshot, not a review of only the final commit.

**Assessment:** retain the spec-driven architecture and its strong regression-test foundation; prioritize confinement, process ownership, workspace identity and deployment recovery before adding more orchestration complexity. There are **17 source-confirmed findings: 6 P1 and 11 P2**. One P1 has explicit browser/proxy reachability preconditions. None is presented as a reproduced end-to-end exploit or an executed ExUnit failure. [Findings](FINDINGS.md) · [Evidence and limits](meta/VALIDATION.md).

## Choose your reading route

Times are editorial estimates, not measurements. Each route has a stopping point so readers need not ingest the whole archive.

| Reader or task | Read in this order | Stop when |
| --- | --- | --- |
| **Human: the 5–10 minute overview** | [Summary](SUMMARY.md) → [priority table](FINDINGS.md) | You understand the main risks and the next work to fund |
| **Human: architecture and contribution, 20–30 minutes** | [Summary](SUMMARY.md) → [Architecture](review/ARCHITECTURE.md) → [Testing and quality](review/TESTING-AND-QUALITY.md) → one domain report | You can locate the responsible module, spec and test |
| **Human: decide what to do next** | [Summary](SUMMARY.md) → [Roadmap](review/ROADMAP.md) → [Work packages](ai/WORK-PACKAGES.md) | Each proposed change has an owner and an acceptance gate |
| **AI parent/orchestrator: compact route** | [Orchestrator brief](ai/ORCHESTRATOR.md) → relevant rows of [Routing index](ai/ROUTING-INDEX.md) | You can delegate focused tasks without loading every report |
| **AI subagent: one bounded task** | Your routing row → named domain finding → owning repository spec/code/test → [Return contract](ai/RETURN-CONTRACT.md) | You can confirm/refute the claim and return evidence |
| **Reviewer: reproduce or challenge** | [Method](meta/METHOD.md) → [Validation](meta/VALIDATION.md) → [Sources](meta/SOURCES.md) → selected finding | You know what was actually checked and what remains untested |
| **Maintainer: reconcile old guidance** | [Documentation drift](review/TESTING-AND-QUALITY.md) → current `specs/subtasks.md`/`AGENTS.md` | Historical plans are no longer mistaken for implemented behavior |

## Detailed reports

| Report | Main subjects |
| --- | --- |
| [Security and command boundaries](review/SECURITY.md) | Host-side instruction reads, protected write aliases, overlay lock, folder-tool mounts |
| [Core](review/CORE.md) | External-project child workspace, session/loop ownership, malformed records, failed saves |
| [Web](review/WEB.md) | Terminal origins and jail state, atomic push state, explorer error handling |
| [Deployment and setup](review/DEPLOYMENT-AND-SETUP.md) | Missing package setup, generated-asset rollback, restart readiness |
| [Providers and compaction](review/LLM-AND-COMPACTION.md) | Blocking summarization, stream error parsing, integration limits |
| [Architecture](review/ARCHITECTURE.md) | Ownership, request flow, directory identities and stored data |
| [Testing and quality](review/TESTING-AND-QUALITY.md) | Strengths, blind spots, execution gates and documentation drift |
| [Open questions](review/OPEN-QUESTIONS.md) | Explicitly unconfirmed investigations and product decisions |

## What the package contains

All narrative material is Markdown. **There are no HTML files**, so no separate HTML/Markdown versions can drift. Relative links connect the review documents; source citations point to the immutable reviewed commit. The archive contains the review, evidence, inventories and a small local verification script. It does not contain a duplicate source checkout or its `.git` history.

- [Machine findings](evidence/findings.json): IDs, priorities, evidence, owners and acceptance checks.
- [Machine routes](ai/routes.json): per-workstream reading lists and integration dependencies.
- [Source ledger](meta/source-ledger.json): sources actually inspected, with full/targeted coverage.
- [Repository inventory](evidence/repository-inventory.json): all 339 tracked paths and hashes; inventory does **not** mean every line was reviewed.
- [Static checks](evidence/static-checks.json) and [test partition plan](evidence/test-plan.txt): actual local results.
- [Review metadata](evidence/review-metadata.json): snapshot and GitHub retrieval observations.
- [Package validation](evidence/package-validation.json): link, citation-bound, routing and consistency checks.
- [Checksums](MANIFEST.sha256): hashes for the archive's contents, excluding the checksum file itself.

## Read the confidence labels correctly

**Source-confirmed** means an inspected code path and a stated trigger support the finding. **Primitive reproduced** means a narrow filesystem/Git premise was executed in a disposable fixture. **Runtime pending** means the application behavior still needs its specified ExUnit/integration reproduction. **Follow-up** means a question, not an established defect.

Elixir/Erlang/Mix are absent from the review environment. `mix precommit`, application build, browser flows and real-jail integration tests were therefore not run. The successful checks are narrower and listed in [Validation](meta/VALIDATION.md). Repository source was left clean; no issues, PRs, commits, merges or deployments were created.

## Using this review on a later revision

Confirm `git rev-parse HEAD`, then compare the current code with the pinned evidence. A finding may already be fixed. Review IDs belong to this package; specification IDs such as `SUBTASK-23` belong to Elia and must not be renumbered. Before implementing behavior changes, read the checkout's current `AGENTS.md` and follow its spec-first approval workflow. [Method and instruction scope](meta/METHOD.md) explains why this read-only review did not require that implementation approval.
