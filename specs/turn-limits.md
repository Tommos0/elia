# Turn limits

Status: Draft

A turn can run long: many steps, and — with a slow provider, or a shell command
that hangs — a lot of wall-clock time. The loop has known both limits since
LOOP-3, LOOP-16, LOOP-19 and LOOP-20, but nothing in the UI ever set them: only
a sub-task got a budget, and it got it from `spawn_task` (SUBTASK-12,
SUBTASK-18). A chat can now set its own step limit and time budget, and whether
reaching one pauses the turn for the user's decision (UI-57) instead of failing
it, from its settings page (CSET-5). The defaults are the loop's, so a chat that
sets nothing behaves exactly as it did before.

## Requirements

- **LIMIT-1** A chat has three limits, each empty by default:
  - `max_steps`, a positive integer: the turn's step limit (LOOP-16, LOOP-3,
    whose default is 100);
  - `max_minutes`, a positive number of minutes: the turn's wall-clock budget
    (LOOP-20, no budget by default);
  - `pause_on_limit`, a boolean: whether reaching either one pauses the turn
    for the user (LOOP-19, SESS-27) rather than ending it with an error
    (LOOP-3), off by default.
- **LIMIT-2** The session holds them as `%{max_steps: nil | pos_integer,
  max_minutes: nil | number, pause_on_limit: boolean}`, where `nil` is "no limit
  of this chat's own", like the chat's jail setting (SESS-30):
  `Elia.Agent.set_limits/2` (chat id, a map of changes) sets them for one chat,
  `set_limits/2` is allowed mid-turn, a change is broadcast as
  `{:limits, limits}` (SESS-6) so every view of the chat agrees, and
  `snapshot/1` carries them (SESS-7). They are saved with the chat (STORE-27,
  STORE-28) and loaded on start.
- **LIMIT-3** A turn runs with them: the session passes `max_steps` and
  `budget_ms` (from `max_minutes`) to the loop when they are set, and
  `pause_on_limit` when it is on, without overriding an option the caller passed
  explicitly (LOOP-16, LOOP-19, LOOP-20), which is how tests drive a limit
  directly. A change applies from the next turn; a turn already running keeps
  the limits it started with.
- **LIMIT-4** With `pause_on_limit` on, a turn that reaches a limit pauses: its
  status becomes `:paused` (SESS-4), the chat shows the pause banner (UI-57,
  SESS-27) and the user continues it — starting the step count and the budget
  over (LOOP-19) — or fails it, which ends the turn with the limit's error.
- **LIMIT-5** A sub-task's limits are set at its spawn instead of in its file:
  `spawn_task`'s `max_steps` (SUBTASK-12) and `max_minutes` (SUBTASK-18) become
  the child chat's limits (LIMIT-2), with `pause_on_limit` on (SUBTASK-24), so
  the child's settings page shows the budget it actually runs with and the child
  can be given more of it while it is paused. The child's limits are its own
  from then on, like its jail setting and auto-approvals (ISOL-18, APPR-12): a
  later change in either chat never affects the other, and the parent's own
  limits are not inherited.
- **LIMIT-6** The chat settings page's **Limits** section (CSET-5) shows the
  three settings — the two numbers in a form with a Save button
  (`#limit-steps`, `#limit-minutes`) and `pause_on_limit` as a switch
  (`#limit-pause`, CSET-7) — marks a value that isn't the chat's own as the
  default it falls back to (LIMIT-1), says what reaching a limit does with
  `pause_on_limit` on and off (LIMIT-4, LOOP-3), and sets them (CSET-4).
- **LIMIT-7** A value that isn't a positive number, a step limit above 1,000, or
  a time budget above 1,440 minutes is rejected and leaves the chat's limits as
  they were.
- **LIMIT-8** A chat with no limits is unchanged (LOOP-3): a runaway turn still
  ends with an error after 100 steps, and a turn that ends at a limit the user
  failed, or with no `pause_on_limit`, stores nothing.

## Implementation

`Elia.Agent` (`set_limits/2`), `Elia.Agent.Session` (the limits, the event, the
save, the turn's options), `Elia.Store` (`save/3`'s `limits:`, `load_limits/1`),
`Elia.Tasks` (a spawn sets the child's limits), `EliaWeb.ChatSettingsLive` (the
Limits section).

## Tests

`test/elia/agent_test.exs` (the limits in a turn: a step limit and a budget
pausing a turn, the defaults, persistence across a restart, LIMIT-1 to LIMIT-4),
`test/elia/store_test.exs` (STORE-27, STORE-28), `test/elia/tasks_test.exs` (a
child's limits come from its spawn, LIMIT-5),
`test/elia_web/live/chat_settings_test.exs` (the Limits section, LIMIT-6,
LIMIT-7).
