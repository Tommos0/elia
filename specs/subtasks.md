# Sub-tasks

Status: Implemented

Phases 1 to 3 of [the plan](plans/subagents.md) are done: core, task cards, a
nested chat list and a task header in the chat UI, stopped turns, budget and
crash recovery. The reset tool is retired (SUBTASK-22). Phase 4, concurrent
sub-tasks, is not done yet.

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
  its session with the parent's loop options (so the same model request fields)
  except `skills` and `max_steps`, and sends it the
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

- **SUBTASK-8** The child's turn has ended when its session goes idle — unless
  the user stopped that turn, which ends the turn but not the task (SUBTASK-16),
  so the watcher waits for the next one. A watcher process, started at the spawn
  (SUBTASK-28), watches for the end, builds the result and records it; the
  parent's `spawn_task` call doesn't wait. If the child session dies first, the
  result is `status: "failed"` with a summary saying so. The child's turn is an
  ordinary turn (LOOP), so nothing else happens at its end.
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
- **SUBTASK-12** The child's step limit becomes the child chat's own limit
  (LIMIT-2, LIMIT-5), defaulting to the loop's own default (LOOP-3). It isn't in
  `spawn_task`'s
  schema, so the model doesn't choose it; a caller may still pass `max_steps`
  (default 100, at most 100) to set it, which tests use to reach the limit
  quickly. Reaching it pauses the child's turn (SUBTASK-24).
- **SUBTASK-13** When the child ends, its saved metadata gets the final
  `status` and the `result` (STORE-16, SESS-18), its entry is released, and the
  final `{:subtask, …}` event is broadcast.

### Retired: interaction with checkpoints and verification

- ~~**SUBTASK-14**~~ Retired: phase 4 dropped it. It used to replace the
  parent's turn checkpoint when the child ended, so a rollback couldn't wipe
  the child's work. The child leaves the parent's workspace alone (SUBTASK-23)
  and `spawn_task` doesn't block the parent, so there was nothing left to
  replace — and checkpoints themselves are gone now (CKPT, VERIFY).

### UI support (phase 2)

- **SUBTASK-15** The saved task metadata also records `parent_call_id`, the id
  of the parent's `spawn_task` call (STORE-18), so the parent's page can show
  the child's card and link after a reload. The UI itself is specified in
  `chat-ui.md` (UI-43 to UI-49).

### Control and robustness (phase 3)

- **SUBTASK-16** Stopping a running child's turn (SESS-8) ends that turn and
  nothing more. The turn ends as any stop does — the transcript says the user
  stopped it (STOP-1, STOP-2), open tool calls get their error results and the
  chat's status goes idle — but the sub-task doesn't end: no result is built or
  saved, its saved task metadata stays `"running"`, and a `finish_task` record
  the child made before the stop is kept for whenever the task does end
  (SUBTASK-9). Its entry stays held (SUBTASK-11), so the child is still a
  running child (and still holds its workspace: a spawn into that tree is
  refused, SUBTASK-4), and no final `{:subtask, …}` event is broadcast
  (SUBTASK-7, SUBTASK-13). What the stopped turn had reported before it was
  stopped is not its result either (STOP-4). The task ends later, at the end of
  a turn the user did not stop (SUBTASK-8): the child runs again when the user
  sends it a message — its history holds the stop (STOP-3) — and ends with what
  that turn gives (SUBTASK-9, SUBTASK-10). *Changed:* it used to end the child
  as `"cancelled"`, so that is no longer a status the harness gives a task (a
  task saved by an older version may still have one, UI-44, UI-50).
- **SUBTASK-17** Stopping the parent's turn (SESS-8) first stops the turn of
  every child of that parent that is still running, so the user's stop really
  stops the work, but each of those children then goes on as a sub-task
  (SUBTASK-16): its turn ends, the task doesn't. An `await_task` call in that
  turn (SUBTASK-27) gets the usual "Cancelled by the user." result, since the
  process running it is killed; the children keep their entries and their own
  watchers (SUBTASK-28) finish them later, when a turn of theirs ends
  (SUBTASK-8) — not the killed parent process.
- **SUBTASK-18** Budget: besides `max_steps` (SUBTASK-12), `spawn_task` takes
  `max_minutes`, a positive number of minutes of wall-clock time (default 30,
  at most 120; the application setting `:task_minutes` changes the default). The
  time a child spends with its status `:awaiting_approval` doesn't count. When
  the time is up, the child's turn pauses (SUBTASK-24). A child that hits its
  step limit (SUBTASK-12) pauses the same way. Both are set as the child
  chat's own limits when it is spawned (LIMIT-5), so from then on they belong
  to that chat and can be changed in its settings page (LIMIT-6).
- **SUBTASK-19** If a child's watcher process (SUBTASK-28) dies while the child
  is still running (it crashed), `Elia.Tasks` finishes the job itself without
  blocking the server: the child's turn is stopped, the saved status becomes
  `"failed"` with reason `"crashed"` (SUBTASK-21) and the result is saved (only
  if the saved status is still `"running"`), the entry is released and the final
  `{:subtask, …}` event is broadcast. The server never calls a session itself,
  so it can't deadlock with one.
- **SUBTASK-20** After an app restart, a task saved as `"running"` is shown as
  `"interrupted"` (STORE-17), and a parent whose `await_task` call was still
  waiting gets that call closed with an error result when its session starts
  (SESS-21). No entry is held: it lives in memory.
- **SUBTASK-21** The result (SUBTASK-9) also has `task_id` (the child's chat id)
  and `reason`, which is `null` unless the status is not `"done"` because of
  `"budget"`, `"cancelled"`, `"crashed"` (the child session died, SUBTASK-8) or
  `"error"` (the turn ended with another error). (`"cancelled"` was what a
  stopped turn gave before SUBTASK-16 changed, so a task saved by an older
  version may still have it.) When the status isn't `"done"`
  it also has `start_commit` and `tree_clean` (`git status --porcelain` is
  empty), so the parent knows whether uncommitted changes were left behind.
- ~~**SUBTASK-22** The tool `reset_task` (parent only, in the skill `tasks`,
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
  what was discarded (commits and changed files).~~ Retired: in a worktree a
  sub-task's work stays on its own branch `chat/<task_id>` and is never merged
  (SUBTASK-25), so discarding it is ordinary git in that worktree — or simply
  deleting the sub-task's chat, which removes the worktree and prunes the branch
  (DEPLOY-10). There is also no caller checkpoint to replace (CKPT).
- **SUBTASK-23** A sub-task in Elia's own project works in its own git
  worktree, on branch `chat/<sub-task id>` forked from its parent's branch
  `chat/<parent id>` when it starts (DEPLOY-9). That worktree is its workspace:
  the file and shell tools and `mix test` run there (DEPLOY-1), so its
  in-progress and uncommitted work never touches the parent's worktree.
  In another project, or when the parent has no worktree, the sub-task shares
  the parent's workspace, as before (DEPLOY-3).
- **SUBTASK-25** The harness never merges a sub-task's work into the parent's
  branch itself. A sub-task's committed work stays on its own branch
  `chat/<sub-task id>` (or, when it shares the parent's workspace, in the
  parent's workspace as before), for the parent to merge or leave alone. Instead
  the parent is told, as a general instruction in the `tasks` skill and in the
  `spawn_task` result, how to bring it in itself: merge the branch when it wants
  the work (`git merge --ff-only chat/<task_id>`), rebasing and resolving
  conflicts when its own branch has moved. So the merge is the parent agent's
  decision, not a coded step, which lets several sub-tasks be merged in any
  order (or discarded) and keeps a concurrent-spawn design possible.
- **SUBTASK-24** A child's limits are the ones set at its spawn — `max_steps`
  from SUBTASK-12 and `max_minutes` from SUBTASK-18, with `pause_on_limit` on
  (LIMIT-5) — so a limit pauses its turn
  instead of ending it: the child's session status becomes `:paused` (SESS-27)
  and its watcher (SUBTASK-28) — and so an `await_task` call on it
  (SUBTASK-27) — keeps waiting, with no deadline of its own. The user decides
  in the child's chat: Continue (`Elia.Agent.resume/1`) starts the step count
  and the budget over and the child goes on; Fail (`Elia.Agent.fail_task/1`)
  ends the turn with the limit's error, so the result is `"failed"` with reason
  `"budget"` (SUBTASK-9, SUBTASK-21) and a summary naming the limit. Stopping
  the paused turn (SESS-8) instead ends that turn with no result — the child
  goes on running (SUBTASK-16), with its limits unchanged (LIMIT-5), so a later
  turn of it pauses at the limit again unless the user continues that one.

### Concurrency (phase 4)

- **SUBTASK-26** The tool `list_tasks` (parent only, in the skill `tasks`,
  approval `:never`) reports this chat's sub-tasks, newest first, as a JSON
  array of `{"task_id", "title", "status", "reason", "started_at"}`. `status`
  is `"running"` while the task's entry is held (SUBTASK-11), otherwise its
  final saved status (STORE-17; `"interrupted"` after a restart, SUBTASK-20). A
  child whose turn the user stopped still holds its entry, so it is still
  reported as `"running"` (SUBTASK-16, SUBTASK-31).
  With `task_id` it reports just that one, as an object, and adds `result`
  (SUBTASK-9) once it has finished. It is an error when `task_id` is given and
  isn't a sub-task of this chat.
- **SUBTASK-27** The tool `await_task` (parent only, in the skill `tasks`,
  approval `:never`) takes `task_id` and waits until that sub-task is no longer
  running (SUBTASK-8), then returns its `result` (SUBTASK-9) as JSON. A turn of
  it that the user stopped is not an end (SUBTASK-16), so the wait goes on. A
  task that has already finished returns at once, from its saved metadata. It
  is a tool error when `task_id` isn't a sub-task of this chat, and when the
  wait is interrupted (the parent's turn is stopped, SUBTASK-17, or the app
  restarts, SUBTASK-20). One `await_task` per spawn lets the parent wait for
  several children in whatever order it likes; it can also carry on without
  waiting and check later with `list_tasks`.
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

- **SUBTASK-29** Saving a child's final metadata when its session is gone
  (SUBTASK-13, SUBTASK-19), by writing straight to disk, never recreates a chat
  that was deleted: it saves only while the child's file still exists
  (`Elia.Store.exists?/1`, STORE-24), so a running sub-task chat the user
  deletes (SESS-29, UI-65) stays deleted rather than being written back by its
  watcher.

- **SUBTASK-30** The child chat starts with a copy of the parent's jail setting
  (ISOL-18): jailed unless the parent's is off, even where the parent's own
  value is the default and so isn't in its file (STORE-26). The copy is the
  child's own from then on (ISOL-18): changing either chat's setting afterwards
  never affects the other.

- **SUBTASK-31** From everywhere but the child's own chat, a sub-task whose turn
  the user stopped is an ordinary running task (SUBTASK-16): `list_tasks`
  reports it as `"running"` (SUBTASK-26), `await_task` on it keeps waiting with
  no deadline of its own (SUBTASK-27), and its card in the parent's page stays
  the running card it was (UI-44). It still ends the ordinary ways: a later turn
  of the child ends (SUBTASK-8 to SUBTASK-10), a limit the user fails
  (SUBTASK-24), its session dies (SUBTASK-8, SUBTASK-19), or the user deletes
  the child's chat (SESS-29, SUBTASK-29).

## Out of scope

Read-only children (phase 5).

## Implementation

`Elia.Tasks` (the registry of running children, spawn, await, and the mark a
stopped turn leaves so the child's watcher doesn't finish its task),
`Elia.Skills.Tasks` (the skills and tools), `Elia.Store` (metadata),
`Elia.Agent.Session` (task metadata, `selection` option, stop, dangling calls),
`Elia.Agent.Loop` (`max_steps`, skill functions, tool context),
`Elia.Deploy` (the child's own worktree).

Core files touched: `lib/elia/agent/loop.ex`, `lib/elia/skills.ex`,
`lib/elia/skills/tasks.ex`, `lib/elia/deploy.ex`, `config/config.exs`.
(`lib/elia/tasks.ex` and `lib/elia/deploy.ex` carry the per-sub-task worktree
and the concurrent registry, SUBTASK-11, SUBTASK-23, SUBTASK-26 to SUBTASK-28.
Neither `Elia.Checkpoint` nor
`Elia.Harness.verify/2` exists any more: retiring SUBTASK-14 and SUBTASK-22
removed their last callers (see `specs/checkpoints.md`).)

## Tests

- `test/elia/tasks_test.exs` (the skill's tools and their errors, spawning and
  its commit, the child's settings and limits, the events, the child's end, the
  result, the registry, stopping a child and the watcher, `list_tasks` and
  `await_task`, the metadata — SUBTASK-1 to SUBTASK-13, SUBTASK-15 to
  SUBTASK-21, SUBTASK-24, SUBTASK-26 to SUBTASK-31).
- `test/elia/tasks_concurrency_test.exs` (two children at once, each in its own
  worktree — SUBTASK-2, SUBTASK-5, SUBTASK-7, SUBTASK-11, SUBTASK-16,
  SUBTASK-17, SUBTASK-21, SUBTASK-23, SUBTASK-26, SUBTASK-27, SUBTASK-31).
- `test/elia/deployment_test.exs` (the child's own worktree, and the merge the
  harness never makes — SUBTASK-23, SUBTASK-25, SUBTASK-28).
- `test/elia/store_test.exs` (the metadata a saved task chat keeps, SUBTASK-15).
- `test/elia/agent_test.exs` (a task whose turn a restart cut short, SUBTASK-20).
- `test/elia_web/live/task_ui_test.exs` (the card, the statuses and the child's
  events — SUBTASK-7, UI-43 to UI-48, UI-50, UI-57, UI-58).
