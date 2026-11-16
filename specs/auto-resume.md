# Auto resume

Status: Implemented

A turn runs in the chat's session process (SESS-1), and a restart kills it: the
session and the turn's task are gone, the chat is left with the messages the
turn had saved, and its record still holds a `turn` (INTR-1). [Interrupted
turns](interrupted-turns.md) makes that visible — the chat is listed as
interrupted, its transcript says the app restarted (INTR-2, INTR-3), and the
user carries on by sending a message. That is the right answer when the server
came back from a crash, and the wrong one for the restart Elia asks for itself:
a "Restart" deploy (DEPLOY-7) stops every running turn to load new code, and the
work those chats had in flight is what the user wants back when the server comes
up, not a note telling them to carry on.

This feature resumes them: when the application starts, the chats a restart cut
a turn short in carry on by themselves, from the history the chat already holds.
A resumed turn is the same turn, run by a new session — the tool results the turn
had already written stay, and the tool calls the restart cut off are closed with
an error result exactly as INTR-3 closes them (SESS-21), so the model is told
what happened and nothing is handed back to it as if it had finished.

A sub-task chat is resumed like any other (RESUME-7), which means more than
starting its turn again: the registry of running children is in memory
(SUBTASK-11), so the restart emptied it, and the child's entry is taken again
before its turn starts — the tree it works in has one writer again
(SUBTASK-4), and the child is a running child again, which is what a parent's
`await_task` waits on (SUBTASK-27) and what ends when the chat is marked done
(SUBTASK-20, SUBTASK-33).

Resuming runs a model and its tools with nobody watching, which bounds the
feature. One automatic resume follows a turn's interruption and never a second
one (RESUME-5): a resume whose own work takes the server down therefore ends as
a note in the transcript rather than as a restart loop (RESTART-1, RESTART-4),
and the user's next message — the recovery interrupted turns always had — is
still how such a chat carries on. A chat that was waiting for the user is not
resumed either: one paused at a limit (RESUME-8) was asking them to decide, and
a child whose workspace another child is writing in (RESUME-7) has no entry free
to take.

## Requirements

- **RESUME-1** When the application starts, `Elia.Agent.Resumer` — a child of the
  application's supervisor (`Elia.Application.children/0`, HOT-10) — starts a
  session (`Elia.Agent.ensure_started/2`, SESS-1) for every saved chat a restart
  cut a turn short in (INTR-2, STORE-31, STORE-39). The scan reads every saved
  chat and not the chat list's first page (STORE-39), a sub-task chat's session
  is started before the session of the chat that started it (STORE-18), a chat
  whose session is already running is left to that session (`Elia.Agent.live?/1`,
  SESS-32), a chat whose session fails to start is logged and left out of the
  rest of the scan, and the scan never holds up the application's own start: it
  runs in the resumer's own process, after its own child has started.

- **RESUME-2** The decision is the session's, not the boot scan's: a session
  starting for a chat whose saved record holds a `turn` (STORE-30, INTR-2)
  resumes that turn (RESUME-3) instead of only announcing it, unless RESUME-5 to
  RESUME-8 say otherwise — the record saying the turn was already resumed,
  automatic resume being switched off, or the turn having been paused at a
  limit. A page opening a chat and a boot scan that got there first therefore do
  the same thing: which of them started the session makes no difference.

- **RESUME-3** A resumed turn carries on from the history the chat already
  holds, with no new user message: the session closes the tool calls the restart
  left unanswered (SESS-21) and appends one harness message (UI-9) — "The app
  restarted while this turn was running. Carrying on with it." — marked as
  INTR-3's notice is, so the transcript shows it as an error row (UI-73) that
  stays afterwards. It is saved as INTR-3 saves its notice, and the loop then
  runs over the chat's history as it does for a turn a message starts (SESS-3,
  COMPACT-5), with the chat's own model selection (MODEL-3), turn limits
  (SESS-31), jail setting (SESS-30), reasoning effort (SESS-40), project and
  compaction state (COMPACT-24).

- **RESUME-4** A resumed turn is a turn like any other, and its chat says so: the
  chat's status is `:running` from the moment the session starts (SESS-4,
  SESS-19), so it is listed as `working` (UI-59) in place of `interrupted`
  (INTR-2, UI-72) in every page, whether or not it shows that chat; its tool
  calls are put to the user for approval as a turn's are (APPR-2); the user can
  stop it (SESS-8); and it reaches a limit, pauses or ends as a turn does
  (LOOP-19, STOP-1).

- **RESUME-5** The record of a turn an automatic resume started says so
  (`resumed: true`, STORE-30), and a chat whose record says so is never resumed
  again: a restart that cuts a resumed turn short leaves the chat interrupted and
  a session starting for it writes INTR-3's notice, so one automatic resume can
  never follow another, whatever the restart was — a resume whose own work takes
  the server down cannot become a restart loop (RESTART-1, RESTART-4). A turn
  the user sends afterwards (SESS-3) is an ordinary turn, and the next restart
  resumes it.

- **RESUME-6** Automatic resume is on unless it is switched off
  (`config :elia, Elia.Agent.Resumer, enabled: false`, read at boot). Switched
  off, no session is started for an interrupted chat at boot (RESUME-1) and a
  session starting for one writes INTR-3's notice instead of resuming it
  (RESUME-2, RESUME-3): a chat a restart cut short is then exactly what INTR-2
  and INTR-3 describe.

- **RESUME-7** A sub-task chat (SUBTASK-1) is resumed like any other, and its
  entry in the registry of running children (SUBTASK-11) is taken again before
  its resumed turn starts, so the tree it works in has one writer again
  (SUBTASK-4) and the child is a running child again: it holds an entry, so a
  parent's `await_task` on it waits (SUBTASK-27) until its chat is marked done
  (SUBTASK-33) — the end that computes and saves the result (SUBTASK-9,
  SUBTASK-13) and releases the entry. There is no watcher to put back (the
  retired SUBTASK-28): what waits for a child is the parent's own `await_task`
  call. A child whose entry cannot be taken — another running child already
  writes in that workspace (SUBTASK-4, SUBTASK-11) — or whose task says nothing
  about the commit it started from, which the result needs (SUBTASK-9), is not
  resumed: its session writes INTR-3's notice and leaves its task as it is.

- **RESUME-8** A chat whose turn had paused at a limit when the restart came
  (SESS-27, LOOP-19) is not resumed: it was waiting for the user's decision, and
  its history still ends with the pause's own message (LIMIT-10). A session
  starting for it writes INTR-3's notice instead of carrying the turn on — for a
  sub-task chat too, whose parent's `await_task` then answers as SUBTASK-20 says
  (SUBTASK-27) — so the decision stays the user's and their next message starts a
  new turn (SESS-3).

## Configuration

`config :elia, Elia.Agent.Resumer, enabled: false` switches automatic resume off
(RESUME-6); anything else, including no configuration at all, leaves it on. The
test environment sets it to `false`, so a test run's own boot resumes nothing —
the tests that cover a resume turn it on for themselves (RESUME-2 to RESUME-5,
RESUME-7, RESUME-8) and drive the boot scan directly (RESUME-1, RESUME-6).

## Stored data

The `turn` record a chat carries while a turn runs (STORE-30) gains one optional
key, `resumed: true`, written for a turn an automatic resume started (RESUME-5).
This is backward compatible and needs no migration: a chat saved before this
change has no such key and is read as a turn that was not resumed, and the key
is dropped with the record as soon as the turn ends (INTR-1).

## Out of scope

- A manual resume control — a button on a chat, or one that resumes every
  interrupted chat — and a warning before a restart deploy that chats are
  running (CONF-19): a chat that isn't resumed carries on with a message, as
  INTR-3 says.
- Restoring what the restart took with the turn's process: a tool call the turn
  had issued but never got a result for is closed as a failure (SESS-21), an
  approval or a question the user had not answered is not put to them again, and
  a pause is not restored (RESUME-8).
- Reconnecting a parent's own wait: the `await_task` call the restart killed is
  closed as any open tool call is (SESS-21, SUBTASK-20) and the parent's resumed
  turn asks again if it wants to wait (SUBTASK-27) — the child's own chat being
  marked done is what the wait then rests on (RESUME-7, SUBTASK-33).
- Carrying a turn's step count, time budget or token spend over the restart: a
  resumed turn is a new turn and its limits start afresh (RESUME-4, LIMIT-3,
  LOOP-19).

## Implementation

`Elia.Agent.Resumer` (the boot scan), `Elia.Agent.Session` (the record it
reads, the resume and the notice), `Elia.Application.children/0` (the resumer,
and `Elia.Tasks` as a child, so a session's own start never has to start the
registry — SUBTASK-11), `Elia.Tasks` (the entry taken again, RESUME-7),
`Elia.Store` (`interrupted/0`, STORE-39).

## Tests

`test/elia/auto_resume_test.exs` (the boot scan and what it leaves alone,
RESUME-1, RESUME-6; a resumed turn, its notice and its record, RESUME-2 to
RESUME-5; a chat whose turn was paused at a limit, RESUME-8; a sub-task chat
resumed, its entry taken again, and its result collected by a parent's
`await_task` after its chat is marked done, RESUME-7),
`test/elia/agent_test.exs` (the notice for a turn whose last message was a tool
call, INTR-3, SESS-21), `test/elia/store_test.exs` (STORE-39, and the `resumed`
key a resumed turn's record carries, STORE-30), `test/elia/tasks_test.exs` (the
entry taken again: what it takes and what it leaves alone, RESUME-7).
