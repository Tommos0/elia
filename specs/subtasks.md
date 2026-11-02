# Sub-tasks

Status: Implemented (phases 1 to 3 of [the plan](plans/subagents.md): core,
task cards, a nested chat list and a task header in the chat UI, and cancel,
budget, crash recovery and reset; phase 4: concurrent sub-tasks)

A chat (the **parent**) can hand a focused piece of work to a **child** chat
with a fresh context and get back a short structured result. The child is an
ordinary saved chat with extra metadata linking it to its parent. In Elia's own
project the child gets its own worktree, so its in-progress work never touches
the parent's (SUBTASK-23). `spawn_task` returns as soon as the child has
started and does not wait for it (SUBTASK-2); the parent goes on working and
asks for results when it wants them with `list_tasks` and `await_task`
(SUBTASK-26, SUBTASK-27). Several children can therefore run at once, each in
its own workspace; children that would share one workspace are serialized
(SUBTASK-11).

## Requirements

### Tools

- **SUBTASK-1** The built-in skill `tasks` (`Elia.Skills.Tasks`, listed in the
  `builtin` config) provides `spawn_task`, `list_tasks` and `await_task`. A
  child session doesn't get them: its skills are the registry's skills without
  `tasks`, plus the skill `task`, which provides `finish_task`. A parent
  therefore has the three and not `finish_task`, and a child the reverse. The
  child's skills are read again every step (LOOP-17).
- **SUBTASK-2** `spawn_task` takes `title` and `brief` (both required, not
  blank), and optionally `model` (a model id, used on the parent's provider;
  default: the parent's own selection). It needs the user's approval (APPR-1)
  and returns as soon as the child has started — it does not wait for it
  (SUBTASK-8, SUBTASK-26, SUBTASK-27). Its output is that start as JSON:
  `{"task_id", "title", "status": "running"}`. The child's step limit is not
  part of the tool's schema, so the model doesn't choose it (SUBTASK-12).
- **SUBTASK-3** `finish_task` takes `status` (`done`, `blocked` or `failed`),
  `summary` (required) and optionally `questions` (an array of strings). It
  never needs approval. It records the child's result and returns a message
  telling the model to end its turn. Calling it again replaces the earlier
  record. Called outside the active child it returns an error.

### Spawning

- **SUBTASK-4** `spawn_task` is refused, as a tool error the model can read and
  without creating a chat, when:
  - the caller is itself a child (it has saved task metadata, or it is the
    active child). Depth is 1;
  - an active child already uses the same workspace root as this spawn would
    (SUBTASK-11), so two writers never share one tree;
  - the repository has no commit to fork from.

  The parent's own uncommitted changes are not a reason to refuse: the child
  runs in its own worktree forked from the parent's *committed* branch
  (SUBTASK-23), so nothing it can leave behind can be lost or wiped. The
  `tasks` skill instruction tells the parent to commit its work first, since
  the child won't see uncommitted changes.
- **SUBTASK-5** Otherwise `spawn_task` records the start commit (`HEAD`),
  creates a chat with a new id and saved task metadata (`parent_id`, `title`,
  `brief`, `started_at`, `status: "running"`, `start_commit`; STORE-16), starts
  its session with the parent's loop options (so the same model request fields
  and `verify` setting) except `skills` and `max_steps`, and sends it the
  brief as its first user message. The message starts with a short preamble: it
  is a sub-task agent, works only from this brief, commits its work, ends by
  calling `finish_task`, does not wait for the user, and lists unresolved
  questions in the result. It then starts a watcher process (SUBTASK-28) that
  owns the wait for the child, and `spawn_task` returns at once (SUBTASK-2).
- **SUBTASK-6** The child chat starts with a copy of the parent's auto-approved
  tools (APPR-8), so a user who has trusted a tool in the parent doesn't have to
  approve it again in every sub-task. The copy is the child's own set from then
  on (APPR-12): changing either chat's auto-approval afterwards never affects
  the other. With `model`, the child's selection is that model on the parent's
  provider; without it, the child starts with the parent's selection. Neither
  changes the stored default model (MODEL-15).
- **SUBTASK-7** `{:subtask, call_id, child_id, status}` is broadcast on the
  parent's topic (SESS-6) when the child starts (`"running"`) and again when it
  ends with its final status, where `call_id` is the `spawn_task` call.
  Approvals of the child's own tool calls happen in the child's chat.

### Finishing

- **SUBTASK-8** The child's turn has ended when its session goes idle. A
  watcher process, started at the spawn (SUBTASK-28), watches for that, builds
  the result and records it; the parent's `spawn_task` call doesn't wait. If the
  child session dies first, the result is `status: "failed"` with a summary
  saying so. The child's turn is verified, checkpointed and retried like any
  turn (VERIFY-3, LOOP-13, LOOP-14), so the end is only reached after
  verification.
- **SUBTASK-9** The result is a JSON object
  `{"status", "summary", "commit", "files", "questions"}`. `status` is what
  `finish_task` recorded, `"unfinished"` (SUBTASK-10) or `"failed"`. The
  harness, not the model, fills in `commit` (the new `HEAD` sha if it differs
  from the start commit, else `null`) and `files` (paths relative to the
  workspace that differ from the start commit, including untracked files,
  sorted). `questions` is a list, empty when none.
- **SUBTASK-10** If the turn ends without a `finish_task` call, the status is
  `"unfinished"` and the summary is the child's last assistant text. If the
  turn ended with an error (including a limit the user failed, SUBTASK-24), the
  status is `"failed"` and the summary is the error text, whatever
  `finish_task` said, since the work did not end the way the child claimed.
- **SUBTASK-11** `Elia.Tasks` (a `GenServer`, started on first use) is the
  registry of running children: it holds every active child with its parent.
  An entry is taken at spawn, released when the child ends, and also released
  when the child's session or the watcher process dies. `Elia.Tasks.active/0`
  returns the list of `%{child_id, parent_id}` for the active children (empty
  when none), and `Elia.Tasks.running?/1` says whether a chat is an active
  child. A spawn is refused (SUBTASK-4) when an active entry has the same
  workspace root, so a tree has at most one writer at a time; children in
  different worktrees (SUBTASK-23) run at once.
- **SUBTASK-12** The child's loop step limit is a loop option (LOOP-16),
  defaulting to the loop's own default (LOOP-3). It isn't in `spawn_task`'s
  schema, so the model doesn't choose it; a caller may still pass `max_steps`
  (default 100, at most 100) to override it, which tests use to reach the limit
  quickly. Reaching it pauses the child's turn (SUBTASK-24).
- **SUBTASK-13** When the child ends, its saved metadata gets the final
  `status` and the `result` (STORE-16, SESS-18), its entry is released, and the
  final `{:subtask, …}` event is broadcast.

### Interaction with checkpoints and verification

- ~~**SUBTASK-14**~~ *Retired (phase 4).* It used to replace the parent's turn
  checkpoint when the child ended, so a rollback couldn't wipe the child's
  work. The child now leaves the parent's workspace alone (SUBTASK-23) and
  `spawn_task` doesn't block the parent, so the parent's checkpoint is simply
  left where it is.

### UI support (phase 2)

- **SUBTASK-15** The saved task metadata also records `parent_call_id`, the id
  of the parent's `spawn_task` call (STORE-18), so the parent's page can show
  the child's card and link after a reload. The UI itself is specified in
  `chat-ui.md` (UI-43 to UI-49).

### Control and robustness (phase 3)

- **SUBTASK-16** Stopping a running child's turn (SESS-8) ends that child with
  status `"cancelled"` and reason `"cancelled"` (SUBTASK-21), whatever
  `finish_task` said. The summary says the user stopped it. Its entry is
  released and the saved task metadata gets the status (SUBTASK-13).
- **SUBTASK-17** Stopping the parent's turn (SESS-8) first stops the turn of
  every child of that parent that is still running, so each is also
  `"cancelled"` (SUBTASK-16). An `await_task` call in that turn (SUBTASK-27)
  gets the usual "Cancelled by the user." result, since the process running it
  is killed. Each child's final metadata, entry release and final
  `{:subtask, …}` event (SUBTASK-7, SUBTASK-13) are then done by `Elia.Tasks`
  itself (SUBTASK-19), not by that process.
- **SUBTASK-18** Budget: besides `max_steps` (SUBTASK-12), `spawn_task` takes
  `max_minutes`, a positive number of minutes of wall-clock time (default 30,
  at most 120; the application setting `:task_minutes` changes the default). The
  time a child spends with its status `:awaiting_approval` doesn't count. When
  the time is up, the child's turn pauses (SUBTASK-24). A child that hits its
  step limit (SUBTASK-12) pauses the same way.
- **SUBTASK-19** If a child's watcher process (SUBTASK-28) dies while the child
  is still running (it crashed), `Elia.Tasks` finishes the job itself without
  blocking the server: the child's turn is stopped, the saved status becomes
  `"failed"` (or `"cancelled"` when the user stopped it, SUBTASK-16/17) and the
  result is saved (only if the saved status is still `"running"`), the entry is
  released and the final `{:subtask, …}` event is broadcast. The server never
  calls a session itself, so it can't deadlock with one.
- **SUBTASK-20** After an app restart, a task saved as `"running"` is shown as
  `"interrupted"` (STORE-17), and a parent whose `await_task` call was still
  waiting gets that call closed with an error result when its session starts
  (SESS-21). No entry is held: it lives in memory.
- **SUBTASK-21** The result (SUBTASK-9) also has `task_id` (the child's chat id)
  and `reason`, which is `null` unless the status is not `"done"` because of
  `"budget"`, `"cancelled"`, `"crashed"` (the child session died, SUBTASK-8) or
  `"error"` (the turn ended with another error). When the status isn't `"done"`
  it also has `start_commit` and `tree_clean` (`git status --porcelain` is
  empty), so the parent knows whether uncommitted changes were left behind.
- **SUBTASK-22** The tool `reset_task` (parent only, in the skill `tasks`,
  approval `:required`) takes `task_id` (from a result) and resets the workspace
  to the task's `start_commit` with `git reset --hard` and `git clean -fd`
  (ignored files are kept), then replaces the caller's turn checkpoint
  (CKPT-10) so a later rollback can't restore the discarded work. For a
  sub-task in Elia's own project it resets the sub-task's own worktree
  (SUBTASK-23), not the parent's workspace, which the sub-task never touched
  (SUBTASK-25), and then the caller's checkpoint is left alone: the reset
  changed a different root, so the caller's own workspace is unchanged. It is
  never
  run automatically. It is refused, as a tool error and without changing
  anything, when: the chat isn't a task of the caller; its status is `"done"`;
  that task itself is still running (SUBTASK-11); the task has no
  `start_commit`; or the `start_commit` isn't an ancestor of `HEAD`. A task
  that was interrupted by a restart (SUBTASK-20) can be reset. Its output lists
  what was discarded (commits and changed files).
- **SUBTASK-23** A sub-task in Elia's own project works in its own git
  worktree, on branch `chat/<sub-task id>` forked from its parent's branch
  `chat/<parent id>` when it starts (DEPLOY-9). That worktree is its workspace:
  the file and shell tools, checkpoints and verification run there (DEPLOY-1),
  so its in-progress and uncommitted work never touches the parent's worktree.
  In another project, or when the parent has no worktree, the sub-task shares
  the parent's workspace, as before (DEPLOY-3).
- **SUBTASK-25** The harness never merges a sub-task's work into the parent's
  branch itself. A sub-task's committed work stays on its own branch
  `chat/<sub-task id>` (or, when it shares the parent's workspace, in the
  parent's workspace as before); `reset_task` (SUBTASK-22) discards it. Instead
  the parent is told, as a general instruction in the `tasks` skill and in the
  `spawn_task` result, how to bring it in itself: merge the branch when it wants
  the work (`git merge --ff-only chat/<task_id>`), rebasing and resolving
  conflicts when its own branch has moved. So the merge is the parent agent's
  decision, not a coded step, which lets several sub-tasks be merged in any
  order (or discarded) and keeps a concurrent-spawn design possible.
- **SUBTASK-24** A child runs with the loop's `:pause_on_limit` and a
  `:budget_ms` from `max_minutes` (LOOP-19, LOOP-20), so a limit pauses its turn
  instead of ending it: the child's session status becomes `:paused` (SESS-27)
  and its watcher (SUBTASK-28) — and so an `await_task` call on it
  (SUBTASK-27) — keeps waiting, with no deadline of its own. The user decides
  in the child's chat: Continue (`Elia.Agent.resume/1`) starts the step count
  and the budget over and the child goes on; Fail (`Elia.Agent.fail_task/1`)
  ends the turn with the limit's error, so the result is `"failed"` with reason
  `"budget"` (SUBTASK-9, SUBTASK-21) and a summary naming the limit. Stopping
  the paused turn (SESS-8) instead cancels the child (SUBTASK-16).

### Concurrency (phase 4)

- **SUBTASK-26** The tool `list_tasks` (parent only, in the skill `tasks`,
  approval `:never`) reports this chat's sub-tasks, newest first, as a JSON
  array of `{"task_id", "title", "status", "reason", "started_at"}`. `status`
  is `"running"` while the task's entry is held (SUBTASK-11), otherwise its
  final saved status (STORE-17; `"interrupted"` after a restart, SUBTASK-20).
  With `task_id` it reports just that one, as an object, and adds `result`
  (SUBTASK-9) once it has finished. It is an error when `task_id` is given and
  isn't a sub-task of this chat.
- **SUBTASK-27** The tool `await_task` (parent only, in the skill `tasks`,
  approval `:never`) takes `task_id` and waits until that sub-task is no longer
  running (SUBTASK-8), then returns its `result` (SUBTASK-9) as JSON. A task
  that has already finished returns at once, from its saved metadata. It is a
  tool error when `task_id` isn't a sub-task of this chat, and when the wait is
  interrupted (the parent's turn is stopped, SUBTASK-17, or the app restarts,
  SUBTASK-20). One `await_task` per spawn lets the parent wait for several
  children in whatever order it likes; it can also carry on without waiting and
  check later with `list_tasks`.
- **SUBTASK-28** The watcher: a process the harness starts per child, in the
  task supervisor (like the process running a tool call, LOOP-10), that owns
  the wait for that child's turn to end (SUBTASK-8). It is the child's entry
  owner (SUBTASK-11), so `Elia.Tasks` can finish the job if it dies
  (SUBTASK-19), and it records the result, the saved metadata and the final
  event (SUBTASK-13) when the child ends. It also announces that end on the
  child's own task topic (`Elia.Tasks.task_topic/1`), so a wait for the child
  (SUBTASK-27) can never miss it — including when `Elia.Tasks` had to finish
  the job itself (SUBTASK-19). Because it is separate from the parent's turn,
  `spawn_task` returns at once (SUBTASK-2) and several watchers can run at
  once.

## Out of scope (later phases of the plan)

Read-only children (phase 5).

## Implementation

`Elia.Tasks` (the registry of running children, spawn, await, cancel, reset),
`Elia.Skills.Tasks` (the skills and tools), `Elia.Store` (metadata),
`Elia.Agent.Session` (task metadata, `selection` option, stop, dangling calls),
`Elia.Agent.Loop` (`max_steps`, skill functions, tool context),
`Elia.Deploy` (the child's own worktree).

Core files touched: `lib/elia/agent/loop.ex`, `lib/elia/skills.ex`,
`lib/elia/skills/tasks.ex`, `lib/elia/deploy.ex`, `config/config.exs`.
(`lib/elia/tasks.ex` and `lib/elia/deploy.ex` carry the per-sub-task worktree
and the concurrent registry, SUBTASK-11, SUBTASK-23, SUBTASK-26 to SUBTASK-28.
`lib/elia/checkpoint.ex` and `lib/elia/harness.ex` are no longer involved:
retiring SUBTASK-14 removed the `Checkpoint.rebase/1` and
`Harness.core_elixir_changed?/1` calls from the spawn path.)

## Tests

`test/elia/tasks_test.exs`, `test/elia/tasks_concurrency_test.exs` (two
children at once, each in its own worktree), `test/elia/store_test.exs`,
`test/elia/agent_test.exs`, `test/elia/deployment_test.exs`,
`test/elia_web/live/task_ui_test.exs`.
