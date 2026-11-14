# Interrupted turns

Status: Implemented

A turn runs in the chat's session process (SESS-1). When the server restarts —
a "Restart" deploy (DEPLOY-7), or `bin/serve` starting it again after a crash
(RESTART-1) — the session and the turn's task are gone, and everything the turn
had not saved is lost. Since a session saves only the messages the loop has
already appended, a restart in the middle of a turn leaves the chat looking as
if the user's last message had simply been ignored: no error in the transcript,
and a chat list that shows the chat as idle.

This feature records the turn in the saved chat while it runs, so that a later
session can tell that the previous process was cut short and say so: an error
notice in the transcript, and a warning in the chat list. Both stay until a
session for the chat starts, which resumes the turn when automatic resume
applies ([auto resume](auto-resume.md), RESUME-2) and otherwise clears the
record (INTR-3).

A **hot reload** (DEPLOY-6) is not an interruption: it keeps the sessions and
their running turns, so the record is reported as interrupted only while no
session for that chat is running (INTR-2).

## Requirements

- **INTR-1** A session records the turn it is running in the saved chat: when a
  turn starts (SESS-3) the chat is saved with `turn` — the turn's own id and its
  start time (STORE-30) — and when the turn ends by any path the session itself
  handles, that is the loop finishing, an error or a refusal (SESS-10, SESS-11),
  a crash of the loop task (SESS-12), a stop (SESS-8) or a decision on a paused
  turn (SESS-27), the record is cleared and the chat saved. A saved chat
  therefore carries `turn` only while a turn is in flight. A session that does
  not persist (SESS-13, tests) writes nothing.

- **INTR-2** A chat whose saved record holds a `turn` (STORE-30) and which has no
  live session (`Elia.Agent.live?/1`, SESS-32) was interrupted: the app was
  restarted while that turn ran, and nothing will resume it. Every listed chat
  says whether it is in that state (`interrupted`, STORE-31), and the chat list
  shows it (UI-72) — including for a chat whose page is not open, so the user
  can see that a turn was cut short before opening the chat.

- **INTR-3** A session starting for an interrupted chat (INTR-2) appends the
  harness message "The app restarted while this turn was running. Send a message
  to carry on." to the history and saves it, which clears the record (INTR-1),
  and broadcasts its status on the activity topic (SESS-19) so every open page
  drops the chat list's marker (UI-72). The transcript keeps the notice (UI-73),
  so the chat says why the turn stopped however long afterwards it is opened.
  Tool calls the turn left unanswered are closed first (SESS-21), and a chat
  with no such record is left untouched. A session that resumes the turn
  instead (RESUME-2) closes the same calls and writes the notice of its own
  (RESUME-3).

- **INTR-4** A sub-task chat (SUBTASK-1) whose turn was cut short gets the same
  notice in its own transcript, and its listed task status stays `interrupted`
  (STORE-17, SUBTASK-20), which is what its parent's card shows — unless it is
  resumed, when it and its task are `running` again and its watcher is put back
  (RESUME-7).

## Out of scope

- Resuming or re-running the interrupted turn as such: automatic resume is
  [auto resume](auto-resume.md), and the notice this feature writes is what a
  chat says when nothing resumes it (RESUME-5 to RESUME-8).
- A task that a restart interrupted is not restarted by this feature either: it
  is resumed with its watcher put back, so its result still reaches its parent
  ([auto resume](auto-resume.md), RESUME-7).

## Implementation

`Elia.Agent.Session` (the turn record and the notice at start),
`Elia.Store` (`turn` and the listed `interrupted`, STORE-30, STORE-31),
`Elia.Agent.live?/1` (SESS-32), `EliaWeb.ChatLive` (UI-72, UI-73).

## Tests

`test/elia/agent_test.exs` (INTR-1 to INTR-4), `test/elia/store_test.exs`
(STORE-30, STORE-31), `test/elia_web/live/task_ui_test.exs` (UI-72),
`test/elia_web/live/chat_live_test.exs` (UI-73).
