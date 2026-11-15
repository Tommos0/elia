[Start](../README.md) · [Findings index](../FINDINGS.md) · [Routing index](../ai/ROUTING-INDEX.md)

# Core review: sessions, tasks and persistence

Reviewed commit: `5be0bd873bd2716529de25541efb1825495cd12e` (15 November 2026).

This is a read-only review of the cloned source. All findings below are based on inspected code and specifications; none was executed against Elixir/OTP in this environment. No repository files were changed. The source ledger is [source ledger](../meta/core-sources.json).

## Assessment

The core has a coherent division of responsibility: a session owns conversational state, a separate loop performs model and tool work, and task watchers turn child-chat completion into a structured result. The specifications describe important edge cases unusually well: stopping a child turn does not finish its task; an interrupted turn is automatically resumed at most once; and tool crashes become individual failed results rather than necessarily killing the turn. The review found two high-priority ownership errors and two narrower persistence robustness problems.

| Local ID | Priority | Finding | Evidence confidence |
| --- | --- | --- | --- |
| CORE-01 | P1 | A subtask started in an external project runs in Elia's own workspace | High; complete source flow and missed test assertion |
| CORE-02 | P1 | A session's termination does not terminate its unlinked loop | High; source flow, upstream task semantics and existing test cleanup |
| CORE-03 | P2 | Valid Erlang terms with an invalid chat shape crash load/list/resume paths | High; unguarded operations on decoded values |
| CORE-04 | P2 | A failed save clears the dirty timer, so a later clean shutdown does not retry it | High for the missing retry; downstream replay requires the stated failure sequence |

P1 means address before relying on the affected workflow; P2 means a concrete defect under narrower conditions. These are suggested development priorities, not vulnerability scores.

## Architecture and invariants to retain

| Component | Responsibility and useful entry point |
| --- | --- |
| `Elia.Agent` | Public API, one registered session per chat, status queries, lifecycle operations. `ensure_started/2` tolerates the normal already-started race. |
| `Elia.Agent.Session` | Full transcript, per-chat settings, approval and input gates, persistence, turn records, broadcasts. Its process is intended to own the conversation. |
| `Elia.Agent.Loop` | One turn: resolve current skills, build the request view, stream a model call, validate and gate tool calls, execute them concurrently, preserve result order, enforce limits between steps. |
| `Elia.Tasks` | Per-workspace writer registry, child startup, a watcher per child, structured results and restart reattachment. The registry keeps blocking session calls outside its own server callbacks. |
| `Elia.Store` / `Store.Cache` | Atomic term-file replacement and a metadata cache identified by file inode, size and modification time. Full histories remain on disk; running status is derived again when listing. |
| `Elia.Agent.Resumer` | Boot-time scan after dependencies start; child sessions are considered before their parents. The session itself decides whether to resume. |

These roles follow [application children](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/application.ex#L22-L68), [session initialization](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/session.ex#L101-L151), [loop setup and steps](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/loop.ex#L72-L148), and [task watching](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/tasks.ex#L392-L623).

Preserve these distinctions while fixing the findings:

- A transcript and a provider request view are different objects. Compaction must not discard the full history.
- A stopped turn, an idle session, a finished subtask and a chat marked done are distinct states.
- A child in a configured Elia worktree has its own branch; a child in another project should share that project's workspace. Worktree children may run concurrently; children sharing a workspace are intentionally serialized.
- Limits are checked between steps. The current specifications deliberately exclude user-wait and retry-delay time, and do not promise a hard deadline interrupting a tool in flight.
- Ordinary turn completion performs no automatic test run, merge or rollback. Parent agents must review a child's result and merge intentionally.

The source contracts are [SESS](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/agent-sessions.md), [LOOP](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/agent-loop.md), and [SUBTASK](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/specs/subtasks.md).

## CORE-01 — External-project subtasks use Elia's own directory

**Priority:** P1. **Confidence:** high, source-confirmed; runtime reproduction pending.

### Evidence and trigger

`Tasks.repo_root/1` uses `ctx[:workspace]` only when `Projects.harness_ctx?/1` is true. Its other branch returns `Workspace.root()`, which is the global Elia workspace, not the external project's folder. The subsequent `child_workspace/3` returns that parent root when it is not a recognized Elia chat worktree. `start_child/5` passes it in `loop_opts[:workspace]`. `Session.init/1` gives that explicit workspace precedence over `Deploy.workspace(project, id)`.

The child still receives the external `project` map. Its identity therefore looks right while its file and shell tools operate in the wrong tree. Git baseline and changed-file reporting also use the wrong tree. This is not a mere misleading label: the actual tool context gets that root.

Sources:

- [Wrong root selection, tasks.ex 181–199](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/tasks.ex#L181-L199).
- [Workspace fallback, tasks.ex 234–253](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/tasks.ex#L234-L253).
- [Passing workspace and project, tasks.ex 280–345](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/tasks.ex#L280-L345).
- [Workspace precedence, session.ex 108–119](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/session.ex#L108-L119).
- [Global root definition, workspace.ex 28–37](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/workspace.ex#L28-L37).
- [Project discriminator, projects.ex 120–126](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/projects.ex#L120-L126).

**Contract:** PROJ-12 and SESS-23 require tools to use the project's folder; SUBTASK-23 explicitly says an external project's child shares its parent's workspace.

### Reproduction design

Use two disposable Git repositories: an Elia fixture root and a distinct external project folder, each with a different committed marker. Start the parent with the external project map. Have the fake provider spawn a child that runs `pwd`, reads the marker, and writes a new marker with the normal tools. Approve calls in the test or use the intended copied auto-approval state. The current source selects the Elia fixture root; the required result is the external root. Assert actual tool output and changed files, not just `snapshot.project`.

The existing [external-project test, tasks_test.exs 537–566](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/tasks_test.exs#L537-L566) checks the project map and saved ID only. Its external folder is not even initialized as a repository, so it cannot establish that Git operations ran there.

### Remediation and acceptance

Resolve the actual parent workspace for every project and use that same root for the baseline, writer lock, child session and result reporting. Keep the Elia-only worktree special case. Add assertions that no file is written to Elia's live tree, that result commits/files belong to the external repository, and that two different external projects do not incorrectly share one writer lock. Include restart/resume coverage: persisted `start_commit` and the restored workspace must refer to the same repository.

Persisted shape need not change for the fix, but affected old task records may contain an Elia commit as their baseline; decide how those are reported instead of silently claiming a valid external-project diff.

## CORE-02 — Session death leaves its loop and tools alive

**Priority:** P1. **Confidence:** high, source-confirmed; runtime reproduction pending.

### Evidence and trigger

A turn is launched with `Task.Supervisor.async_nolink/2`. The session tracks that task and explicitly terminates it when handling the public Stop operation. However, its `terminate/2` callback only flushes an outstanding save. The loop has no guard monitoring the session; its per-tool guards monitor the loop itself. Consequently a session crash or direct supervisor termination can leave its already-running loop and tool workers alive under the separate task supervisor.

Sources:

- [Unlinked loop launch, session.ex 1245–1250](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/session.ex#L1245-L1250).
- [Termination callback, session.ex 1109–1116](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/session.ex#L1109-L1116).
- [Explicit Stop cleanup, session.ex 431–447](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/session.ex#L431-L447).
- [Tool guard observes loop only, loop.ex 593–607](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/loop.ex#L593-L607).
- [Existing shutdown test manually kills the loop, agent_test.exs 1005–1019](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/agent_test.exs#L1005-L1019).
- Upstream confirmation: [Elixir v1.17.3 Task.Supervised.reply/4](https://github.com/elixir-lang/elixir/blob/v1.17.3/lib/elixir/lib/task/supervised.ex#L30-L37) demonitoring its owner before invoking the task. The startup monitor does not provide ongoing owner-death cleanup.

The shutdown test's explicit `Process.exit(loop, :kill)` is significant: the assertion covers saving the transcript, but not ownership cleanup.

### Impact and boundary

An in-flight shell/script worker may continue changing the workspace after its session has disappeared. A reopened chat can obtain a new session and resume its saved turn while the previous loop still exists, creating overlapping work in what appears to be one chat. An orphan loop may also continue a model call or remain indefinitely waiting for approvals from a dead session.

This finding concerns a session disappearing while the application stays up. It does not claim that a full VM exit leaves BEAM processes alive, or that the ordinary Stop path lacks cleanup.

### Reproduction design and acceptance

Reuse `push_held_step/1` or a fake tool that announces its PID and blocks. Monitor session, loop and worker. Terminate or crash only the session; do not manually kill the loop as the current test does. Assert loop and worker shutdown and no later file-write effect. Reopen the same chat and assert that only the new turn runs. Repeat with a pending approval and with a shell process group.

Bind the loop's lifetime to the session with an explicit owner monitor/guard or supervision arrangement that still isolates a tool crash from the session. A `terminate/2` cleanup is useful but insufficient on its own for `:kill`, which cannot run the callback. Retain the current one-way loop-to-worker protection and the store's interrupted-turn semantics. Clarify session-death ownership in SESS rather than relying on the phrase “owns the task.”

## CORE-03 — Decodable but malformed chat records are not contained

**Priority:** P2. **Confidence:** high, source-confirmed; malformed-file fixture not executed.

`Store.decode/1` only rejects invalid external-term binaries. `load/1` then accepts any `%{messages: value}` and sends `value` to `Enum.map/2`. The metadata path accepts any decoded map, obtains `messages`, and calls `title/1`. A valid encoded `%{version: 1, messages: nil}` therefore raises in both paths. Other malformed fields, such as a non-`DateTime` `created_at`, reach sorting without normalization.

Sources: [load/1, store.ex 148–157](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/store.ex#L148-L157), [metadata decoding, 491–504](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/store.ex#L491-L504), [title and decode, 569–595](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/store.ex#L569-L595), and [all-entry sorting, 401–410](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/store.ex#L401-L410).

**Precondition:** a structurally invalid saved file, such as a damaged/manual/migrated fixture, exists in the session store. This is a robustness finding, not a demonstrated remote write path. The impact extends beyond opening that chat because `list/1`, `latest/0`, child lookup and the resumer scan traverse all entries. A malformed file can repeatedly crash the boot resumer; the eventual supervision impact depends on its restart policy and timing.

STORE-3 promises an empty history for corrupt records. Existing [cache corruption tests, 89–99](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/store_cache_test.exs#L89-L99) and [entry corruption test, 674–676](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/test/elia/store_test.exs#L674-L676) use non-term bytes and miss valid terms with invalid shapes.

Introduce one boundary validator/normalizer for the stored version and expected fields; keep legacy supported shapes and exact provider raw blocks. Quarantine or skip malformed records with a diagnostic rather than silently overwriting them. Test invalid root terms, `messages: nil`, malformed message members/blocks, invalid timestamps and task metadata, then assert that other valid chats still list and resume. Do not replace `binary_to_term(..., [:safe])` with unsafe decoding.

## CORE-04 — Failed saves lose their retry/dirty state

**Priority:** P2. **Confidence:** high for the code path; disk-failure/restart scenario not executed.

SESS-13 deliberately permits a failed save to be logged while the session continues. That is not itself the finding. The narrower defect is that `Session.save/1` cancels and clears `save_timer` before attempting the write and returns that state on failure. `terminate/2` retries only when the timer is present. A transient storage error can therefore leave a completed turn permanently unsaved even after storage recovers and the session shuts down gracefully.

Sources: [clear timer before save, session.ex 1121–1155](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/session.ex#L1121-L1155), [conditional shutdown save, 1114–1116](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/session.ex#L1114-L1116), [turn completion, 1184–1189](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/session.ex#L1184-L1189), and [resumption decision, 1272–1298](https://github.com/Tommos0/elia/blob/5be0bd873bd2716529de25541efb1825495cd12e/lib/elia/agent/session.ex#L1272-L1298).

Reproduction sequence: save the beginning of a turn successfully; fail its final write with an injected `{:error, :enospc}`; let the turn become idle; restore successful storage; shut down the session without any later message or settings mutation. The old file still has the active turn marker and lacks its completion. The next session can automatically resume work that already finished, with lost final messages and possible repeated side effects. This is more severe than merely showing an old title in a list.

Keep a separate dirty flag/generation until a write succeeds. Permit bounded retry without stopping the live chat, and let graceful termination retry dirty state even when no timer is pending. A persistent UI indicator would make the durability condition visible; log-only behavior is the existing contract and any UI change needs a deliberate spec update. Verify fault injection at interval saves, final saves and settings saves, including storage recovery with no subsequent mutation. Review SESS-44's broad “only abrupt VM termination loses messages” wording in light of real I/O failures.

## Notes for the orchestrator and future subagents

Read `specs/subtasks.md` and the executable implementation before the draft `specs/plans/subagents.md`. The draft's lines 40–42 say auto-approval is not inherited, while the current implementation explicitly copies it at `tasks.ex` 338–340. The spec index also describes concurrency as future work although per-worktree concurrency and its tests are present. Treat this as documentation drift, not evidence that concurrency should be removed.

Suggested separate work packages:

1. Fix and test external-project workspace selection (CORE-01); also review affected saved task baselines.
2. Define and enforce session-to-loop ownership (CORE-02); cover normal Stop, direct termination, crash and reopen.
3. Normalize stored records at their boundary (CORE-03) without losing legacy/raw provider content.
4. Retain dirty state through failed writes (CORE-04); test graceful-shutdown recovery with injected I/O failures.

These touch overlapping files, particularly `session.ex` and `agent_test.exs`. Parallel investigation is useful; integrate changes in a controlled order or separate worktrees. Coordinate all actual suite runs, since the repository's testing instructions forbid overlapping runs against shared `/tmp/elia-test-pN` fixtures.

Before implementation, follow the repository's spec workflow, including user approval of a drafted behavior change unless the user has explicitly waived it. The present review itself changes no behavior and required no spec-approval pause.

## Checks and limitations

- Read the core implementation and targeted tests/specifications; looked for contrary tests and intentional semantics before promoting a finding.
- Verified the external-project workspace selection through every caller to the tool context.
- Checked upstream Elixir task implementation for the unlinked-owner lifecycle claim.
- Did not run ExUnit, compile Elixir, exercise the browser or perform a live restart. The review does not claim tests pass or fail.
- Did not audit every possible race or prove exactly-once execution across machine failure. Batched transcript saves and automatic resume inherently need side-effect-aware recovery; the specification currently accepts losing the last interval on abrupt VM termination.
- Synchronous compaction in the session was raised to the parent reviewer for its LLM/compaction track and is not counted twice here.

