# Sub-tasks

Status: Implemented (phase 1 of [the plan](plans/subagents.md): core only, no
dedicated UI)

A chat (the **parent**) can hand a focused piece of work to a **child** chat
with a fresh context, wait for it, and get back a short structured result. The
child is an ordinary saved chat with extra metadata linking it to its parent.
Only one child runs at a time, because the workspace, checkpoints, git index
and approvals are global.

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
  default: the parent's own selection) and `max_steps` (default 50, at most
  100). It needs the user's approval (APPR-1) and blocks until the child's turn
  ends. Its output is the result (SUBTASK-9) as JSON.
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
- **SUBTASK-6** The child chat starts with no auto-approved tools; the
  parent's auto-approval isn't inherited (APPR-8). With `model`, the child's
  selection is that model on the parent's provider; without it, the child
  starts with the parent's selection. Neither changes the stored default model
  (MODEL-15).
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
  turn ended with an error (including the step limit, SUBTASK-12), the status
  is `"failed"` and the summary is the error text, whatever `finish_task`
  said, since the work did not end the way the child claimed.
- **SUBTASK-11** The lock `Elia.Tasks` (a `GenServer`, started on first use)
  holds the one active child and its parent for the whole app. It is taken at
  spawn, released when the child ends, and also released when either session
  dies. `Elia.Tasks.active/0` returns `nil` or `%{child_id, parent_id}`.
- **SUBTASK-12** `max_steps` is the child's loop step limit (LOOP-16).
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
  after the child, as usual.

## Out of scope (later phases of the plan)

Task cards and a nested chat list (phase 2); cancel, wall-clock budget, restart
recovery and rollback on failure (phase 3); read-only children (phase 4).

## Implementation

`Elia.Tasks` (lock, spawn, await), `Elia.Skills.Tasks` (the skills and tools),
`Elia.Store` (metadata), `Elia.Agent.Session` (task metadata, `selection`
option), `Elia.Agent.Loop` (`max_steps`, skill functions, tool context),
`Elia.Checkpoint.rebase/1`, `Elia.Harness.core_elixir_changed?/1`.

Guarded files touched: `lib/elia/agent/loop.ex`, `lib/elia/skills.ex`,
`lib/elia/skills/tasks.ex`, `lib/elia/checkpoint.ex`, `lib/elia/harness.ex`,
`config/config.exs`. None of the guardrails is weakened.

## Tests

`test/elia/tasks_test.exs`, `test/elia/store_test.exs`,
`test/elia/agent_test.exs`.
