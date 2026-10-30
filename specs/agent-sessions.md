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
- **SESS-4** Session status is one of `:idle`, `:running` or
  `:awaiting_approval`. Every change is broadcast.
- **SESS-5** Every message the loop produces is appended to the history,
  saved (STORE-1) and broadcast. Messages with empty content are dropped.
- **SESS-6** Events are broadcast on `Elia.Agent.topic(id)` as
  `{:agent, id, event}`, where event is one of `{:message, m}`,
  `{:delta, :text | :reasoning, text}`, `{:notice, text}`, `{:status, s}`,
  `{:tool_status, call_id, s}`, `{:error, text}`, `{:reset, messages}`,
  `{:model, selection}` (the chat's model selection changed, MODEL-1),
  `{:auto_approve, names}` (the chat's auto-approved tools changed, SESS-16).
- **SESS-7** `snapshot/1` returns the id, messages, status, per-call tool
  status, the chat's model selection (`nil` if none yet) and its
  auto-approved tool names (sorted list), so a UI that connects mid-turn can render the current state.
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
  their defaults and the saved model selection (SESS-14) and auto-approved
  tools (SESS-16) are loaded, so snapshots and turns don't crash. Fields the
  state already has are kept.
- **SESS-16** A session loads its saved auto-approved tools on start (STORE-15).
  `set_auto_approve/3` (chat id, tool name, boolean) turns auto-approval for a
  tool on or off (APPR-8, APPR-13), saves it with the history once the chat has
  messages (as in SESS-14), and broadcasts `{:auto_approve, names}` with the
  sorted list. It is allowed mid-turn (APPR-11).

## Out of scope

- Several turns running at once in one session.
- Deleting chats from the UI (`Elia.Store.delete/1` exists but isn't exposed).

## Implementation

`Elia.Agent`, `Elia.Agent.Session`.

## Tests

`test/elia/agent_test.exs`.
