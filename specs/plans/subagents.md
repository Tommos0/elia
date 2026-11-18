# Plan: sub-agent workflow

Status: Draft. This is a plan, not a spec: it has no requirement IDs. Phase 1
writes `specs/subtasks.md` (prefix `SUBTASK`) before any code, and later phases
extend that spec.

**The design below is what is built.** Phases 1 to 4 are done and phase 5 is
not; `specs/subtasks.md` is the source of truth for what the feature does. The
**Decisions** and **Design sketch** sections here describe the feature as it
stands, and each phase below says what it built and marks the machinery that was
retired afterwards: a sub-task is an ordinary chat that ends when its chat is
marked done, so the per-child watcher, the registry of running children, the
writer lock, the task status vocabulary (`running`, `done`, `blocked`, `failed`,
`unfinished`, `cancelled`) and the `{:subtask, …}` event are gone (SUBTASK-33,
SUBTASK-34, and the retired SUBTASK-4, SUBTASK-8, SUBTASK-11, SUBTASK-28).

## Goal

A chat (the **parent**) can hand a focused piece of work to a **child** chat
with a fresh context, wait for it, and get back a short structured result. This
keeps long multi-step work (spec, implement, test, commit) from filling one
chat's context, and gives each step a focused session.

Out of scope for this plan: multiple projects and sandboxing. A per-task git
worktree started here as "later" and was never built into the spawn: a child
works in its parent's folder (SUBTASK-23) and makes its own worktree when it has
a code change to commit (DEPLOY-28).

## Decisions

- **A child is a normal chat.** It is an `Elia.Agent.Session` with its own saved
  history, shown in the chat list, inspectable and resumable, and ended by what
  ends any chat: its chat being marked done (SUBTASK-33). Nothing about it is
  special beyond the chat that started it — no status, lock, limit or record of
  what it changed of its own (SUBTASK-5, SUBTASK-15).
- **The child works where its parent does.** Its workspace is its parent's
  (SUBTASK-23, SUBTASK-30): the harness creates no worktree and forks no branch
  for it (DEPLOY-1). The worktree a child makes for its own code change is its
  own, on branch `chat/<its own id>` (DEPLOY-28), forked from the branch its
  brief names — its parent's, so it sees what its parent has committed — and
  the parent merges it when it wants the work (SUBTASK-23).
- **The parent is not blocked.** `spawn_task` starts the child and returns at
  once (SUBTASK-2); waiting is a separate `await_task` call (SUBTASK-27), so a
  parent carries on working and collects results later — one `await_task` per
  child, in whatever order suits, or a check on them with `list_chats`'s
  `children` filter (HIST-2).
- **The child sees the brief, not the parent transcript.** The brief is the
  whole interface. It still gets the normal system prompt (`AGENTS.md`, skills).
- **Depth 1.** A child has no `spawn_task` tool (SUBTASK-1).
- **The result is short and structured**, and only the result enters the
  parent's context: `{"task_id", "summary"}`, built by the harness from the
  child's last message when its chat is marked done (SUBTASK-9, SUBTASK-13).
  What the child changed is not in it: its branch and its transcript are where
  that is (SUBTASK-23, HIST-4).
- **Approvals happen in the child's own chat.** The parent's chat shows the
  `spawn_task` call as the tool call it is (UI-43) and the child's page links
  back to the chat that started it (SUBTASK-15, UI-48). The chat list shows a
  badge on a chat awaiting approval.
- **Auto-approval is inherited at the spawn.** The child's session starts with
  the parent's auto-approved tools (APPR-8, SUBTASK-6). Beyond that nothing is
  inherited: the user approves the spawn itself, and can change the child's
  auto-approval in the child's own chat (APPR-12).

## Design sketch

### Tools

- `spawn_task(title, brief, model?)`, parent only, approval `:required`
  (SUBTASK-1, SUBTASK-2). Returns as soon as the child has started, as JSON:
  `{"task_id", "title", "status"}`.
- `await_task(task_id)`, parent only, no approval: waits until that child's chat
  is marked done and returns `{"task_id", "summary"}` (SUBTASK-27, SUBTASK-9).
- There is no third tool. A parent lists its children with `list_chats`'s
  `children` filter (HIST-2), and a child ends by marking its chat done
  (SUBTASK-33, DONE-6) rather than by calling a tool of its own.

How tools are selected per session: `Elia.Agent.Loop` takes a `:skills` option
(LOOP-17); a child session passes the registry minus the `tasks` skill
(`Elia.Skills.for_child/1`), so it has exactly the tools an ordinary chat has
and no `spawn_task` (SUBTASK-1). The two tools live in a built-in skill
(`Elia.Skills.Tasks`) so each session's tool set is decided in one place.

### Spawning

1. Refuse, as a tool error the model can read, a `spawn_task` with an unknown
   model (SUBTASK-6) and one from a chat that is itself a child (SUBTASK-1).
   Nothing else is refused: there is no lock to take and no clean tree to
   require (the retired SUBTASK-4, SUBTASK-11).
2. Create the child chat with the metadata of a child — `parent_id` and
   `started_at` (SUBTASK-5, STORE-16) — and the spawn's title as its own title
   (STORE-32, TITLE-3), and start its session with the parent's loop options:
   its model unless `model` overrides it (MODEL-2), its auto-approved tools
   (APPR-8), its jail (ISOL-2).
3. Send the brief as the child's first user message, wrapped in a preamble that
   tells it: it is a sub-task agent; work only from this brief; commit its work
   on its own branch; say what it did in its last message, where anything the
   user must settle also goes; and then call `mark_done` (SUBTASK-5,
   SUBTASK-33, SUBTASK-38).
4. Return at once (SUBTASK-2). Nothing subscribes to the child's events: the
   harness builds and saves the result when the child's chat is marked done
   (SUBTASK-9, SUBTASK-13), and a parent that is waiting is told then
   (SUBTASK-27).

### No lock

There is no registry and no writer lock. A running child is a child chat whose
chat isn't marked done, read from the saved chats (`Elia.Store.children/1`,
STORE-17, STORE-18) — the same thing the chat list shows (UI-45, UI-46). Two
chats working in one tree are as ordinary as two chats in one project folder
(PROJ-12), so nothing is taken, held or released, a restart has nothing to
empty, and a resumed child has nothing to take again (RESUME-7). This is what
the retired `Elia.Tasks` registry did, and with it the retired SUBTASK-4 and
SUBTASK-11.

### Persistence

A child's task metadata is `parent_id` and `started_at`, and, once its chat is
marked done, `result` (STORE-16, STORE-18). It is saved with the history the
same way `model` and `auto_approve` are (STORE-9, STORE-14), with `load_task/1`
to read it back (STORE-44). Nothing per-task is listed: a child's status is its
chat's own (UI-59, UI-72), so a child whose turn a restart cut short is
`interrupted` like any chat (STORE-31, RESUME-7).

### Events

None of its own. A child's status reaches every view through the activity topic
(SESS-19) and its done flag through SESS-35, so the `{:subtask, call_id,
child_id, status}` event of the earlier design is retired with the card that
read it (the retired SUBTASK-7, UI-44). The link from a child to the chat that
started it is saved metadata (SUBTASK-15, STORE-17).

### Interaction with verification and checkpoints

Nothing special. A child's turn is a turn of an ordinary chat: it runs its tests
through the shell like any chat (VERIFY-11), and there is no turn checkpoint to
rebase — checkpoints are retired (CKPT), because a chat's work is in a worktree
of its own and git protects it (DEPLOY-28). The open point the earlier design
left here went with them.

## How to run this plan

Phases run in order, one chat each. Each starts from a clean git tree, writes the
spec first (add it to the index in `specs/README.md`), implements, tests with
requirement IDs, runs `mix precommit` and ends with one commit. Tick the phase
here when done and record any decision that changed. Each phase below says what
it built, and marks what was retired afterwards; `specs/subtasks.md`'s retired
requirements say why.

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

Decisions made in phase 1 (several retired since — see `specs/subtasks.md`):

- **Verification open point:** a spawn needed a clean git tree, and if the
  parent's turn changed core Elixir files, the tests had to pass first (the
  retired SUBTASK-4), with the parent's turn checkpoint rebased when the child
  ended (the retired SUBTASK-14). Neither is needed now: a child works in its
  parent's folder and makes its own worktree from the branch its brief names
  (SUBTASK-23, DEPLOY-28), and there is no turn checkpoint (CKPT).
- The result was recorded by a child-only `finish_task` (the retired
  SUBTASK-3). A child ends by marking its chat done instead (SUBTASK-33), and
  the harness builds the result from its last message (SUBTASK-9).
- The loop's tool context carries `call_id` and `loop_opts` (LOOP-18), and the
  `skills` option may be a function (LOOP-17).
- The session field for task metadata is `task_meta` (`task` is the running
  loop task).

- Write `specs/subtasks.md`: requirements for the tools, the spawn
  preconditions, the lock, the result shape, persistence and the verification
  interaction above. Update `agent-sessions.md` (new event) and
  `persistence.md` (task metadata) with new IDs.
- `Elia.Skills.Tasks` (the two tools), `Elia.Skills.for_child/1` (a child's
  skill list), the spawn and the child's session in `Elia.Agent`, and the task
  metadata in `Elia.Store`. The `Elia.Tasks` lock and the child's own step limit
  that phase 1 also added were retired later (the retired SUBTASK-11,
  SUBTASK-12).
- Tests use the LLM stub approach in `test/` (look at how `agent_test.exs`
  fakes the model): a scripted parent calls `spawn_task`, the child chat is
  marked done, and the result, the refusals and the persistence are asserted
  (`test/elia/tasks_test.exs`, `test/elia/store_test.exs`).
- No new UI beyond the child appearing in the chat list as an ordinary chat.

Read first: `docs/agents/harness.md`, `docs/agents/elixir.md`,
`docs/agents/testing.md`, `specs/agent-sessions.md`, `specs/agent-loop.md`,
`specs/persistence.md`, `specs/checkpoints.md`, `specs/verification.md`. Write
the spec before code, and tell the user which guarded files change.

### 2. UI: link, status, approvals

- [x] Spec, implementation, tests, commit (see `specs/chat-ui.md`, UI-43 to UI-49)

Decisions made in phase 2 (the card was retired since — see `specs/subtasks.md`):

- The card linked to the child through `parent_call_id` in the child's saved
  task metadata (SUBTASK-15, STORE-18) rather than only through the transient
  `:subtask` event, so it survived a reload. Both went with the card: a
  `spawn_task` call renders as the tool call it is (UI-43), and the child's own
  header links back to the chat that started it (SUBTASK-15, UI-48).
- The spec's UI-31 was reused by phase 1 (it collided with the "New chat"
  button); that entry is struck through and replaced by UI-43 and the retired
  UI-44.
- Approval badges come from a global `Elia.Agent.activity_topic/0`
  (`{:chat_status, id, status}`) and the session's status kept as its registry
  value (`Elia.Agent.awaiting_approval/0`), not from per-chat subscriptions
  (SESS-19). Children are nested, not put in a separate "Tasks" group.
- The child's own page got `{:task, metadata}` events (the retired SESS-20) so
  its header and result updated when the task's status changed. A child's
  status is its chat's own now (UI-59), and its page reads it like any chat's
  (UI-48).

Depends on 1.

- Parent transcript: a `spawn_task` call renders as the tool call it is, with
  its brief under it (UI-43) — not as the task card with the child's status and
  a link to it that phase 2 drew (the retired UI-44).
- Chat list: children nested under the chat that spawned them (UI-45), each
  showing its status the way any chat's row shows it (UI-46), and a badge on
  any chat awaiting approval so a pending child prompt is not missed.
- Child chat header: "Task of <parent>" with a link back to the chat that
  started it (SUBTASK-15, UI-48).
- Extend `chat-ui.md` with new IDs.

Read first: `docs/agents/phoenix-liveview.md`, `docs/agents/frontend.md`,
`specs/chat-ui.md`, `specs/subtasks.md`.

### 3. Control and robustness

- [x] Spec, implementation, tests, commit (see `specs/subtasks.md`, SUBTASK-16 to 22)

Decisions made in phase 3:

- A stopped turn told `Elia.Tasks` (`note_stop/1`, SESS-22), which marked the
  child cancelled and, when the stopped chat was the parent, stopped the child.
  The lock server also monitored the process running `spawn_task` and finished
  the job itself (in another process, keeping the lock) if that died, because
  a stopped parent kills that process before it can clean up (the retired
  SUBTASK-19). There is no lock server and no `cancelled`: stopping a parent's
  turn stops the turn of every child it has running, and each goes on as a
  sub-task (SUBTASK-16, SUBTASK-17, SESS-22).
- A child had a wall-clock budget of its own — the `max_minutes` input (default
  30, max 120, setting `:task_minutes`), with time spent awaiting approval not
  counting, and a reached budget gave `status: "failed"`, `reason: "budget"`
  (the retired SUBTASK-18). A child's limits are its own chat's now (LIMIT-5):
  a limit pauses its turn as any chat's does (LIMIT-4), and the user settles it
  in the child's chat (SUBTASK-24, SUBTASK-34).
- The result gained `task_id` (SUBTASK-9), and for a result that wasn't `done`
  `reason`, `start_commit` and `tree_clean` (the retired SUBTASK-21), with
  `reset_task(task_id)` to reset a child's workspace to its start commit (the
  retired SUBTASK-22). The status vocabulary and the rollback tool went: a task
  ends only when its chat is marked done (SUBTASK-33), and a child's work is
  discarded by not merging its branch (SUBTASK-23).
- Restart recovery is general, not only for `spawn_task`: any session whose
  saved history ends in unanswered tool calls closes them at start (SESS-21).
  The `interrupted` status already existed (STORE-17).

Depends on 1; order with 2 is free.

- **Cancel:** stopping the parent's turn (SESS-8) stops the turn of every child
  of that chat whose chat isn't marked done (SUBTASK-17, SESS-22), and each
  child goes on as a sub-task afterwards (SUBTASK-16). Stopping a child's own
  turn ends that turn and nothing more (SUBTASK-16).
- **Budget:** a child's limits are its own chat's (LIMIT-5), so reaching one
  pauses its turn as any chat's does (LIMIT-4) and the user decides in the
  child's chat (SUBTASK-24). There is no budget the harness imposes on a
  sub-task (the retired SUBTASK-12, SUBTASK-18).
- **Crash and restart:** a child whose session dies is still a sub-task — its
  chat isn't marked done (SUBTASK-34) — and after an app restart a parent's
  `await_task` call was closed with an error result (SESS-21) while its child is
  shown `interrupted` like any chat (SUBTASK-20, STORE-31).
- **Rollback on failure:** there is none. A child's work is on its own branch
  and the parent discards it by not merging it (SUBTASK-23); the tool that
  reset a tree in place is retired (SUBTASK-22).

Read first: `specs/subtasks.md`, `specs/agent-sessions.md`,
`specs/checkpoints.md`.

### 4. Concurrent sub-tasks

- [x] Spec, implementation, tests, commit (see `specs/subtasks.md`, SUBTASK-2,
  SUBTASK-27)

- `spawn_task` stops waiting: it returns at once, as
  `{"task_id", "title", "status"}`, and the parent's turn goes on (SUBTASK-2).
  Phase 4 did that with a watcher process that recorded the result (the retired
  SUBTASK-28); waiting is a plain `await_task` call now, whose process dying is
  that call ending (SUBTASK-27).
- `await_task` (parent only, no approval) is how the parent collects a result
  (SUBTASK-27). The `list_tasks` tool phase 4 added was retired: a parent lists
  its children with `list_chats` (HIST-2).
- `Elia.Tasks` was a registry of running children, one writer per workspace (the
  retired SUBTASK-11). It is gone: a running child is a child chat whose chat
  isn't marked done, read from the saved chats (STORE-17, STORE-18).
- The spawn no longer needs a clean tree, an ignored `.elia/` or a green test
  run: the child works in a branch of its own and leaves the parent's tree alone
  (SUBTASK-4, SUBTASK-23). SUBTASK-14 is retired.
- Stopping the parent's turn stops every child it has running (SUBTASK-17).

Depends on 1 to 3 (and a child's own worktree for a code change, SUBTASK-23).

Decisions made in phase 4 (the watcher and the registry were retired since —
see `specs/subtasks.md`):

- The watcher took the child's entry itself (`Elia.Tasks.acquire/4`) and was its
  owner, so the entry couldn't be taken before the workspace was reserved, and
  the spawn path waited for that one message (with a monitor on the watcher)
  before sending the brief. There is no watcher and no entry: the spawn returns
  as soon as the child's session has started (SUBTASK-2), and the result is
  built when the child's chat is marked done (SUBTASK-9, SUBTASK-13).
- A child whose session dies is finished by its watcher, not by the entry's
  monitor (the retired SUBTASK-19). Nothing has to be finished now: a session
  that dies leaves the child's chat unmarked, so the sub-task goes on and the
  user settles it in its chat (SUBTASK-34).
- `spawn_task` checked the workspace before creating anything (SUBTASK-4:
  "without creating a chat"), and `acquire/4` checked it again so two spawns
  couldn't race into one tree. Both went with the writer lock (SUBTASK-4).
- The end of a child was announced on `Elia.Tasks.task_topic/1` as well, so a
  wait never missed it. A wait now reads the child's chat and follows its own
  events: a child's end is its chat being marked done (SUBTASK-33), which its
  session announces (SESS-35).
- `reset_task` replaced the caller's turn checkpoint only when the reset
  happened in the caller's own workspace (the retired SUBTASK-22). The tool and
  the checkpoints are both retired (CKPT).

Read first: `specs/subtasks.md`, `docs/agents/testing.md`,
`docs/agents/elixir.md`.

### 5. Read-only children (reviewer, researcher)

- [ ] Spec, implementation, tests, commit

Depends on 1 and 3.

- `spawn_task(..., role: "reviewer" | "researcher")` gives the child only
  read-only tools (`read_file`, no `shell`, no `write_file`/`edit_file`), and
  forbids hot reload and commits. No shell, because a shell can't be made
  read-only without a sandbox.
- Several read-only children run at once, since they take no lock (there is no
  writer lock any more, SUBTASK-4) and need no clean tree. Whether they may run
  alongside a writer: decide in the spec (default: not alongside one, since they
  would read half-finished files).
- A reviewer's task is given a spec ID plus a commit range. Its findings go in
  its last message, and it ends by marking its chat done like any child
  (SUBTASK-9, SUBTASK-33).

Read first: `specs/subtasks.md`, `specs/workspace-policy.md`,
`specs/file-tools.md`.

## Later

- A user-facing "Run as task" action that starts a child from a brief without a
  parent chat.
- Children that return a patch for the parent to review instead of committing.
- Different default model per role.
