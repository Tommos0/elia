# Plan: sub-agent workflow

Status: Draft. This is a plan, not a spec: it has no requirement IDs. Phase 1
writes `specs/subtasks.md` (prefix `SUBTASK`) before any code, and later phases
extend that spec.

## Goal

A chat (the **parent**) can hand a focused piece of work to a **child** chat
with a fresh context, wait for it, and get back a short structured result. This
keeps long multi-step work (spec, implement, test, commit) from filling one
chat's context, and gives each step a focused session.

Out of scope for this plan: multiple projects and sandboxing. Per-task git
worktrees started here as "later" and became phase 4 (concurrent sub-tasks).

## Decisions

- **Concurrent writers, each in its own worktree** (phase 5, formerly "later").
  A child in Elia's own project works in its own git worktree, so it never
  touches its parent's tree; `spawn_task` returns as soon as the child starts
  and the parent goes on working, asking for results with `list_tasks` and
  `await_task`. Children that would share one workspace (another project, or no
  worktree) are still serialized, one writer per tree. Read-only children
  running alongside a writer remain out of scope (phase 5).
- **A child is a normal chat.** It is a `Elia.Agent.Session` with its own saved
  history, shown in the chat list, inspectable and resumable. It only has extra
  metadata linking it to its parent.
- **The parent is not blocked.** A per-child watcher process (a task in the
  task supervisor, LOOP-10) owns the wait, so `spawn_task` returns as soon as
  the child has started and the parent's turn goes on (phase 5).
- **The child sees the brief, not the parent transcript.** The brief is the
  whole interface. It still gets the normal system prompt (`AGENTS.md`, skills).
- **Depth 1.** A child has no `spawn_task` tool.
- **The result is structured**, and only the result enters the parent's context:
  `%{status, summary, commit, files, questions}`.
- **Approvals happen in the child's own chat.** The parent's chat shows a link
  to the child and that it is waiting. The chat list shows a badge on a chat
  awaiting approval.
- **Auto-approval is not inherited.** A child starts with no auto-approved
  tools. The user approves the spawn itself, and can turn on auto-approval in
  the child chat.

## Design sketch

### Tools

- `spawn_task(title, brief, model?, max_minutes?)`, parent only, approval
  `:required`. Returns as soon as the child has started. `list_tasks` and
  `await_task` (parent only, no approval) report status and bring the result
  back (phase 5, SUBTASK-26, SUBTASK-27).
- `finish_task(status, summary, questions?)`, child only. `status` is `done`,
  `blocked` or `failed`. The harness, not the model, fills in `commit` (HEAD if
  it changed since the spawn) and `files` (changed paths since the spawn).
  If the child's turn ends without calling it, the result is
  `status: "unfinished"` with the child's last assistant text as `summary`.

How tools are selected per session: `Elia.Agent.Loop` already takes a `:skills`
option; a child session passes a skill list that has `finish_task` and not
`spawn_task`, and the parent has the reverse. The tools live in a built-in skill
(`Elia.Skills.Tasks`) so each session's tool set is decided in one place.

### Spawning

1. Refuse (as a tool error the model can read) when: the caller is itself a
   child, a child is already active, or the git tree is dirty. A clean tree
   means a failed or cancelled child can be rolled back to a known point. Check
   that `.elia/` is ignored, so chat files don't make the tree dirty.
2. Record the start commit, create the child chat id, save its metadata
   (`parent_id`, `title`, `brief`, `started_at`, `status: running`) and start
   its session.
3. Send the brief as the child's first user message, wrapped with a short
   preamble (you are a sub-task agent, work only from this brief, finish by
   calling `finish_task`, don't wait for the user, list unresolved questions in
   the result).
4. Subscribe to the child's events and wait for its turn to end, then build the
   result and mark the child `done`/`blocked`/`failed`/`cancelled`.

### The lock

A small `GenServer` (`Elia.Tasks`) is the registry of running children. It
holds each active child with its parent, monitors the child's session and its
watcher, and releases the entry when either dies. Since phase 5 it allows one
child per workspace, so children in their own worktrees run at once and
children sharing a tree are serialized.

### Persistence

`Elia.Store.save/3` gains an option for task metadata, saved with the history
the same way `model` and `auto_approve` are (STORE-9/14 style, with a loader
`load_task/1`). `Store.list/1` entries get `parent_id` and `task_status`.
On startup a child saved as `running` with no live session is shown as
`interrupted`.

### Events

New session event on the parent's topic: `{:subtask, call_id, child_id, status}`,
so the parent's UI can link the tool call to the child chat. Added to SESS-6
without renumbering.

### Interaction with verification and checkpoints

The child's turn is verified like any turn (VERIFY-3) and checkpointed on its
first change, so a child whose tests fail is rolled back and told why, with the
usual two-attempt limit. **Open point for phase 1:** the parent's turn then ends
and is verified against the parent's own turn checkpoint. Read
`specs/checkpoints.md` and `specs/verification.md` and make sure a parent
rollback can't wipe a child's committed work (checkpoints never touch HEAD,
but the working tree is restored), or that the parent's verify is skipped when
the tree has not changed since the child's last verified commit. Decide this in
the spec.

## How to run this plan

Phases run in order, one chat each. Each starts from a clean git tree, writes the
spec first (add it to the index in `specs/README.md`), implements, tests with
requirement IDs, runs `mix precommit` and ends with one commit. Tick the phase
here when done and record any decision that changed.

To start a phase, open a fresh chat and say: *"Implement phase N of
`specs/plans/subagents.md`."* The phase's **Read first** list says which docs
and specs to open; the chat reads them itself. Until phase 1 exists the user
plays the parent. Once `spawn_task` exists, the parent writes the child's brief
the same way: the goal, what to read, and what "done" means.

Several phases touch guarded files (`lib/elia/agent/loop.ex` and
`lib/elia/skills/*.ex` are guarded; `lib/elia/agent/session.ex` is core but not
guarded). Say so when it happens, and don't weaken any guardrail.

## Phases

### 1. Core: spawn, finish, lock, result (`SUBTASK-*`)

- [x] Spec, implementation, tests, commit (see `specs/subtasks.md`)

Decisions made in phase 1:

- **Verification open point:** a spawn needs a clean git tree, and if the
  parent's turn changed core Elixir files, the tests must pass first
  (SUBTASK-4). When the child ends, the parent's turn checkpoint is replaced
  by a fresh snapshot (`Checkpoint.rebase/1`, SUBTASK-14), so a parent rollback
  never wipes the child's work and the parent's earlier changes were already
  verified.
- `finish_task` only records the result; the turn ends when the model stops.
  The harness fills `commit` and `files` at that point, after verification. A
  turn that ends in an error is `failed` even if `finish_task` said `done`.
- `Elia.Tasks` is started lazily under `Elia.Agent.Supervisor` instead of in
  `application.ex`, so a hot-reloaded dev server needs no restart.
- `max_steps` is already accepted and capped at 100 (default 50); phase 3 adds
  the wall-clock limit.
- The loop's tool context now has `call_id` and `loop_opts` (LOOP-18); the
  `skills` option may be a function (LOOP-17).
- The session field for task metadata is `task_meta` (`task` is the running
  loop task).

- Write `specs/subtasks.md`: requirements for the tools, the spawn
  preconditions, the lock, the result shape, persistence and the verification
  interaction above. Update `agent-sessions.md` (new event) and
  `persistence.md` (task metadata) with new IDs.
- `Elia.Tasks` (lock and spawn/await), `Elia.Skills.Tasks` (the two tools),
  `Store` metadata, per-session skill lists, session option for a step limit.
- Tests use the existing LLM stub approach in `test/` (look at how
  `agent_test.exs` fakes the model): a scripted parent calls `spawn_task`, a
  scripted child calls `finish_task`, assert the result, the lock release, the
  refusals (dirty tree, second child, child spawning) and persistence.
- No new UI beyond the child appearing in the chat list as an ordinary chat.

Read first: `docs/agents/harness.md`, `docs/agents/elixir.md`,
`docs/agents/testing.md`, `specs/agent-sessions.md`, `specs/agent-loop.md`,
`specs/persistence.md`, `specs/checkpoints.md`, `specs/verification.md`. Write
the spec before code, and tell the user which guarded files change.

### 2. UI: link, status, approvals

- [x] Spec, implementation, tests, commit (see `specs/chat-ui.md`, UI-43 to UI-49)

Decisions made in phase 2:

- The card links to the child through `parent_call_id` in the child's saved
  task metadata (SUBTASK-15, STORE-18) rather than only through the transient
  `:subtask` event, so it survives a reload. Children from before phase 2 have
  no call id and show no card.
- The spec's UI-31 was reused by phase 1 (it collided with the "New chat"
  button); that entry is struck through and replaced by UI-43/44.
- Approval badges come from a global `Elia.Agent.activity_topic/0`
  (`{:chat_status, id, status}`) and the session's status kept as its registry
  value (`Elia.Agent.awaiting_approval/0`), not from per-chat subscriptions
  (SESS-19). Children are nested, not put in a separate "Tasks" group.
- The child's own page gets `{:task, metadata}` events (SESS-20) so its header
  and result update when `Elia.Tasks` saves the final status.

Depends on 1.

- Parent transcript: a `spawn_task` call renders as a task card with the title,
  child status and a link to the child chat (from the `:subtask` event and
  `Store` metadata).
- Chat list: children nested under their parent (or filtered into a "Tasks"
  group), status icon, and a badge on any chat awaiting approval so a pending
  child prompt is not missed.
- Child chat header: "Task of <parent>" with a link back, the brief, and the
  result once finished.
- Extend `chat-ui.md` with new IDs.

Read first: `docs/agents/phoenix-liveview.md`, `docs/agents/frontend.md`,
`specs/chat-ui.md`, `specs/subtasks.md`.

### 3. Control and robustness

- [x] Spec, implementation, tests, commit (see `specs/subtasks.md`, SUBTASK-16 to 22)

Decisions made in phase 3:

- A stopped turn tells `Elia.Tasks` (`note_stop/1`, SESS-22), which marks the
  child cancelled and, when the stopped chat is the parent, stops the child.
  The lock server also monitors the process running `spawn_task` and finishes
  the job itself (in another process, keeping the lock) if that dies, because
  a stopped parent kills that process before it can clean up (SUBTASK-19). The
  lock server never calls a session, so it can't deadlock with one.
- The wall-clock limit is the `max_minutes` input (default 30, max 120, setting
  `:task_minutes`). Time spent awaiting approval in the child doesn't count.
  Both limits give `status: "failed"`, `reason: "budget"`.
- The result gained `task_id` and `reason`, and for non-`done` results
  `start_commit` and `tree_clean` (SUBTASK-21). `reset_task(task_id)` (approved,
  parent only) resets to the start commit with `git reset --hard` + `git clean
  -fd`, only when the start commit is an ancestor of `HEAD`, and rebases the
  parent's checkpoint (SUBTASK-22).
- Restart recovery is general, not only for `spawn_task`: any session whose
  saved history ends in unanswered tool calls closes them at start (SESS-21).
  The `interrupted` status already existed (STORE-17).

Depends on 1; order with 2 is free.

- **Cancel:** stopping the parent (SESS-8) stops its active child. Stopping the
  child ends it with `status: "cancelled"`, and the parent's `spawn_task`
  returns that as a tool result. Both release the lock.
- **Budget:** `max_steps` per child (default 50, capped), and a wall-clock limit,
  ending the child with `status: "failed"` and reason `budget`.
- **Crash and restart:** a child session crash returns `status: "failed"` to the
  parent. After an app restart, a parent whose tool call was waiting is closed
  with an error result (as SESS-12 does) and its child is shown `interrupted`.
- **Rollback on failure:** when the result is not `done`, include whether the
  tree is clean, and give the parent a way to ask for it to be reset to the start
  commit (a separate, approved step, not automatic).

Read first: `specs/subtasks.md`, `specs/agent-sessions.md`,
`specs/checkpoints.md`.

### 4. Concurrent sub-tasks

- [x] Spec, implementation, tests, commit (see `specs/subtasks.md`, SUBTASK-1,
  SUBTASK-2, SUBTASK-4, SUBTASK-8, SUBTASK-11, SUBTASK-26 to SUBTASK-28)

- `spawn_task` stops waiting: it starts a watcher process and returns
  `{task_id, title, status: "running"}`; the watcher records the result
  (SUBTASK-28).
- `list_tasks` and `await_task` (parent only, no approval) are how the parent
  checks on children and collects results (SUBTASK-26, SUBTASK-27).
- `Elia.Tasks` becomes a registry of running children, one writer per
  workspace, instead of a single global lock (SUBTASK-11).
- The spawn no longer needs a clean tree, an ignored `.elia/` or a green test
  run: the child forks from the parent's committed branch and leaves the
  parent's tree alone (SUBTASK-4). SUBTASK-14 is retired.
- Stopping the parent stops every child it has running (SUBTASK-17).

Depends on 1 to 3 (and the per-sub-task worktree, SUBTASK-23).

Decisions made in phase 4:

- The watcher takes the child's entry itself (`Elia.Tasks.acquire/4`) and is its
  owner, so the entry can't be taken before the workspace is reserved, and the
  spawn path waits for that one message (with a monitor on the watcher) before
  sending the brief. It also waits for the brief to go out before it starts
  waiting, so a parent whose turn is stopped in that window leaves nothing
  behind.
- A child whose session dies is finished by its watcher, not by the entry's
  monitor: the entry is released a moment later, so an `await_task` that starts
  in between still gets the result instead of finding an interrupted task.
- `spawn_task` still checks the workspace before creating anything (SUBTASK-4:
  "without creating a chat"); `acquire/4` checks it again, so two spawns can't
  race into one tree.
- The end of a child is announced on `Elia.Tasks.task_topic/1` as well, so a
  wait never misses it; `Elia.Tasks` announces it too when it has to finish a
  crashed watcher's job (SUBTASK-19).
- `reset_task` replaces the caller's turn checkpoint only when the reset
  happened in the caller's own workspace; a sub-task's worktree is a different
  root, which the caller's checkpoint never held (SUBTASK-22).

Read first: `specs/subtasks.md`, `docs/agents/testing.md`,
`docs/agents/elixir.md`.

### 5. Read-only children (reviewer, researcher)

- [ ] Spec, implementation, tests, commit

Depends on 1 and 3.

- `spawn_task(..., role: "reviewer" | "researcher")` gives the child only
  read-only tools (`read_file`, no `shell`, no `write_file`/`edit_file`), and
  forbids hot reload and commits. No shell, because a shell can't be made
  read-only without a sandbox.
- Read-only children don't take the writing lock, so several can run at once,
  and they don't need a clean tree. They may run while no writer is active, or
  alongside one: decide in the spec (default: not alongside a writer, since they
  would read half-finished files).
- A reviewer's task is given a spec ID plus a commit range. Its `finish_task` result
  is a list of findings in `questions`/`summary`.

Read first: `specs/subtasks.md`, `specs/workspace-policy.md`,
`specs/file-tools.md`.

## Later

- A user-facing "Run as task" action that starts a child from a brief without a
  parent chat.
- Children that return a patch for the parent to review instead of committing.
- Different default model per role.
