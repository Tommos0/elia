# Testing and quality

[Start](../README.md) · [Findings](../FINDINGS.md) · [Validation record](../meta/VALIDATION.md) · [Parent AI route](../ai/ORCHESTRATOR.md) · [Subagent routing](../ai/ROUTING-INDEX.md)

Snapshot: `5be0bd873bd2716529de25541efb1825495cd12e`. Elixir, Erlang and Mix were unavailable in the review environment. **The application suite, asset build and real-browser tests were not executed.** Static checks and isolated filesystem/Git probes have narrower evidential value; see the [validation record](../meta/VALIDATION.md) and [raw results](../evidence/static-checks.json).

## The foundation is useful

The snapshot contains **103 test files and 59 Markdown files under `specs/`**. These are inventory counts, not a coverage percentage or a passing-test count. The specification count includes its index and plan material. [Inventory and counting output](../evidence/static-checks.json).

Elia has several useful testing boundaries:

- **Specifications are executable bookkeeping.** Hygiene and traceability tests check IDs, references, corpus shape and whether requirements are accounted for by an existing test file or an explicit `No test:` explanation. They cannot establish that a cited test actually proves the requirement, or resolve contradictions between prose and behavior. [Hygiene tests](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/spec_hygiene_test.exs), [traceability tests](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/spec_tests_test.exs).
- **Model-dependent behavior can be deterministic.** `FakeLLM` records requests, accepts scripted callbacks and refuses calls from sessions that predate its test. That supports held-provider and lifecycle tests without spending money or sending data to a provider. [Fake provider](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/support/fake_llm.ex#L1-L85).
- **The web layers have distinct responsibilities.** LiveView tests cover server state and DOM interactions; a separate PhoenixTest/Playwright layer covers JavaScript, geometry and actual connections. `:real_browser` and `:preview` are excluded from ordinary runs. Passing `mix precommit` would therefore not establish browser correctness. [Test helper](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/test_helper.exs#L22-L41), [testing guide](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/docs/agents/testing.md).
- **Some integration boundaries already have strong tests.** Shell-isolation tests inspect real filesystem effects, provider timeout tests use sockets, and push crypto tests include a known-answer vector. Retain those approaches when adding regressions. [Isolation](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/command_isolation_test.exs), [stream timeout](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/llm/stream_timeout_test.exs), [crypto](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/push_crypto_test.exs).

## What the next tests must prove

Use the detailed reports for reproductions and source chains. The useful addition is a test of each missed boundary, rather than another assertion that the expected helper was called.

| Findings | Meaningful acceptance evidence |
| --- | --- |
| SEC-01, SEC-02 | A dummy outside sentinel never enters the captured provider request; alias writes leave protected/shared bytes unchanged. Exercise host file operations as well as the command jail. [Security](SECURITY.md) |
| SEC-03, SEC-04 | A second command finishes while the first remains alive after mount readiness; a real jailed folder tool reaches its workspace sentinel and cannot reach a sibling. Current readiness-argv and missing-bwrap tests do not prove these outcomes. [Security](SECURITY.md) |
| CORE-01 | A child of an external-project parent actually reads/writes that project's fixture, verified through tools and changed files. A correct project label alone is insufficient. [Core](CORE.md) |
| CORE-02, LLM-01 | Hold a provider/tool/summary with a barrier, then kill or stop its owner. Assert prompt control responsiveness, child cleanup and rejection of late results. [Core](CORE.md), [compaction](LLM-AND-COMPACTION.md) |
| CORE-03, CORE-04 | Load malformed-but-decodable records; inject save failure followed by recovery without another chat mutation. Assert containment and retained dirty state. [Core](CORE.md) |
| W01, W02 | Test the real socket handshake with foreign origin/missing proof, plus two tabs changing jail settings. Direct channel construction and single-view start/stop tests miss these boundaries. [Web](WEB.md) |
| W03, W04 | Use barriers for key/subscription updates; remove a registered project's directory before visiting Files. Verify persisted results and a usable error page. [Web](WEB.md) |
| DEP-01, DEP-02, DEV-01 | Verify served bundle bytes after failure, restart supervision separately from reload capability, and the documented setup in a clean checkout without Node packages. [Deployment](DEPLOYMENT-AND-SETUP.md) |
| LLM-02 | Feed symbolic, empty, absent and malformed error codes into the SSE path; preserve a useful error without an exception. [Providers](LLM-AND-COMPACTION.md) |

## Run gates in a controlled order

After an approved change, run its focused regression first, then the project's `mix precommit` gate. Run browser coverage explicitly when changing transport, hooks, terminal behavior or layout, after installing asset packages and building the bundle. Run real-jail tests on a qualified host; record skipped tests rather than counting them as evidence of isolation. These are proposed gates, not commands reported as completed here. [Aliases](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/mix.exs#L84-L104), [browser instructions](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/docs/agents/testing.md).

**One orchestrator must own the test slot.** Do not run two `mix test`, `bin/test` or `mix precommit` invocations concurrently, even in separate worktrees: the documented partition scratch paths are shared across runs. `bin/test` already provides its own coordinated internal partitioning. Subagents should request a test window and return command, exit status, scope and skips through the [return contract](../ai/RETURN-CONTRACT.md). [Running rules](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/docs/agents/testing.md).

## Reconcile documentation alongside repairs

These are confirmed documentation mismatches, not additional numbered runtime findings:

| Reading trap | Current evidence to use |
| --- | --- |
| Draft plan says children do not inherit auto-approval | [Plan lines 40–42](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/plans/subagents.md#L40-L42) conflicts with [SUBTASK-6](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/subtasks.md#L69-L75). Preserve current copy-on-spawn behavior. |
| Index and subtask introduction describe concurrency as future work | [Index](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/README.md#L163-L168) and [introduction](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/subtasks.md#L5-L8) lag the later requirements and [concurrency tests](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/tasks_concurrency_test.exs). |
| README says there is no recovery page, and its page table omits the route | Correct the [explicit statement](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/README.md#L213-L215) and add `/recover` to onboarding using the [recovery spec](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/recovery.md); it is implemented before the router. [README](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/README.md). |
| Push implementation notes name `web_push` | The [spec](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/push-notifications.md#L149-L154) should describe [local `Elia.Push.Crypto`](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/push/crypto.ex). |
| Node is described as optional and only for browser testing/preview | Reconcile the [README](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/README.md#L24-L36) with required xterm assets and the setup repair in DEV-01. |

Keep stable requirement IDs, cite them in regression tests, and separate behavior changes from prose repair. A traceability lint pass establishes a useful map; reviewers still need to check where that map disagrees with the running system.
