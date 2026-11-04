# Stopped turns

Status: Draft

A turn can end without the model finishing it: it reaches a limit (LOOP-3), a
provider fails (LOOP-5, LLM-13), the model declines the request (LOOP-4), the
user stops it (SESS-8), or the loop dies (SESS-12). In every one of those cases
the session broadcast the reason once, to whoever happened to be looking: no
page open, no record, nothing saved. A chat could then sit there stopped, with a
transcript that ends mid-thought — a tool call and nothing after it — and
nothing anywhere to say why. That is the same hole [turn
limits](turn-limits.md) and [interrupted turns](interrupted-turns.md) closed for
a pause at a limit and for a restart in the middle of a turn. This feature
closes it for the rest: how a turn ended is written into the transcript, marked,
and saved, so the chat says why it stopped whenever it is opened again.

## Requirements

- **STOP-1** A turn that ends without the model finishing it writes the reason
  into the transcript: as the turn ends, the session appends one harness message
  (UI-9), saved with the chat (STORE-1, STORE-2) and rendered as an error row
  (UI-82, UI-12). It is written whether or not any page is open, and it stays
  when the turn is over. A turn the user continues (LOOP-19) is a new turn, so
  its own end writes its own message. Nothing is written for a turn that ends
  because the model finished (`:end_turn`, LLM-4) — its own last message is the
  transcript — and nothing is written by a session that doesn't persist
  (SESS-13).

- **STOP-2** The message is marked `meta.stopped` with the kind of stop
  (STOP-4's event carries the same text), and says what happened:
  - `:limit` — the limit's own error (LOOP-3, LOOP-20): "Stopped after 100 steps
    without finishing", or the time budget's wording. It is written when the
    turn *ends* at a limit: the user failed a paused turn (LIMIT-4, LOOP-19), or
    the chat turned pausing off (LIMIT-9). A pause before it wrote a message of
    its own (LIMIT-10), so the transcript holds both: that the turn waited, and
    that it was ended.
  - `:error` — the loop's reason, as the text the loop returned, e.g. "OpenRouter
    stream failed: socket closed" (LOOP-5's output limit, a provider that failed
    after its retries, LLM-13).
  - `:refused` — "The model declined this request." (LOOP-4), appended after the
    rollback (SESS-10), so it is the last thing the transcript holds rather than
    the request the model declined.
  - `:crash` — "The harness crashed: <the crash's banner>", written after the
    open tool calls got their error results (SESS-12), so every call still has
    one. It names the reason the loop died with, on one line —
    "The harness crashed: ** (RuntimeError) boom", "…: ** (exit) killed" — and
    not a stacktrace.
  - `:stopped` — "Stopped by the user." (SESS-8).

- **STOP-3** The message is part of the history (SESS-1) and so is sent to the
  model on the next turn, exactly as INTR-3's notice and LIMIT-10's pause are:
  the model learns why its last turn ended — the user stopped it, a limit ended
  it, a provider failed — instead of being handed a history that stops with an
  unanswered tool call.

- **STOP-4** A stop is still reported to the watchers that read a chat's events,
  with the same text as the message, and no page shows it twice: `{:error, text}`
  goes to the chat's topic as before (SESS-11, SESS-12), because a sub-task's
  parent reads a child's failure from it (SUBTASK-13), while the message is what
  the page renders (UI-82). A stop the user asked for is not reported as an
  error: SESS-8's "Stopped." notice is gone and its message is the record, and a
  parent whose child was cancelled still learns that its own way (SUBTASK-16,
  SESS-22).

- **STOP-5** Only a stop is written: a tool call's own error is the tool result
  it is (LOOP-6, LOOP-7), the rollback before `:refused` is the reset it is
  (SESS-10), and a turn the app restarted during says so in its own words
  (INTR-3) — the record that turn left behind is what reports it (INTR-1), not
  this message.

## Out of scope

- Running a stopped turn again, or retrying what it was doing.
- What a stop leaves in the chat list: the chat is idle, as before (SESS-4,
  UI-59).

## Implementation

`Elia.Agent.Session` (one way to stop a turn: append the message and report it),
`EliaWeb.ChatLive` (the row, and the event it no longer renders, UI-82).

## Tests

`test/elia/agent_test.exs` (each kind: a limit ending, a provider error, a
refusal, a crash and a stop — written, marked and saved, STOP-1 to STOP-3),
`test/elia_web/live/chat_live_test.exs` (the row, once per stop, UI-82),
`test/elia/tasks_test.exs` (a child that fails still reports its failure,
SUBTASK-13).
