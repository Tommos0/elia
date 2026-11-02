# Sub-tasks

Status: Implemented (phases 1 to 3 of [the plan](plans/subagents.md): core,
task cards, a nested chat list and a task header in the chat UI, and cancel,
budget, crash recovery and reset)

A chat (the **parent**) can hand a focused piece of work to a **child** chat
with a fresh context, wait for it, and get back a short structured result. The
child is an ordinary saved chat with extra metadata linking it to its parent.
In Elia's own project the child gets its own worktree, so its in-progress work
never touches the parent's (SUBTASK-23). Only one child runs at a time, because
the checkpoints, git index and approvals are still shared.

## Requirements

### Tools

- **SUBTASK-1** The built-in skill `tasks` (`Elia.Skills.Tasks`, listed in the
  `builtin` config) provides `spawn_task`. A child session doesn't get it: its
  skills are the registry's skills without `tasks`, plus the skill `task`,
  which provides `finish_task`. A parent therefore has `spawn_task` and not
  `finish_task`, and a child the reverse. The child's skills are read again
  every step (LOOP-17).
- **SUBTASK-2** `spawn_task` takes `title` and `brief` (both required, not
  blank), and optionally `model` (a model id, used on the parent's provider;
  default: the parent's own selection). It needs the user's approval (APPR-1)
  and blocks until the child's turn ends. Its output is the result (SUBTASK-9)
  as JSON. The child's step limit is not part of the tool's schema, so the
  model doesn't choose it (SUBTASK-12).
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
  - a child is already active (SUBTASK-11);
  - the git working tree isn't clean (`git status --porcelain` lists
    anything), so a failed child can be rolled back to a known point;
  - `.elia/` isn't git-ignored, since chat files would make the tree dirty;
  - the parent's turn changed core Elixir files since its checkpoint (as in
    VERIFY-3) and the full test suite fails. The test output is returned. This
    keeps SUBTASK-14 sound: changes made before the spawn are verified.
- **SUBTASK-5** Otherwise `spawn_task` records the start commit (`HEAD`),
  creates a chat with a new id and saved task metadata (`parent_id`, `title`,
  `brief`, `started_at`, `status: "running"`, `start_commit`; STORE-16), starts
  its session with the parent's loop options (so the same model request fields
  and `verify` setting) except `skills` and `max_steps`, and sends it the
  brief as its first user message. The message starts with a short preamble: it
  is a sub-task agent, works only from this brief, commits its work, ends by
  calling `finish_task`, does not wait for the user, and lists unresolved
  questions in the result.
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

- **SUBTASK-8** The child's turn has ended when its session goes idle. If the
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
- **SUBTASK-11** The lock `Elia.Tasks` (a `GenServer`, started on first use)
  holds the one active child and its parent for the whole app. It is taken at
  spawn, released when the child ends, and also released when either session
  dies. `Elia.Tasks.active/0` returns `nil` or `%{child_id, parent_id}`.
- **SUBTASK-12** The child's loop step limit is a loop option (LOOP-16),
  defaulting to the loop's own default (LOOP-3). It isn't in `spawn_task`'s
  schema, so the model doesn't choose it; a caller may still pass `max_steps`
  (default 100, at most 100) to override it, which tests use to reach the limit
  quickly. Reaching it pauses the child's turn (SUBTASK-24).
- **SUBTASK-13** When the child ends, its saved metadata gets the final
  `status` and the `result` (STORE-16, SESS-18), the lock is released, and the
  final `{:subtask, …}` event is broadcast.

### Interaction with checkpoints and verification

- **SUBTASK-14** When the child ends, the parent's turn checkpoint, if the
  parent's turn has one, is replaced by a new snapshot of the workspace as it
  is then (CKPT-10). If the parent's turn later fails verification, it rolls
  back to that snapshot, so it can never wipe the child's work, and
  the parent's own earlier changes were verified before the spawn
  (SUBTASK-4). A parent with no checkpoint yet takes one at its first change
  after the child, as usual. This matters when the sub-task shares the parent's
  workspace and commits there (SUBTASK-23); one in its own worktree leaves the
  parent's tree unchanged, so the new snapshot is the same.

### UI support (phase 2)

- **SUBTASK-15** The saved task metadata also records `parent_call_id`, the id
  of the parent's `spawn_task` call (STORE-18), so the parent's page can show
  the child's card and link after a reload. The UI itself is specified in
  `chat-ui.md` (UI-43 to UI-49).

### Control and robustness (phase 3)

- **SUBTASK-16** Stopping the active child's turn (SESS-8) ends the child with
  status `"cancelled"` and reason `"cancelled"` (SUBTASK-21), whatever
  `finish_task` said. The summary says the user stopped it. `spawn_task` returns
  that result to the parent as an ordinary tool result (not an error), the lock
  is released and the saved task metadata gets the status (SUBTASK-13).
- **SUBTASK-17** Stopping the parent's turn (SESS-8) while it waits for a child
  first stops that child's turn, so the child is also `"cancelled"`. The parent's
  `spawn_task` call gets the usual "Cancelled by the user." result, since the
  process running it is killed. The child's final metadata, the lock release and
  the final `{:subtask, …}` event (SUBTASK-7, SUBTASK-13) are then done by
  `Elia.Tasks` itself (SUBTASK-19), not by that process.
- **SUBTASK-18** Budget: besides `max_steps` (SUBTASK-12), `spawn_task` takes
  `max_minutes`, a positive number of minutes of wall-clock time (default 30,
  at most 120; the application setting `:task_minutes` changes the default). The
  time a child spends with its status `:awaiting_approval` doesn't count. When
  the time is up, the child's turn pauses (SUBTASK-24). A child that hits its
  step limit (SUBTASK-12) pauses the same way.
- **SUBTASK-19** If the process running `spawn_task` dies while it holds the
  lock (it was killed by SUBTASK-17, or crashed), `Elia.Tasks` finishes the job
  itself without blocking the lock: the child's turn is stopped if it is still
  running, the saved status becomes `"cancelled"` (when it was stopped by the
  user, SUBTASK-16/17) or `"failed"` and the result is saved (only if the saved
  status is still `"running"`), the lock is released and the final
  `{:subtask, …}` event is broadcast. The lock server never calls a session
  itself, so it can't deadlock with one.
- **SUBTASK-20** After an app restart, a task saved as `"running"` is shown as
  `"interrupted"` (STORE-17), and a parent whose `spawn_task` call was still
  waiting gets that call closed with an error result when its session starts
  (SESS-21). No lock is held: it lives in memory.
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
  (SUBTASK-25). It is never
  run automatically. It is refused, as a tool error and without changing
  anything, when: the chat isn't a task of the caller; its status is `"done"`;
  a child is active (SUBTASK-11), which includes this one; the task has no
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
  and `spawn_task` keeps waiting, with no deadline of its own. The user decides
  in the child's chat: Continue (`Elia.Agent.resume/1`) starts the step count
  and the budget over and the child goes on; Fail (`Elia.Agent.fail_task/1`)
  ends the turn with the limit's error, so the result is `"failed"` with reason
  `"budget"` (SUBTASK-9, SUBTASK-21) and a summary naming the limit. Stopping
  the paused turn (SESS-8) instead cancels the child (SUBTASK-16).

## Out of scope (later phases of the plan)

Read-only children (phase 4).

## Implementation

`Elia.Tasks` (lock, spawn, await, merge, cancel, reset), `Elia.Skills.Tasks`
(the skills and tools), `Elia.Store` (metadata), `Elia.Agent.Session` (task
metadata, `selection` option, stop, dangling calls), `Elia.Agent.Loop`
(`max_steps`, skill functions, tool context), `Elia.Checkpoint.rebase/1`,
`Elia.Harness.core_elixir_changed?/1`, `Elia.Deploy` (the child's own worktree,
the merge back into the parent's branch).

Core files touched: `lib/elia/agent/loop.ex`, `lib/elia/skills.ex`,
`lib/elia/skills/tasks.ex`, `lib/elia/checkpoint.ex`, `lib/elia/harness.ex`,
`lib/elia/deploy.ex`, `config/config.exs`. (The per-sub-task worktree
(SUBTASK-23, SUBTASK-25) adds `lib/elia/deploy.ex` and `lib/elia/tasks.ex`.)

## Tests

`test/elia/tasks_test.exs`, `test/elia/store_test.exs`,
`test/elia/agent_test.exs`, `test/elia_web/live/task_ui_test.exs`.
