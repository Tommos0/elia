# Agent sessions

Status: Implemented

Each conversation is a process that owns its message history, runs one turn
at a time in a supervised task, collects the user's approvals, and broadcasts
progress so any number of UIs can follow it.

## Requirements

- **SESS-1** A session is identified by a chat id and is unique per id.
  `Elia.Agent.ensure_started/2` returns the running session or starts one.
- **SESS-2** On start, a session loads its saved history (STORE-3). When it
  restarts, the history is the same as before.
- **SESS-3** Sending a message appends it as a user message and starts a turn
  with a new turn id. Sending while a turn is in progress returns
  `{:error, :busy}` and changes nothing.
- **SESS-4** Session status is one of `:idle`, `:running`,
  `:awaiting_approval`, `:awaiting_input` (SESS-34) or `:paused` (SESS-27).
  Every change is broadcast.
- **SESS-5** Every message the loop produces is appended to the history,
  saved (STORE-1) and broadcast. Messages with empty content are dropped.
- **SESS-6** Events are broadcast on `Elia.Agent.topic(id)` as
  `{:agent, id, event}`, where event is one of `{:message, m}`,
  `{:delta, :text | :reasoning, text}`, `{:notice, text}`, `{:status, s}`,
  `{:tool_status, call_id, s}`, `{:error, text}` (a stop, whose transcript
  message is STOP-1's, SESS-38), `{:reset, messages}`,
  `{:compaction, state}` (the chat's compaction state changed, COMPACT-24),
  `{:model, selection}` (the chat's model selection changed, MODEL-1),
  `{:auto_approve, names}` (the chat's auto-approved tools changed, SESS-16),
  `{:jail, on?}` (the chat's jail setting changed, SESS-30),
  `{:limits, limits}` (the chat's turn limits changed, SESS-31, LIMIT-2),
  `{:effort, effort}` (the chat's reasoning effort changed, SESS-40),
  `{:title, title}` (the chat's own title changed, SESS-33, TITLE-1),
  `{:done, on?}` (the chat's done flag changed, SESS-35, DONE-1, DONE-9),
  `{:paused, message}` (the turn paused at a limit, SESS-27),
  `{:retry, info}` (a failed model call is being retried, SESS-39, RETRY-3),
  `{:subtask, call_id, child_id, status}` (a `spawn_task` call's child started
  or ended, SUBTASK-7; sent by `Elia.Tasks`, not by the session itself),
  `{:task, metadata}` (the chat's task metadata changed, SESS-20).
- **SESS-7** `snapshot/1` returns the id, messages, status, per-call tool
  status, the chat's model selection (`nil` if none yet), its
  auto-approved tool names (sorted list), its jail setting (ISOL-16), its turn
  limits (SESS-31, LIMIT-1), its reasoning effort (`effort`, SESS-40, `nil`
  when the configured default applies), its task
  metadata (`task`, `nil`
  for an ordinary chat), the project it belongs to (`project`, PROJ-9), its
  compaction state (`compaction`, COMPACT-24), its own title (`title`, `nil`
  when it has none, SESS-33, TITLE-1), its done flag (`done`, a boolean,
  false when it isn't done, SESS-35, DONE-1) and its pause message (`pause`,
  `nil` unless the turn is paused, SESS-27), so a UI that connects mid-turn
  can render the current state.
- **SESS-8** Stopping a turn kills its task, gives each unanswered tool call
  in the last assistant message an error result ("Cancelled by the user."),
  returns to idle and writes the stop into the transcript — "Stopped by the
  user.", STOP-1, SESS-38 — in place of the "Stopped." notice it used to
  broadcast. Stopping an idle session does nothing.
- **SESS-9** Messages from a stopped loop that arrive late are ignored.
- **SESS-10** If the loop ends with `:refused`, the history is truncated to
  what it was before the turn's user message, the truncated history is saved
  and broadcast as `:reset`, and the error "The model declined this request."
  is broadcast.
- **SESS-11** If the loop ends with an error, the error text is broadcast and
  the session returns to idle with the history kept.
- **SESS-12** If the loop task crashes, "The harness crashed: …" — the exit
  reason, on one line — is broadcast, the stop is written into the transcript
  (STOP-1, STOP-2) and any unanswered tool calls are closed with an error
  result, as in SESS-8.
- **SESS-13** A failure to save the history is logged and does not stop the
  session.
- **SESS-14** A session loads its saved model selection on start (STORE-9).
  `select_model/4` sets it, saves it with the history once the chat has
  messages, and broadcasts `{:model, selection}`. A session never writes a chat
  that has no messages: the file an empty chat has is the one STORE-22 writes
  when it is started. It is allowed mid-turn (MODEL-3).
- **SESS-15** A session process whose state predates a struct field (e.g. one
  that outlived a hot reload) is upgraded on its next call: missing fields get
  their defaults and the saved model selection (SESS-14), auto-approved
  tools (SESS-16), project (PROJ-9), compaction state (COMPACT-24), jail
  setting (SESS-30), turn limits (SESS-31), reasoning effort (SESS-40) and the
  done flag (SESS-35) are
  loaded, so snapshots and turns don't crash. Fields the state already has are
  kept. The turn record (INTR-1) is not loaded from disk: it belongs to the
  process that is running the turn, so a missing one defaults to `nil`; the
  pending question (SESS-34) has nothing saved to load either, and takes its
  default, which is none.
- **SESS-16** A session loads its saved auto-approved tools on start (STORE-15),
  or, for a chat that is new, starts with every tool that can need approval
  (APPR-14, APPR-13).
  `set_auto_approve/3` (chat id, tool name, boolean) turns auto-approval for a
  tool on or off (APPR-8, APPR-13), saves it with the history once the chat has
  messages (as in SESS-14), and broadcasts `{:auto_approve, names}` with the
  sorted list. It is allowed mid-turn (APPR-11).
- **SESS-30** A session loads its saved jail setting on start (STORE-26) and
  every session it starts from (a sub-task, SUBTASK-30) carries it. `set_jail/2`
  (chat id, boolean) turns the jail for this chat's commands on or off (ISOL-16),
  saves it with the history once the chat has messages (as in SESS-14,
  STORE-25) and broadcasts `{:jail, on?}`, so every view of the chat agrees. It
  is allowed mid-turn (ISOL-19).

- **SESS-17** `ensure_started/2` options `task` (sub-task metadata, STORE-16),
  `selection` (a model selection, MODEL-1), `auto_approve` (a list of
  tool-name strings, APPR-8) and `limits` (turn limits, SESS-31) set the new
  session's values instead of the saved ones. None stores the selection as the
  default model (MODEL-15). The session
  saves its task metadata with the history (STORE-16), and a session whose state
  predates the `task` field is upgraded as in SESS-15.
- **SESS-18** `Elia.Agent.update_task/2` (chat id, map of changes) merges the
  changes into the chat's task metadata and saves it. It returns
  `{:error, :not_a_task}` for a chat that has none.
- **SESS-19** Every status change (SESS-4) is also broadcast on
  `Elia.Agent.activity_topic/0` as `{:chat_status, id, status}`, so a page can
  follow every chat without subscribing to each. A session also keeps its
  status as its value in `Elia.Agent.Registry`,
  `Elia.Agent.awaiting_approval/0` returns the ids of the sessions whose status
  is `:awaiting_approval`, `Elia.Agent.awaiting_input/0` (SESS-34) those whose
  status is `:awaiting_input`, and `Elia.Agent.paused/0` those whose status is
  `:paused`, without calling them.
- **SESS-20** `update_task/2` (SESS-18) broadcasts `{:task, metadata}` with the
  merged metadata on the chat's topic.

- **SESS-21** When a session starts and the last message of its saved history
  is an assistant message whose tool calls have no results (the app stopped
  while they ran), the calls are closed with an error result ("The app
  restarted while this tool was running.") and the history is saved, as in
  SESS-12, so the chat can go on (SUBTASK-20).
- **SESS-22** Stopping a running turn (SESS-8) first tells `Elia.Tasks`
  (SUBTASK-16, SUBTASK-17): if this chat is a running sub-task, the stop is
  recorded as the stop of that turn, so its task goes on running (SUBTASK-16),
  and if it is the parent of running sub-tasks, each of their turns is stopped
  too, with the same result (they stop, their tasks go on).

- **SESS-23** A turn runs in the chat's project: `send_message` puts the chat's
  `project` and its folder as the `workspace` into the loop options, overriding
  any the caller passed, so a sub-task session (which inherits its parent's loop
  options, SUBTASK-5) still runs its tools in its own project's folder (PROJ-9,
  PROJ-12).

- **SESS-24** A turn sends the loop the chat's full history and its compaction
  state (COMPACT-2, COMPACT-29), after compacting first if the estimated request
  is over the trigger (COMPACT-5, COMPACT-6). The session keeps the full history
  — every message the loop appends is saved — and the loop derives the request
  view it sends from that history at every step (COMPACT-29), so the
  `estimated_input_tokens` of a usage report (CTX-10) is the estimate of what
  that step sent (COMPACT-26); the loop reports a mid-turn pass that advanced the
  state back to the session, which saves it and broadcasts it (COMPACT-29).
- **SESS-25** `Elia.Agent.compact/1` compacts an idle chat on demand
  (COMPACT-10), ignoring the threshold and the target; it returns
  `{:error, :busy}` while a turn runs. `Elia.Agent.set_compaction/2` sets this
  chat's compaction options (COMPACT-9) and `Elia.Agent.set_pin/4` pins or
  unpins a message or one of its blocks (COMPACT-21), returning
  `{:error, :no_such_message}` for an index the chat doesn't have. Both save
  the state with the chat and broadcast `{:compaction, state}` (COMPACT-24);
  when the request view changes the CTX-10 adjustment is cleared (COMPACT-27),
  so the next usage report calibrates it afresh.
- **SESS-26** A session loads the chat's compaction state on start and can be
  given options for a new one with `ensure_started/2`'s `compaction` option
  (`COMPACT-9`). An options or pin change is written to disk right away, while a
  chat with no messages isn't (as in SESS-14).

- **SESS-27** When the loop pauses at a limit (LOOP-19), the session's status
  becomes `:paused`, it broadcasts `{:paused, message}` (a message naming the
  limit) and keeps the turn's task; `snapshot/1`'s `pause` holds that message.
  `Elia.Agent.resume/1` sends the loop `{:pause_decision, :continue}` and
  returns to `:running`; `Elia.Agent.fail_task/1` sends `{:pause_decision, :fail}`
  and returns to `:running`, so the loop ends the turn with the limit's error
  (SESS-11). Both return `{:error, :not_paused}` when the chat isn't paused.
  Ending the turn (SESS-8, SESS-11, SESS-12) clears the pause.

- **SESS-28** `Elia.Agent.running/0` returns the ids of the sessions whose
  status is `:running` (SESS-4) — a turn is running — read from the registry
  without calling the sessions, like `awaiting_approval/0` and `paused/0`
  (SESS-19), so a chat list can show which chats are working on first render.

- **SESS-29** `Elia.Agent.delete/1` deletes a chat: it stops the chat's turn if
  one is running (SESS-8, which also stops its sub-tasks' turns, SESS-22),
  terminates its session process so no stale session can later save it again,
  then removes the saved chat (STORE-23). A chat with no session is simply
  removed. It returns `:ok`, and `{:error, :invalid_id}` for an invalid id
  (STORE-4).

- **SESS-31** A session loads the chat's turn limits on start (STORE-28), and a
  session started for a sub-task is given that child's own (LIMIT-5, SESS-17).
  `Elia.Agent.set_limits/2` (chat id, a map of changes) sets this chat's step
  limit, time budget and whether a limit pauses the turn (LIMIT-1), saves them
  with the chat once it has messages (as SESS-14, STORE-27) and broadcasts
  `{:limits, limits}` (SESS-6), so every view of the chat agrees. It is allowed
  mid-turn (LIMIT-3), and `snapshot/1` carries them (SESS-7). A turn is started
  with them without overriding an option the caller passed explicitly (LIMIT-3).

- **SESS-40** A session loads the chat's saved reasoning effort on start
  (STORE-38, `nil` when it has none of its own, so the configured default
  applies, LLM-38). `Elia.Agent.set_effort/2` (chat id, `nil` or one of
  `"low"`, `"medium"` and `"high"`, LLM-39) sets this chat's effort, saves it
  with the chat once it has messages (as SESS-14, STORE-37) and broadcasts
  `{:effort, effort}` (SESS-6), so every view of the chat agrees; `nil` gives
  the chat no effort of its own again. Any other value returns
  `{:error, message}` and changes nothing. The snapshot carries it (SESS-7), a
  session whose state predates the field loads it (SESS-15), and every turn's
  request carries it as its `:effort` (LLM-39), unless the caller's own loop
  options name one, which wins. It is allowed mid-turn: the next turn is sent
  with it.

- **SESS-32** `Elia.Agent.live?/1` reports whether a session for a chat is
  running in this app instance, read from `Elia.Agent.Registry` without calling
  it, like `running/0` and `awaiting_approval/0` (SESS-19, SESS-28). It is
  `false` for a chat with no session, for an invalid or unknown id, and when the
  registry isn't running. A chat list uses it to tell the record a restart left
  behind (INTR-2, STORE-31) from a turn that is running right now.
- **SESS-34** A question from the loop (LOOP-21) is held by the session: each
  call in `{:loop_await_input, pid, calls}` gets the tool status
  `:awaiting_input`, the status becomes `:awaiting_input` (SESS-4), and the
  session waits for `Elia.Agent.answer/3` (chat id, call id, the answer text) on
  every one of them. Answering sets that call's status to `:answered`; when the
  last pending call is answered the loop is sent
  `{:input_answers, %{call_id => answer}}` and the status returns to `:running`,
  so none of the step's tools runs before then (ASK-6). `answer/3` returns
  `{:error, :blank}` for an answer that is blank once trimmed and
  `{:error, :not_pending}` for a call that isn't awaiting an answer, changing
  nothing either way (ASK-4). Ending the turn (SESS-8, SESS-11, SESS-12) clears
  the pending questions, so a late answer is `{:error, :not_pending}` (ASK-7),
  and messages from a stopped loop (SESS-9) are ignored as before.
  `Elia.Agent.awaiting_input/0` returns the ids of the sessions waiting for an
  answer without calling them (SESS-19). No event is added for the question: the
  card follows the status changes (SESS-6), and a UI that connects mid-question
  renders it from the snapshot's `tool_status` and the history (SESS-7). Nothing
  is saved for a question beyond the tool call and its result (ASK-2).

- **SESS-37** A pause at a limit is recorded in the transcript as well as
  announced (SESS-27): when the loop pauses (LOOP-19), the session appends the
  harness message LIMIT-10 describes — the pause message plus what the decision
  does — to the history, marked `meta.limit` with the limit it names
  (`{:steps, n}` or `{:time, ms}`), and saves the chat, exactly as it appends
  any other message (SESS-6, STORE-1): the transcript keeps it, the broadcast
  brings it to every open page, and the resumed turn sends it to the model like
  any harness message, as a restart's notice does (INTR-3). The banner,
  `snapshot/1`'s `pause`, the status and the turn's task are unchanged
  (SESS-27), and nothing is written for a session that does not persist
  (SESS-13).

- **SESS-38** Every way a turn ends other than the model finishing writes it
  into the transcript through one path (STOP-1): the loop's error (SESS-11), its
  refusal (SESS-10), the loop dying (SESS-12) and the user's stop (SESS-8) each
  append the marked harness message STOP-2 describes — `meta.stopped` holding
  the kind, one of `:limit`, `:error`, `:refused`, `:crash`, `:stopped` —
  before the session returns to idle, so a stop is written whether or not a page
  is open and stays after the turn is over. The text is the same one the event
  carries: `{:error, text}` is still broadcast for the watchers that read a
  chat's events (STOP-4, SUBTASK-13), and the page renders the message rather
  than that event, so a stop is not shown twice (UI-82).

- **SESS-33** `Elia.Agent.set_title/2` (chat id, text) sets the chat's own title
  (TITLE-1, TITLE-4): the session shapes the text (trimmed, whitespace collapsed,
  cut to 60 characters, TITLE-2), saves it with the chat once the chat has
  messages (as SESS-14, STORE-32) and broadcasts `{:title, title}` (SESS-6), so
  every view of the chat agrees; the shaped title is returned. It returns
  `{:error, message}` and changes nothing for a blank title (TITLE-2) and for a
  chat whose session has task metadata (TITLE-3, STORE-16), and the session
  loads the saved title on start (STORE-32), upgrading a state that predates the
  field as in SESS-15.

- **SESS-35** `Elia.Agent.set_done/2` (chat id, boolean) marks the chat done or
  reopens it (DONE-1, DONE-6): the session saves the flag with the chat once the
  chat has messages (as SESS-14, STORE-34), broadcasts `{:done, on?}` (SESS-6)
  and returns `{:ok, on?}`, so every view of the chat agrees. It returns
  `{:error, message}` and changes nothing for a chat whose session has task
  metadata (DONE-3, STORE-16), and it is allowed mid-turn, like the chat's other
  settings (SESS-16, SESS-30): marking a chat done changes nothing about the turn
  it is running. The session loads the saved flag on start (STORE-34), upgrading
  a state that predates the field as in SESS-15.
- **SESS-36** A done chat is continued like any other: `send_message` (SESS-3)
  works on it unchanged, and starting the turn clears the chat's done flag
  (DONE-9) — the save the user message triggers writes it away (STORE-34) and,
  when the chat was done, `{:done, false}` is broadcast (SESS-6). Nothing about
  the message, the turn or the composer is different, and no confirmation is
  asked (DONE-8).

- **SESS-39** A retry the loop reports (`{:loop_retry, info}`, RETRY-3) is
  broadcast as `{:retry, info}` and changes nothing else: the turn keeps running
  (SESS-4), no message is appended and nothing is saved (RETRY-3), so the
  history holds only what the turn completed. A report from a loop the session
  no longer runs (SESS-9) is ignored, like its other late messages.

## Out of scope

- Several turns running at once in one session.

## Implementation

`Elia.Agent`, `Elia.Agent.Session`.

## Tests

`test/elia/agent_test.exs`, `test/elia/chat_titles_test.exs` (SESS-33, the
title's event and its refusals), `test/elia/chat_done_test.exs` (SESS-35,
SESS-36).
