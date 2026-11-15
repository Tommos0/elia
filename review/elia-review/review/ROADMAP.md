# Recommended development sequence

[Summary](../SUMMARY.md) · [Findings](../FINDINGS.md) · [Assignable work packages](../ai/WORK-PACKAGES.md)

The recommendation is to repair specific boundary failures while retaining Elia's current architecture. The sequence below is an engineering judgment based on the [17 findings](../FINDINGS.md), their shared files and their acceptance conditions. It is not a schedule estimate or a claim that the pending tests already fail.

## 1. Establish a trustworthy verification lane

Make the documented clean setup work (DEV-01), then run a baseline in an Elixir/Erlang environment using the repository's own `mix precommit` gate. Run the browser and real-jail lanes explicitly where a finding depends on them. Record OS, bubblewrap availability, Node/browser/runtime versions and the actual launch/supervisor mode. Our environment could not run those lanes; [Validation](../meta/VALIDATION.md) records the smaller checks that were completed.

This can proceed alongside read-only confirmation of the P1 findings. Avoid interpreting a broad baseline failure as proof of a specific report; add the smallest observable regression for each claimed behavior. Do not run separate test invocations simultaneously across worktrees. [Testing rules](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/docs/agents/testing.md).

## 2. Repair the six high-priority boundaries

| Work | Outcome to require before considering it closed | Parallelization |
| --- | --- | --- |
| SEC-01/02: host file policy | External prompt sentinels do not enter provider requests; protected aliases cannot become approved writes | One policy owner, coordinated with shell work |
| CORE-01: workspace identity | Child file, cwd, Git and lock behavior all use the intended external tree | Independent task owner; consult session owner for resume metadata |
| CORE-02: session lifetime | Session death ends owned loop/workers; reopening cannot duplicate live work | Session owner; establish before asynchronous compaction changes |
| DEP-01: bundle recovery | A rejected deploy leaves the old served bundle coherent, including ignored outputs | Deployment owner with actual served-byte assertions |
| W01: terminal origin/session | Actual transport rejects foreign/missing-proof requests and permits supported clients | Web owner; priority depends on the deployed browser/proxy reachability |

Read the trigger and qualification for each finding before choosing mitigations. SEC-02 still involves the ordinary approval policy, including per-chat auto-approval. W01 requires a known existing chat ID and browser/proxy reachability. These qualifications influence exploitability; they do not establish a runtime reproduction.

## 3. Make lifecycle and state resilient

Under the session owner, fix malformed-record containment (CORE-03), durable dirty-state handling (CORE-04), then slow summary ownership and cancellation (LLM-01). Keep the visible full transcript distinct from the compacted provider request. Use old-shape fixtures and controlled fault injection; do not inspect real user conversations to design a migration. [Core](CORE.md), [Compaction](LLM-AND-COMPACTION.md).

In parallel, give terminal Start and labeling a consistent state source (W02), make push state transactions atomic (W03), and make an unavailable project folder a usable error state (W04). The last two have small, largely independent scopes. Unknown streamed provider errors (LLM-02) are another bounded repair that can land without a model API call. [Web](WEB.md), [Providers](LLM-AND-COMPACTION.md).

## 4. Resolve command and operator reliability

Release the command overlay lock at readiness (SEC-03) and separate skill cwd from the project mount root (SEC-04). Add the readiness barrier and real-jail sentinel assertions before measuring any speedup. A short timeout or broader mount is not an adequate repair. [Security](SECURITY.md).

Make restart readiness match the actual launch mode (DEP-02), preserving hot reload as its own capability. Finish clean-setup and deployment recovery checks on the combined tree, including a plain launch, supervised launch and asset failure. [Deployment](DEPLOYMENT-AND-SETUP.md).

## 5. Reconcile guidance and measure remaining questions

Correct the stale subagent plan/index, README recovery statement, push implementation description and setup prerequisites. Preserve stable requirement IDs; cross-reference one owner for a behavior instead of duplicating requirements. Consider consolidating the single-user/network threat posture in one owning spec so new contributors do not have to reconstruct it from several out-of-scope sections. These are documentation and design recommendations, separate from the 17 findings. [Testing and documentation drift](TESTING-AND-QUALITY.md), [open questions](OPEN-QUESTIONS.md).

Only then use measurements to choose a larger performance or modularity project. The existing performance review contains historical author measurements and notes that later timing data has not been analyzed; this review has not reproduced those measurements. Avoid promising speedups from source size or the number of tests alone. [Existing performance review](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/docs/performance-review.md#L1-L35).

## Definition of a completed repair

A repair is complete when the owning behavior is explicit, the regression demonstrates the observable outcome, the integrated tests have actually run, compatibility is stated, and the result names any remaining limitations. Specification approval, implementation, local verification, branch integration and user deployment remain separate reviewable transitions. For delegated work, require [the return contract](../ai/RETURN-CONTRACT.md) and keep one parent-owned integration/test queue.
