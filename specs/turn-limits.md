# Turn limits

Status: Draft

A turn can run long: many steps, and — with a slow provider, or a shell command
that hangs — a lot of wall-clock time. The loop has known both limits since
LOOP-3, LOOP-16, LOOP-19 and LOOP-20, but nothing in the UI ever set them: only
a sub-task got a budget, and it got it from `spawn_task` (SUBTASK-12,
SUBTASK-18). A chat can now set its own step limit and time budget, and whether
reaching one pauses the turn for the user's decision (UI-57) instead of failing
it, from its settings page (CSET-5). The defaults are the loop's — a step limit
of 100, no time budget — and a chat that sets nothing pauses when it reaches
that step limit rather than ending with an error (LIMIT-9); the pause is written
into the transcript (LIMIT-10), so a turn that stopped for the user says so
however much later the chat is opened.

## Requirements

- **LIMIT-1** A chat has three limits, each empty by default:
  - `max_steps`, a positive integer: the turn's step limit (LOOP-16, LOOP-3,
    whose default is 100);
  - `max_minutes`, a positive number of minutes: the turn's wall-clock budget
    (LOOP-20, no budget by default);
  - `pause_on_limit`, a boolean: whether reaching either one pauses the turn
    for the user (LOOP-19, SESS-27) rather than ending it with an error
    (LOOP-3), on by default (LIMIT-9).
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
  three settings — the two numbers in the page's single form
  (`#limit-steps`, `#limit-minutes`, CSET-7) and `pause_on_limit` as a switch
  (`#limit-pause`, CSET-7) — marks a value that isn't the chat's own as the
  default it falls back to (LIMIT-1), says that pausing is the default, so the
  switch reads as on for a chat that never touched it (LIMIT-9), says what
  reaching a limit does with it on and off (LIMIT-4, LOOP-3), and sets them
  (CSET-4).
- **LIMIT-7** A value that isn't a positive number, a step limit above 1,000, or
  a time budget above 1,440 minutes is rejected and leaves the chat's limits as
  they were.
- ~~**LIMIT-8** A chat with no limits is unchanged (LOOP-3): a runaway turn
  still ends with an error after 100 steps, and a turn that ends at a limit the
  user failed, or with no `pause_on_limit`, stores nothing.~~ Superseded by
  LIMIT-9 and LIMIT-11: a chat with no limits pauses at the step limit (LIMIT-9)
  and the transcript keeps that (LIMIT-10), while a turn that *ends* at a limit
  still stores nothing of its own (LIMIT-11).

- **LIMIT-9** `pause_on_limit` is on by default: a chat that sets no limits of
  its own **pauses** when its turn reaches a limit — the loop's 100 steps
  (LOOP-16), or the step limit or time budget the chat does set (LIMIT-1,
  LOOP-20) — instead of ending with an error (LOOP-3), where it used to end: the
  status becomes `:paused` (SESS-4), the chat shows the pause banner (UI-57) and
  the chat list shows it paused (UI-58), and the user continues the turn —
  starting the count over — or fails it (LIMIT-4). It is still the chat's own
  switch (LIMIT-1, LIMIT-6, CSET-5, `#limit-pause`), stored like the others
  (LIMIT-2, STORE-27, STORE-28): on is the default, so only a chat that turns it
  *off* writes an entry, and such a chat keeps LOOP-3's ending.

- **LIMIT-10** A turn that reaches a limit says so in the transcript, whether or
  not anyone was looking when it did: when the loop pauses (LOOP-19), the
  session appends a harness message (UI-9) that names the limit and what the
  decision does — "Step limit reached (100 steps). The turn is paused: Continue
  starts the count over, Fail ends it." (and the time budget's own wording,
  LOOP-20) — marked as the pause it is (`meta.limit`, SESS-37),
  saved with the chat (STORE-1, STORE-2) so the transcript keeps it however long
  afterwards the chat is opened, and rendered as an error row (UI-81, UI-12)
  rather than as a plain harness notice (UI-9), so a turn waiting on the user
  never reads as if it had finished. It is written once per pause: a resumed
  turn that reaches the limit again writes another.

- **LIMIT-11** A turn that *ends* at a limit is unchanged (LOOP-3): the user
  failed a paused turn (SESS-27, LOOP-19), or the chat turned `pause_on_limit`
  off (LIMIT-9), so the turn stops and the session reports the limit's error as
  an error row (UI-12) that is not written into the transcript, and the turn's
  end adds nothing to the chat beyond the messages it already has. What the
  transcript keeps is the pause's own message (LIMIT-10), which is what says why
  the turn stopped.

## Implementation

`Elia.Limits` (the defaults, LIMIT-9), `Elia.Agent` (`set_limits/2`),
`Elia.Agent.Session` (the limits, the event, the pause's message, the save, the
turn's options), `Elia.Store` (`save/3`'s `limits:`, `load_limits/1`),
`Elia.Tasks` (a spawn sets the child's limits), `EliaWeb.ChatSettingsLive` (the
Limits section), `EliaWeb.ChatLive` (the pause's row, UI-81).

## Tests

`test/elia/agent_test.exs` (the limits in a turn: a step limit and a budget
pausing a turn, the defaults — a chat with no limits pauses at 100 steps
(LIMIT-9) — the pause's message and what the transcript keeps of it (LIMIT-10),
the ending (LIMIT-11), persistence across a restart, LIMIT-1 to LIMIT-4, LIMIT-9
to LIMIT-11), `test/elia/store_test.exs` (STORE-27, STORE-28),
`test/elia/tasks_test.exs` (a child's limits come from its spawn, LIMIT-5),
`test/elia_web/live/chat_settings_test.exs` (the Limits section, LIMIT-6,
LIMIT-7), `test/elia_web/live/chat_live_test.exs` (the pause's row, UI-81).
