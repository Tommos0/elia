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
  `:awaiting_approval` or `:paused` (SESS-27). Every change is broadcast.
- **SESS-5** Every message the loop produces is appended to the history,
  saved (STORE-1) and broadcast. Messages with empty content are dropped.
- **SESS-6** Events are broadcast on `Elia.Agent.topic(id)` as
  `{:agent, id, event}`, where event is one of `{:message, m}`,
  `{:delta, :text | :reasoning, text}`, `{:notice, text}`, `{:status, s}`,
  `{:tool_status, call_id, s}`, `{:error, text}`, `{:reset, messages}`,
  `{:compaction, state}` (the chat's compaction state changed, COMPACT-24),
  `{:model, selection}` (the chat's model selection changed, MODEL-1),
  `{:auto_approve, names}` (the chat's auto-approved tools changed, SESS-16),
  `{:paused, message}` (the turn paused at a limit, SESS-27),
  `{:subtask, call_id, child_id, status}` (a `spawn_task` call's child started
  or ended, SUBTASK-7; sent by `Elia.Tasks`, not by the session itself),
  `{:task, metadata}` (the chat's task metadata changed, SESS-20).
- **SESS-7** `snapshot/1` returns the id, messages, status, per-call tool
  status, the chat's model selection (`nil` if none yet), its
  auto-approved tool names (sorted list), its task metadata (`task`, `nil`
  for an ordinary chat), the project it belongs to (`project`, PROJ-9), its
  compaction state (`compaction`, COMPACT-24) and its pause message (`pause`,
  `nil` unless the turn is paused, SESS-27), so a UI that connects mid-turn
  can render the current state.
- **SESS-8** Stopping a turn kills its task, gives each unanswered tool call
  in the last assistant message an error result ("Cancelled by the user."),
  returns to idle and broadcasts the notice "Stopped.". Stopping an idle
  session does nothing.
- **SESS-9** Messages from a stopped loop that arrive late are ignored.
- **SESS-10** If the loop ends with `:refused`, the history is truncated to
  what it was before the turn's user message, the truncated history is saved
  and broadcast as `:reset`, and the error "The model declined this request."
  is broadcast.
- **SESS-11** If the loop ends with an error, the error text is broadcast and
  the session returns to idle with the history kept.
- **SESS-12** If the loop task crashes, "Agent crashed: …" is broadcast and
  any unanswered tool calls are closed with an error result, as in SESS-8.
- **SESS-13** A failure to save the history is logged and does not stop the
  session.
- **SESS-14** A session loads its saved model selection on start (STORE-9).
  `select_model/4` sets it, saves it with the history once the chat has
  messages (a chat with no messages is not written to disk), and broadcasts
  `{:model, selection}`. It is allowed mid-turn (MODEL-3).
- **SESS-15** A session process whose state predates a struct field (e.g. one
  that outlived a hot reload) is upgraded on its next call: missing fields get
  their defaults and the saved model selection (SESS-14), auto-approved
  tools (SESS-16), project (PROJ-9) and compaction state (COMPACT-24) are
  loaded, so snapshots and turns don't crash. Fields the state already has are
  kept.
- **SESS-16** A session loads its saved auto-approved tools on start (STORE-15).
  `set_auto_approve/3` (chat id, tool name, boolean) turns auto-approval for a
  tool on or off (APPR-8, APPR-13), saves it with the history once the chat has
  messages (as in SESS-14), and broadcasts `{:auto_approve, names}` with the
  sorted list. It is allowed mid-turn (APPR-11).

- **SESS-17** `ensure_started/2` options `task` (sub-task metadata, STORE-16),
  `selection` (a model selection, MODEL-1) and `auto_approve` (a list of
  tool-name strings, APPR-8) set the new session's values instead of the saved
  ones. None stores the selection as the default model (MODEL-15). The session
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
  is `:awaiting_approval`, and `Elia.Agent.paused/0` those whose status is
  `:paused`, without calling them.
- **SESS-20** `update_task/2` (SESS-18) broadcasts `{:task, metadata}` with the
  merged metadata on the chat's topic.

- **SESS-21** When a session starts and the last message of its saved history
  is an assistant message whose tool calls have no results (the app stopped
  while they ran), the calls are closed with an error result ("The app
  restarted while this tool was running.") and the history is saved, as in
  SESS-12, so the chat can go on (SUBTASK-20).
- **SESS-22** Stopping a running turn (SESS-8) first tells `Elia.Tasks`
  (SUBTASK-16, SUBTASK-17): if this chat is a running sub-task it is marked
  cancelled, and if it is the parent of running sub-tasks, each of their turns
  is stopped too.

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

## Out of scope

- Several turns running at once in one session.
- Deleting chats from the UI (`Elia.Store.delete/1` exists but isn't exposed).

## Implementation

`Elia.Agent`, `Elia.Agent.Session`.

## Tests

`test/elia/agent_test.exs`.
