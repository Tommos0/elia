# Sub-tasks

Status: Draft

The feature is built (phases 1 to 3 of `specs/plans/subagents.md`); this draft
replaces the model it was built with. A sub-task is an ordinary chat that ends
when its own chat is marked done (SUBTASK-33), so the task's own status
vocabulary (`running`, `done`, `blocked`, `failed`, `unfinished`, `cancelled`),
the per-task watcher process and the child-only `finish_task` go. Not built
yet.

A chat (the **parent**) hands a focused piece of work to a **child** chat with a
fresh context and its own session, and waits for it to finish. The child is an
ordinary saved chat (SUBTASK-5) with task metadata linking it to its parent
(STORE-16): it is listed in the chat list (UI-45), opens at `/c/<id>` like any
chat (UI-48), is continued and marked done like any chat, and its status is
derived the one way every chat's status is (UI-59, UI-72). Nothing about it
carries a status of its own.

What ends a sub-task is the chat's own done flag (SUBTASK-33): the child marks
itself done with `mark_done` as its last act, or the user does it for it
(DONE-4). Nothing else ends one — not the end of a turn, not a turn the user
stops, not a limit the user fails, not a session that dies (SUBTASK-16,
SUBTASK-24, SUBTASK-34) — which is what the stopped-turn rule used to say for
one case and now says for all of them. The parent gets a short result when it
ends (SUBTASK-9, SUBTASK-27).

A child works where its parent does (SUBTASK-23), and `Elia.Tasks` is the
registry that keeps a tree to one writer: it holds an entry for every child
whose chat isn't done yet (SUBTASK-11), which is also what a parent's
`await_task` waits on (SUBTASK-27). That registry lives in memory, so a restart
empties it and a resumed child takes its entry again (RESUME-7).

The feature was built in phases 1 to 3 of `specs/plans/subagents.md`. Phase 4
(concurrent children, each in its own worktree) is not built.

## Requirements

- **SUBTASK-1** The built-in skill `tasks` (a `spawn_task` call needs approval,
  APPR-5) gives a chat three tools: `spawn_task` (parent), `list_tasks` and
  `await_task` (SUBTASK-26, SUBTASK-27). A child gets neither them nor any
  skill of its own: its session is built from the skill registry minus the
  `tasks` skill (LOOP-17), so a child has exactly the tools an ordinary chat
  has, `mark_done` (DONE-6) among them. There is no child-only tool.

- **SUBTASK-2** `spawn_task` takes a `title` (a short name for the chat list)
  and a `brief` (the whole of the child's input), and optionally a `model` and
  a `max_minutes` (SUBTASK-18). It starts the child (SUBTASK-5) and returns as
  soon as it has started, as JSON: `{"task_id", "title", "status"}`, where
  `status` is the child chat's own status (UI-59) — `working`, since its first
  turn has just started. Waiting for the child is `await_task` (SUBTASK-27).

- ~~**SUBTASK-3** The child-only tool `finish_task(status, summary,
  questions?)` records the result: `status` is `"done"`, `"blocked"` or
  `"failed"`, `summary` is what the child did, `questions` is a list of
  anything it needs the user to settle, and `commit` and `files` are filled in
  by the harness, not the model (SUBTASK-9). It needs no approval. Its result
  is saved as the task's (SUBTASK-13) and is what `await_task` returns.~~
  Retired: a child ends by marking its chat done (SUBTASK-33) and says what it
  did in its last message (SUBTASK-9), so there is no separate tool, no
  `status` and no `questions` — a child's questions go to the user in that
  message and the parent's card links to the chat they are in.

- **SUBTASK-4** A child that would share a workspace with another running child
  is not started: `spawn_task` is refused while a child is running in that
  workspace root (SUBTASK-11), with a message naming the child that holds it.
  In Elia's own project a child gets a worktree of its own (SUBTASK-23), so
  concurrent children there are never refused. The refusal is the tool's error
  result, and the spawn writes nothing: no chat is created.

- **SUBTASK-5** Starting a child records the start commit (`git rev-parse
  HEAD`, SUBTASK-9) and creates the child chat with task metadata (STORE-16),
  then starts its session with the parent's loop options (its model unless
  `model` overrides it, MODEL-2; its auto-approved tools, APPR-8, APPR-12; its
  jail, ISOL-2; its `max_steps`, LOOP-16, SUBTASK-12) and with `spawn_task`'s
  own `max_minutes` (SUBTASK-18), and sends the brief as the child's first user
  message, wrapped in a preamble that tells it: it is a sub-task agent; work
  only from this brief and don't ask for more; commit your work on your own
  branch; finish by saying what you did in your last message — anything you
  need the user to settle goes there — and then calling `mark_done`
  (SUBTASK-33, DONE-6). The child's tools are SUBTASK-1's, and it cannot start
  sub-tasks of its own. The spawn returns at once (SUBTASK-2) and does not wait
  for anything the child does.

- **SUBTASK-6** The child's session starts with the parent's auto-approved
  tools (APPR-8) and no approval inheritance beyond that, and with the model
  the spawn named or the parent's (MODEL-2). A `spawn_task` call with an
  unknown model is refused before anything is created, with the provider's
  error.

- ~~**SUBTASK-7** A `{:subtask, call_id, child_id, status}` event is
  broadcast on the parent's topic when a child starts and when its task's
  status changes (SUBTASK-7), so the parent's page can link the tool call to
  the child chat and show its status (UI-44).~~ Retired: a child's status is
  its chat's own and reaches every view through SESS-19, the done flag through
  SESS-35, so a per-task event would be a second source for the same thing. The
  link to the child is saved metadata (SUBTASK-15, STORE-18).

- ~~**SUBTASK-8** The child's turn is the unit of the task: when its session
  goes idle (or dies), the task ends — the result is built and saved
  (SUBTASK-9, SUBTASK-13), the workspace lock released (SUBTASK-11) and the
  parent's waiting `spawn_task` returns.~~ Retired: a turn's end is no longer
  the task's end. Only the child's chat being marked done ends it (SUBTASK-33),
  so a turn that ends, is stopped or dies leaves the task running (SUBTASK-16,
  SUBTASK-34).

- **SUBTASK-9** The result of a sub-task is JSON: `{"task_id", "summary",
  "commit", "files"}`. `task_id` is the child chat's id; `summary` is the
  child's last assistant message before it marked the chat done — its report of
  what it did — or a placeholder saying the task ended without one; `commit` is
  the child's new HEAD sha against the commit its spawn recorded, or `null` when
  it didn't change; `files` is the paths it changed since then, untracked ones
  included and sorted. The harness derives `commit` and `files`, never the
  model, and derives the whole result when the child's chat is marked done
  (SUBTASK-33), which is what `list_tasks` and `await_task` report
  (SUBTASK-26, SUBTASK-27).

- ~~**SUBTASK-10** A child whose turn ends without reporting a result is
  `"unfinished"`, with its last assistant text as the summary, and the
  parent's `spawn_task` returns that.~~ Retired: a child that ends a turn
  without marking its chat done hasn't finished (SUBTASK-33), so there is
  nothing to report: the parent keeps waiting (SUBTASK-27) and the user settles
  it in the child's chat (SUBTASK-34).

- **SUBTASK-11** `Elia.Tasks` is the registry of children that haven't
  finished: an entry per child whose chat isn't marked done (SUBTASK-33), with
  its parent, its workspace root and its start commit, held for as long as the
  task runs. An entry is taken when the child is started (SUBTASK-5), and
  released when its chat is marked done (SUBTASK-13) or when its chat is
  deleted (SUBTASK-35); `active/0` reports the entries and `running?/1` says
  whether one child's is held, without calling any session. A child that stops
  its turn or is stopped keeps its entry (SUBTASK-16), and a chat that isn't a
  running child holds none: the entry is the whole of what "still running"
  means, and a restart empties it (SUBTASK-20, RESUME-7).

- **SUBTASK-12** `spawn_task` takes `max_steps` (a step limit for the child,
  LOOP-16) and defaults it to 50, capped at the loop's own cap. It is the
  child's limit, not the parent's: a later change in either chat never affects
  the other.

- **SUBTASK-13** When the child's chat is marked done, the harness builds the
  result (SUBTASK-9), saves it in the child's task metadata with the chat
  (STORE-16, SESS-18, SESS-20) and releases the entry (SUBTASK-11). A result is
  saved once: a chat that is marked done again, or reopened and marked done
  again (DONE-9), keeps the result it has.

- ~~**SUBTASK-14** A child can also be stopped by the user from its own chat:
  stopping the turn ends the task with `status: "cancelled"`.~~ Removed: a stop
  is not an end (SUBTASK-16, SUBTASK-33); the status `cancelled` went with the
  task vocabulary, and `UI-50` (its icon) was retired with it.

- **SUBTASK-15** The parent's `spawn_task` call and the child chat are linked
  in both directions: the child's task metadata holds the parent's id and the
  id of the tool call that spawned it (`parent_call_id`, STORE-18), and the
  parent's page reads `Elia.Store.children/1` (STORE-18) to find the child of
  each of its `spawn_task` calls, so a chat opened later still shows the card
  and its link (UI-44).

- **SUBTASK-16** Stopping a running child's turn (SESS-8, SESS-22) ends that
  turn and nothing more. The turn ends as any chat's stop does — its open tool
  calls get error results, the transcript says the user stopped it (STOP-1) and
  the status goes `idle` (SESS-4, UI-59) — and the sub-task doesn't end: it
  stays a running child (SUBTASK-11), the user can send it another turn, and a
  parent's wait goes on (SUBTASK-27). The child's chat is left idle, not done,
  and that is the state the parent's card shows (UI-44). *Changed:* this used to
  be the exception to "the child's turn end is the child's end" (the retired
  SUBTASK-8); now no turn's end is (SUBTASK-33).

- **SUBTASK-17** Stopping the parent's turn (SESS-8) first stops the turn of
  every child of that chat that is still running (SUBTASK-11), and stops their
  turns the same way (SUBTASK-16). Each child goes on as a sub-task after that,
  holding its entry, and a parent's later `await_task` waits for it again
  (SUBTASK-27). The `await_task` call in the stopped turn is closed as any
  running tool call is — its process is killed, so the parent's resumed turn
  gets an error result for it (SESS-21) and asks again if it wants to wait.

- **SUBTASK-18** A child's time budget is `spawn_task`'s `max_minutes`
  (default 30, at most 120, from the `:task_minutes` setting), and it is the
  child's limit like `max_steps` (LIMIT-2, LIMIT-5). Time spent waiting for the
  user doesn't count against it, so a child paused at a limit or waiting for an
  approval isn't failed by the clock (SUBTASK-24).

- ~~**SUBTASK-19** The process watching a child (SUBTASK-28) can die — a crash,
  a kill — and the job is finished in another process, keeping the entry, so
  the server never blocks and never calls a session itself.~~ Retired: there is
  no watcher process to die (SUBTASK-28). The end of a task happens in the
  child's own session, when its chat is marked done (SUBTASK-33), and nothing
  has to be finished on a process's death.

- **SUBTASK-20** After an app restart, a sub-task chat whose chat isn't marked
  done is still a sub-task, and its interruption is the one every chat's is: a
  saved `turn` with no session for it is `interrupted` (STORE-31, UI-72), and
  it is resumed like any chat (RESUME-7), which is what takes its entry again
  (SUBTASK-11) before its turn runs. The parent's own `await_task` call was
  killed with the turn: the parent's next turn gets an error result for it, as
  for any tool call the restart cut off (SESS-21), and a later `await_task`
  waits for the child's chat to be marked done (SUBTASK-27).

- ~~**SUBTASK-21** The result also carries `task_id` (the child chat's id), and
  a result that isn't `"done"` carries `start_commit` and `tree_clean`, so a
  parent knows whether a failed child's work can be rolled back.~~ Retired:
  `task_id` is part of the result (SUBTASK-9), and the rest went with the
  status vocabulary: a task ends when its chat is marked done (SUBTASK-33), so
  there is no failed outcome to describe, and whether a child's work can be
  rolled back is a question about its branch, which the parent can look at
  itself.

- ~~**SUBTASK-22** `reset_task(task_id)` (a `spawn_task`-style call, approval
  required, parent only) resets a child's workspace to its start commit
  (`git reset --hard` plus `git clean`) so a failed child's work can be
  discarded.~~ Removed: the work is discarded by not merging the child's branch
  (SUBTASK-23) and by deleting its chat (SUBTASK-35); a tool that rewrites a
  tree in place is a second way to do it, and a dangerous one.

- **SUBTASK-23** A child's workspace is its parent's (PROJ-12) unless the
  parent is in Elia's own project, where the child gets a git worktree of its
  own, on branch `chat/<child id>` forked from the parent's branch's last
  commit (DEPLOY-1), so the child never writes its parent's tree. Its committed
  work stays on that branch and is not merged for it: the parent merges
  (`git merge --ff-only chat/<child id>`) when it wants the work.

- **SUBTASK-24** A child's limits are the ones its spawn set (SUBTASK-12,
  SUBTASK-18, LIMIT-5) with `pause_on_limit` on, so reaching one pauses its
  turn: the session's status becomes `:paused`, the chat shows the pause banner
  (UI-57, LIMIT-4) and the parent's wait goes on (SUBTASK-27) with no deadline
  of its own. The user decides in the child's chat: **Continue** resumes the
  turn (LIMIT-4, LIMIT-9), and **Fail** ends that turn with the limit's error
  (LIMIT-4) — after which the sub-task goes on, since its chat isn't marked
  done (SUBTASK-33), so the parent keeps waiting and the user either gives the
  child another turn or marks its chat done when they want it over (SUBTASK-34).
  Stopping the paused turn is the same as stopping any turn (SUBTASK-16). A
  restart takes the paused turn with it and a paused child is not resumed
  (RESUME-8). *Changed:* failing a paused child used to end its task as
  `"failed"` with the reason `budget`; now only marking the chat done ends a
  task (SUBTASK-33).

- **SUBTASK-25** A child's session is started even when the app has restarted
  since the spawn (SUBTASK-20) and is started for the user's benefit too: the
  child chat is inspectable and resumable like any chat (SUBTASK-23, DONE-9).

- **SUBTASK-26** `list_tasks` reports this chat's sub-tasks, newest first, as
  JSON: `{"task_id", "title", "status", "started_at"}` per child, where
  `status` is the child chat's own status (UI-59, UI-72) — `working` while a
  turn of it runs, `awaiting_approval` or `awaiting_input` while it needs the
  user, `paused` at a limit, `interrupted` after a restart, `done` once its
  chat is marked done, `idle` otherwise — so a parent sees what it would see in
  the chat list (UI-45, UI-46). With `task_id` it reports that one child and
  adds its `result` once its chat is marked done (SUBTASK-9, SUBTASK-13); a
  `task_id` that isn't a sub-task of this chat is a tool error. `list_tasks`
  doesn't wait for anything: it is how a parent checks on children without
  blocking.

- **SUBTASK-27** `await_task` takes a `task_id` and waits until that child's
  chat is marked done (SUBTASK-33), then returns its result (SUBTASK-9) as
  JSON. A task whose chat is already marked done returns at once, from its
  saved metadata (STORE-16), so a parent can collect a result it has already
  been told about. The wait survives everything that isn't the end: a turn that
  ends (SUBTASK-10), a turn the user stops (SUBTASK-16), a pause at a limit
  (SUBTASK-24) and a session that dies all leave it waiting. It answers with a
  tool error when `task_id` isn't a sub-task of this chat, when the child's
  chat is deleted while it waits (SUBTASK-35), and when the wait itself is cut
  short — the parent's turn is stopped (SUBTASK-17) or the app restarts
  (SUBTASK-20). One `await_task` per child lets a parent wait for several in
  the order that suits, or carry on and check with `list_tasks`.

- ~~**SUBTASK-28** A watcher process (a task in the task supervisor, LOOP-10)
  owns the wait for a child's turn to end (SUBTASK-8), so `spawn_task` returns
  at once; the caller is monitored, so the entry is released when it dies, and
  the watcher records the result (SUBTASK-9, SUBTASK-13).~~ Retired: nothing
  owns a wait any more. The end of a task is the child's chat being marked done
  (SUBTASK-33), which happens in the child's own session, and a parent's wait is
  its own `await_task` call, whose process dying is that call ending
  (SUBTASK-27).

- ~~**SUBTASK-29** When a child's session is gone, its final metadata is still
  saved, written straight to disk rather than through a session, so a chat
  deleted by the user is never recreated.~~ Retired: a result is saved by the
  child's own session, when its chat is marked done (SUBTASK-13), so nothing
  writes a child's file after its session is gone and a deleted chat stays
  deleted (SUBTASK-35).

- **SUBTASK-30** A child's workspace is the one its spawn resolved
  (SUBTASK-23), and the jail setting it runs with is the parent's at the time
  of the spawn (ISOL-2, ISOL-9): a child in a worktree of Elia's own project is
  jailed like its parent, and one sharing its parent's workspace has the
  parent's jail setting, on or off. The child's own jail setting is its own
  from then on (ISOL-18).

- **SUBTASK-31** From everywhere but the child's own chat, a sub-task whose
  turn the user stopped is an ordinary running child: `list_tasks` reports its
  chat's status (SUBTASK-26), `await_task` goes on waiting (SUBTASK-27) and the
  parent's card is the card it was (UI-44). It ends the ordinary ways — its
  chat is marked done (SUBTASK-33) or its chat is deleted (SUBTASK-35) — and a
  turn the user starts in it after the stop goes on being part of it
  (SUBTASK-16). *Changed:* this used to be a special case (a stopped turn is not
  the child's end); it is now what any turn's end is (SUBTASK-10).

- ~~**SUBTASK-32** Saving a child's final metadata straight to disk (SUBTASK-29)
  preserves every other key the file has, so a concurrent save by the child's
  session can't be clobbered and no field is lost.~~ Retired: there is no
  out-of-session save (SUBTASK-29), so there is nothing to preserve.

- **SUBTASK-33** A sub-task ends when — and only when — its chat is marked done
  (DONE-1, DONE-6, SESS-35): the child marks itself done with `mark_done` as its
  last act, or the user marks it done (DONE-4, UI-79). That single event is the
  end: the harness builds and saves the result (SUBTASK-9, SUBTASK-13), the
  entry is released (SUBTASK-11) and a waiting `await_task` returns it
  (SUBTASK-27). Nothing else ends a task — not the end of a turn (SUBTASK-10),
  not a turn the user stops (SUBTASK-16), not a limit they fail (SUBTASK-24),
  not a session that dies (SUBTASK-19). The end is recorded once and doesn't
  move: reopening the chat (DONE-9) doesn't un-end the task, which keeps the
  result it has (SUBTASK-13).

- **SUBTASK-34** A sub-task whose chat nobody has marked done keeps running,
  however its turns end: its chat is left where it is — `idle`, `awaiting_*`,
  `paused` or `interrupted` (UI-59, UI-72) — and the user settles it in that
  chat, by marking it done (DONE-4), by giving it another turn, or by deleting
  it (SUBTASK-35). Nothing has to happen for the task to be over, and no
  deadline of the harness's own ends it: a parent that waits for such a child
  waits until the user settles it (SUBTASK-27), and its entry is held until
  then (SUBTASK-11), so the workspace it works in stays its own (SUBTASK-4).

- **SUBTASK-35** Deleting a running sub-task's chat (SESS-29, UI-65) ends it
  without a result: the entry is released (SUBTASK-11) and a parent's
  `await_task` on it answers with a tool error saying the chat is gone, rather
  than waiting for a chat that no longer exists (SUBTASK-27). The chat stays
  deleted: nothing recreates it (SUBTASK-13, SUBTASK-29).

- **SUBTASK-36** A child whose brief was never sent — its spawner died before
  it got there — is not a running child: its entry is released (SUBTASK-11) and
  no per-task event is sent for it (the retired SUBTASK-7). Its chat is left saved and unmarked,
  with the metadata of a child (STORE-16), so the user can open it, use it or
  delete it like any chat; a later `await_task` on it waits as for any child
  whose chat isn't marked done (SUBTASK-27, SUBTASK-34).

## Out of scope

- Sub-tasks of sub-tasks: a child has no `spawn_task` (SUBTASK-1), so depth is
  one.
- Read-only children running beside a writer in the same tree: children sharing
  a workspace are serialized (SUBTASK-4).
- Carrying a parent's context into a child: the brief is the whole of it
  (SUBTASK-5).
- A limit the harness imposes on how long a sub-task may run: only the child's
  own limits pause it (SUBTASK-24) and the user ends it (SUBTASK-34).
- A per-task status of its own, on the child's row or anywhere else: a
  sub-task's status is its chat's (UI-46, UI-59).

## Stored data

A child's task metadata (STORE-16) loses its `status` key: a chat's status is
derived from the chat itself (UI-59, STORE-31), so nothing persists one, and
`result` is written once, when the chat is marked done (SUBTASK-13). This is
backward compatible and needs no migration: a chat saved with a `status` — any
child saved by an earlier version — is read for its `parent_id`, `title`,
`brief`, `started_at`, `start_commit` and `result`, and the `status` is ignored,
so a child saved as `"running"` is a running child if its chat isn't done and
one saved as `"failed"` or `"cancelled"` is simply a child whose chat isn't
marked done (SUBTASK-34). `interrupted` is unchanged and comes from the chat's
own saved turn (STORE-31), as it does for every chat. The result keeps `task_id`
and loses `status`, `reason`, `questions`, `start_commit` and `tree_clean`
(SUBTASK-9, SUBTASK-21): a saved result with those keys is read for the four it
has, and a saved `summary` that a child wrote is still its summary.

## Implementation

`Elia.Skills.Tasks` (`spawn_task`, `list_tasks`, `await_task`), `Elia.Tasks`
(the registry: entries, the workspace lock, `active/0`, `running?/1`),
`Elia.Agent` (the spawn and the child's session, `set_done/2` as the end of a
task, SUBTASK-33), `Elia.Agent.Session` (the done flag and the result it saves,
SESS-35, SESS-18), `Elia.Store` (the task metadata, STORE-16),
`Elia.Agent.Resumer` (the entry a resumed child takes again, RESUME-7),
`EliaWeb.ChatStatus` and `EliaWeb.ChatLive` (a child's status is its chat's,
UI-46) and `AGENTS.md` (the `tasks` skill's section: how a sub-task ends and
what it reports).

## Tests

- `test/elia/tasks_test.exs` (spawning and its refusals, the brief, the child's
  skills and tools, the workspace and its lock, the entry's life — taken at the
  spawn, held through a stopped turn and a pause, released when the chat is
  marked done — the end and the result it saves, `list_tasks` and `await_task`
  and what they report while a child is only idle, a child's limits from its
  spawn, a child deleted while a parent waits, and a child whose brief never
  went out — SUBTASK-1 to SUBTASK-6, SUBTASK-9, SUBTASK-11 to SUBTASK-13,
  SUBTASK-15 to SUBTASK-18, SUBTASK-20, SUBTASK-23 to SUBTASK-27, SUBTASK-30,
  SUBTASK-31, SUBTASK-33 to SUBTASK-36).
- `test/elia/store_test.exs` (the task metadata saved and loaded, and a file
  written with a `status` key read without it — STORE-16, STORE-17).
- `test/elia/agent_test.exs` (stopping a parent's turn and its children's,
  SESS-22; the done flag's event, SESS-35).
- `test/elia_web/live/task_ui_test.exs` (the card, the child's own status on it,
  the nested rows, the child's header — UI-43 to UI-49).
- `test/elia/auto_resume_test.exs` (a resumed child's entry, RESUME-7).
- No test: SUBTASK-7, SUBTASK-8, SUBTASK-10, SUBTASK-14 — retired: a turn's end
  is no longer a task's end and a stop is not one either, so nothing asserts
  them; what replaced them is tested where SUBTASK-33 and SUBTASK-34 are.
- No test: SUBTASK-19, SUBTASK-21, SUBTASK-22 — retired: there is no watcher
  process to die, no failed outcome to describe and no rollback tool, so
  nothing asserts them.
- No test: SUBTASK-28, SUBTASK-29, SUBTASK-32 — retired: nothing owns a wait
  for a child and nothing writes its file out of session, so nothing asserts
  them.
