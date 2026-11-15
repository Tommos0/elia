# Open questions and deliberately unconfirmed leads

[Start](../README.md) · [17 findings](../FINDINGS.md) · [Validation record](../meta/VALIDATION.md) · [Parent AI route](../ai/ORCHESTRATOR.md) · [Subagent routing](../ai/ROUTING-INDEX.md)

Snapshot: `5be0bd873bd2716529de25541efb1825495cd12e`. The numbered findings have source evidence and explicit triggers; they are not all runtime-reproduced. **This page adds no confirmed findings.** It distinguishes environmental conditions still to measure, plausible leads still to test, and product choices to preserve or make deliberately. Elixir/Mix were absent, so no application, real-browser or Erlang-crypto tests were executed. [Validation](../meta/VALIDATION.md).

## 1. Which browser deployments are actually reachable?

**Type: environmental qualification of W01; owner: web/security.** The disabled origin check and permissive terminal connection path are confirmed. End-to-end exposure still depends on an unrelated origin knowing an existing chat ID and the browser/proxy permitting the connection. Random IDs are not established as guessable, and a proxy may enforce an effective boundary. The single-user deployment model does not answer whether another website can act through the user's browser. [Default endpoint](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/config/dev.exs#L9-L19), [terminal socket](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/terminal_socket.ex), [detailed qualifications](WEB.md).

Define supported localhost and reverse-proxy origins. Test handshake rejection and valid same-origin use with harmless fixture terminals on those deployments. Record browser versions, origin, proxy settings and ID source. Do not promote the code-path finding into a claim that every internet page can control every installation.

## 2. Can one malformed push device abort delivery to the rest?

**Type: unconfirmed runtime lead; owner: push.** Subscription validation checks base64-decoded lengths; it does not establish that a 65-byte public key is a valid P-256 point. Encryption hands that value to `:crypto.compute_key`, and the delivery reduction has no per-device exception boundary. The runtime behavior of a correctly sized invalid point was not executed here. This is separate from confirmed concurrent-update finding W03. [Validation](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/push/subscriptions.ex#L65-L94), [ECDH call](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/push/crypto.ex#L108-L120), [delivery loop](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/push.ex#L120-L149).

Use a local fixture containing the uncompressed marker `0x04` followed by 64 zero bytes, then a valid device. Stub HTTP delivery. Determine the actual OTP result and require one failure tally plus continued processing of the valid device. Test malformed HTTPS endpoint values through the same boundary. No live push subscription is needed.

## 3. Should recovery be explicitly protected from framing?

**Type: conditional hardening question; owner: web/recovery.** Recovery intentionally answers before the router's normal browser pipeline, and its response function adds content type and no-store without a frame policy. A same-origin form check does not itself decide whether a foreign page may embed that form and induce a click. Browser and proxy framing policies were not tested, so an executed clickjacking exploit is not claimed. [Endpoint order](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/endpoint.ex#L68-L73), [response](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia_web/recovery.ex#L431-L442).

Decide whether embedding recovery has any supported use. If none, add frame denial directly to its independent response and test those headers without relying on the normal layout/router. Preserve recovery's independence from a working asset bundle; it is valuable precisely when that bundle is broken.

## 4. Stopping a child is deliberately not cancelling its task

**Type: product contract to preserve; owner: orchestration.** A stopped child turn leaves the task `running`, retains its entry and keeps the parent waiting. Stopping a parent stops child turns, without inventing a cancelled result. This is explicitly required by SUBTASK-16/17/31. It is different from CORE-02, where a dead session leaves an unowned loop running. [Stop semantics](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/subtasks.md#L138-L164), [external status](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/subtasks.md#L291-L298).

An agent should not “fix” a long wait by automatically finishing or cancelling the child. A distinct abandon/cancel workflow would need a product decision, new requirements, persisted-state compatibility analysis and approval. Until then, inspect the child's own chat and resume or finish it under the existing contract.

## 5. What does a runtime-incompatible jail do?

**Type: host-matrix verification and policy decision; owner: shell/isolation.** The availability predicate tests whether the executable exists; ISOL-12 also describes unavailable user namespaces. Overlay setup has its own retry/read-only fallback, which is different from permission to run an arbitrary command unjailed. The review did not exercise kernel/mount combinations. [Availability](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/shell.ex#L59-L61), [fallback paths](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/shell.ex#L323-L367), [ISOL-12](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/command-isolation.md#L127-L144).

Test missing binary, present-but-forbidden namespace creation, unsupported overlay, working overlay, and an explicitly disabled jail. Record what the command actually did and what the UI/model were told. Resolve any mismatch through an explicit fallback policy; do not silently broaden unjailed execution while fixing SEC-03 or SEC-04.

## 6. How much deployment state must rollback restore?

**Type: scope beyond DEP-01; owner: deployment.** Generated asset restoration is a confirmed finding. Dependency restoration deserves a separate fixture: deployment runs `mix deps.get` and npm installation in the live tree before completion, while failure recovery resets tracked files. Restoring lockfiles does not itself establish that installed dependency directories match them. The effect on an already-running VM versus its next compile/restart needs measurement. [Deployment sequence](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/deploy.ex#L1109-L1155), [npm/build/reset](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/deploy.ex#L1226-L1269).

Use a disposable live/trunk fixture with changed dependency versions and an injected later failure. Compare installed versions, generated artifacts, loaded revision, and the next startup. Decide whether to stage a complete candidate, restore dependencies, or explicitly report incomplete recovery. Do not assume development watchers provide transactional restoration.

## 7. Which real integrations and performance claims remain unmeasured?

**Type: validation backlog; owners: relevant routes.** No live provider, real browser, real push delivery or running-server performance profile was exercised. Fake-provider success would not establish current vendor model/header compatibility; LiveView success would not establish JavaScript/layout behavior. Retest those boundaries with controlled fixtures and provider-owned documentation when making current-compatibility claims. [Provider discussion](LLM-AND-COMPACTION.md), [browser workflow](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/docs/agents/testing.md).

Use existing step timings to separate provider wait, approval wait and tool execution; add targeted profiling for persistence and rendering before proposing architectural performance work. Profile representative long transcripts and concurrent chats with synthetic data, record cold versus warm state, and compare the reviewed commit with the proposed change. Existing performance notes are useful hypotheses and historical evidence, not a new benchmark performed for this review. [Timing spec](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/step-timing.md), [existing performance review](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/docs/performance-review.md).

For any lead promoted to a finding, return the trigger, inspected source, observed result, refutations checked and proposed acceptance gate through the [subagent return contract](../ai/RETURN-CONTRACT.md). Keep uncertainty attached to the claim as it moves between agents.
