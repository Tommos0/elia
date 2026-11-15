# Sources read and how to locate them

[Method](METHOD.md) · [Validation](VALIDATION.md) · [Source ledger](source-ledger.json) · [Repository inventory](../evidence/repository-inventory.json)

All repository findings are grounded in the cloned snapshot **`5be0bd873bd2716529de25541efb1825495cd12e`**. Domain reports link to immutable GitHub paths and line ranges. Local paths below are relative to the Elia checkout; archive paths refer to review material.

## Three different indexes

| Index | Use it for | Scope |
| --- | --- | --- |
| [findings.json](../evidence/findings.json) | Exact evidence for a claim, owning requirement IDs, tests and acceptance | The 17 confirmed source findings |
| [source-ledger.json](source-ledger.json) | What a reviewer actually inspected and why | Aggregates parent and three domain reviewers, preserving full/targeted/inherited coverage |
| [repository-inventory.json](../evidence/repository-inventory.json) | Path, byte/line counts, SHA-256 and pinned URL | All 339 tracked paths; enumeration does not mean manual review |

Original reviewer ledgers are retained as [core-sources.json](core-sources.json), [security-sources.json](security-sources.json), [web-sources.json](web-sources.json), and [root-sources.json](root-sources.json). The aggregate normalizes navigation but retains each reviewer record instead of upgrading combined fragments into a claimed full read. Some targeted ranges are approximate read windows, not the exact minimal evidence slice; findings carry the latter. `search-only` identifies discovery/keyword reads rather than full-file inspection.

## Main source groups

| Group | Representative inspected sources | Why they were read |
| --- | --- | --- |
| Workflow and intent | `AGENTS.md`, `README.md`, `docs/agents/*`, `specs/README.md`, owning specs | Contribution rules, setup, stable IDs, current intended behavior and delegated-work constraints |
| Supervision and state | `application.ex`, `agent.ex`, `agent/session.ex`, `agent/loop.ex`, `agent/resumer.ex`, `tasks.ex`, `store.ex`, `store/cache.ex` | Turn ownership, subtask workspace/result lifecycle, recovery and persistence |
| Commands and files | `workspace.ex`, `shell.ex`, `shell/lock.ex`, `skills.ex`, `skills/files.ex`, `skills/folder.ex`, terminal code | Host/jail boundary, canonical targets, approvals, mount lifetime and cwd |
| Providers and context | `llm.ex`, OpenAI-format/Anthropic adapters, SSE/retry, compaction/context/tokens/catalog | Stream failure semantics, request shaping, slow preparation and provider neutrality |
| Web and push | Endpoint/router/socket/channel, terminal/files/chat/settings LiveViews, Markdown/file links, push/settings/crypto, JS and service worker | Browser-origin proof, state freshness, safe rendering, concurrent settings and UI errors |
| Deployment/setup | `deploy.ex`, runner, Mix aliases, config, `bin/*`, asset imports, root layout | Candidate transaction, generated outputs, restart readiness and clean prerequisites |
| Closest tests | Source/test routes in each report, FakeLLM, live-tree fixtures and browser helpers | Determine what is actually asserted and design observable regressions |
| Existing project reviews | `docs/spec-review.md`, `docs/performance-review.md`, draft subagent plan | Counterevidence, acknowledged decisions and historical context; their metrics were not rerun |

For focused development, use [the routing index](../ai/ROUTING-INDEX.md) instead of reading the entire ledger. A source can be relevant to orientation without providing evidence for a confirmed finding.

## External primary sources

Only primary dependency/runtime source was used for the following technical assumptions:

| Source | Inspected behavior | Qualification |
| --- | --- | --- |
| [Phoenix v1.8.16 socket transport](https://github.com/phoenixframework/phoenix/blob/v1.8.16/lib/phoenix/socket/transport.ex#L345-L356) and [session extraction](https://github.com/phoenixframework/phoenix/blob/v1.8.16/lib/phoenix/socket/transport.ex#L503-L526) | `check_origin: false` bypasses origin validation; missing/invalid session proof yields `session: nil` for the socket callback | Version from the pinned lockfile; source inspection, no handshake executed |
| [Elixir v1.17.3 Task supervised startup](https://github.com/elixir-lang/elixir/blob/v1.17.3/lib/elixir/lib/task/supervised.ex#L21-L43) | Startup owner monitor is removed before the task function executes | Representative version satisfying the declared Elixir series; no installed runtime to inspect or run |
| [Elixir v1.17.3 GenServer call](https://github.com/elixir-lang/elixir/blob/v1.17.3/lib/elixir/lib/gen_server.ex#L1103-L1117) | Default synchronous call timeout is 5,000 ms | Supports LLM-01 reasoning; not a measured application timeout trace |

These primary sources were fetched through read-only GitHub access; the parent inspected the relevant excerpts as well as the subreviewer conclusions. No third-party blog, stale web snippet or assumed live-provider error sample is treated as authoritative evidence.

## Repository metadata queries

Read-only repository, branch, issue/PR search and Actions-run queries established the snapshot and visible project context. [review-metadata.json](../evidence/review-metadata.json) records the precise query strings and returned counts. A zero-result search and no checked-in workflow files do not exclude off-platform CI or inaccessible discussions. Metadata observations are not included in the 17 defect count.

## Reading omissions

The review did not read user-specific `.elia` data, real settings/credentials, unrelated folders, all dependency source or every test body. Binary screenshots/assets were inventoried rather than visually assessed. Coverage is intentionally conservative: a targeted source record cannot establish that an entire module is correct. A future child agent should inspect the current implementation and nearest test before changing it, even when the route points to an already-reviewed file.
