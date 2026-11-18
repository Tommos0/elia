# Marking a chat done

Status: Implemented

An ordinary chat has one status: working, waiting for the user, or idle
(UI-59). Nothing says that the work is *finished* — that the change has landed
on the trunk `master` and the chat is waiting for nothing but a deploy
(DEPLOY-13). So the chat that just merged its branch looks exactly like the one
that was abandoned mid-turn, and `/chats` keeps resuming it as where the user
left off (STORE-29).

This feature gives a chat a **done** flag of its own, saved with it like its
title (STORE-32) and shown as its status (DONE-2). Typically the chat's agent
marks it done as its last step, right after merging its branch into `master`
(DONE-6); the user can also do it by hand from the open chat (DONE-4). Done is
bookkeeping, not a lock: a message in a done chat continues it as always and
reopens it (DONE-9), so nothing has to be undone before going on.

A sub-task has the same flag, and there it means more: marking a sub-task's
chat done *is* what ends the task (SUBTASK-33), whether the child's own
`mark_done` did it or the user did (DONE-4). So a child is finished when its
chat says it is, and its row shows the status any chat's does (DONE-2, UI-46).
What "done" means is a little different in a child, since its work is committed
on its own branch rather than landed on the trunk (SUBTASK-23, DONE-6).

## Requirements

### The flag

- **DONE-1** Any chat may be marked done, a task chat included (STORE-16). The
  flag is saved with the chat (STORE-34), carried by each listed chat
  (STORE-35), loaded by a session on start (SESS-35) and part of
  its snapshot (SESS-7), so every view of the chat agrees without a call of its
  own. A chat that isn't done is exactly as before: every chat saved before
  this feature has no flag and is unchanged.
- **DONE-2** A done chat shows it wherever a chat's status is shown: its
  sidebar row (UI-80) and the dashboard's rows (DASH-3, DASH-5, DASH-7) read
  `done` — a check icon and the `title` "Done" — in place of `idle`. Anything
  that needs the user or is running now still comes first (UI-59): awaiting
  approval, awaiting an answer, paused, a turn running right now and a turn a
  restart cut short (UI-72) are all shown as they are, done or not. A task chat
  is no different: it has no status of its own to stand in for (UI-46), so its
  row and its header (UI-48) read `done` where its chat is marked done and
  whatever the chat is doing otherwise. *Changed:* a task chat used to show its
  task's status, with `done` standing in for the ones that meant the task was
  over.
- **DONE-3** A task chat's flag is the end of its task (SUBTASK-33): marking
  one done ends it — the result is built and saved (SUBTASK-9, SUBTASK-13) and a
  parent's `await_task` returns it
  (SUBTASK-27) — and the child is finished. Reopening it (DONE-9) doesn't
  un-end the task: the end happened and the result stays (SUBTASK-13). Both the
  page's control (DONE-4) and the tool (DONE-6) work on a task chat, which is
  what makes a child's own `mark_done` the ordinary way for it to finish.
  *Changed:* a task chat's flag used to be bookkeeping beside the task, which
  ended with the child's `finish_task` (the retired SUBTASK-3) or its turn
  (SUBTASK-8).

### Marking it by hand

- **DONE-4** Every open chat's composer toolbar — beside the "Focus" toggle
  (UI-60) and the settings link — carries a done control (`#done-toggle`): a
  button with `aria-pressed` that marks the chat done, and reopens it when it
  is done. Its label says which one it does ("Mark done" while the chat isn't
  done, "Reopen" while it is), so the state is readable without hovering, and
  it never needs a confirmation (DONE-9: nothing is lost by either). A task
  chat has it too, under its task header (UI-48), where it is how the task is
  ended (DONE-3, SUBTASK-33).
- **DONE-5** The control acts on the click and the page follows
  `{:done, on?}` (SESS-35) as every other setting of the chat does: the button's
  state and the sidebar's icon for this chat (DONE-2) change without a reload,
  and every other view of the chat agrees (SESS-6, UI-6). It is offered while a
  turn runs as well: marking a chat done mid-turn changes nothing about the
  turn.

### Marking it from the agent

- **DONE-6** A built-in skill gives the chat a `mark_done` tool (SKILL-7):
  its input is `done`, an optional boolean defaulting to `true` (`false`
  reopens the chat), and it never needs approval (`:never`, so it is not a
  tool the approval popover offers, APPR-13), since it changes nothing on the
  machine. Its instructions tell the model that this is the chat's own
  bookkeeping — the work is finished and has landed on the trunk — that it
  should mark the chat done once it has merged its branch into `master`
  (DEPLOY-13), that a done chat is still resumable, and that in a sub-task the
  tool is what ends the task, where "done" means the work is committed on the
  child's own branch rather than landed on the trunk (SUBTASK-23, SUBTASK-33,
  DONE-3).
- **DONE-7** The tool answers with the chat's flag as it now is ("This chat is
  marked done." / "This chat is open again."), so the model can tell that
  nothing stopped and that the chat can still be continued (DONE-8). A missing
  or non-boolean `done` is read as `true`. Nothing refuses it, a task chat
  included (DONE-3), so it always answers.

### Continuing a done chat

- **DONE-8** A done chat can still be continued: nothing about it is locked,
  the composer, the transcript, the tools and the turn are the ones an idle
  chat has, and `Elia.Agent.send_message/2` (SESS-3) works on it unchanged.
- **DONE-9** Sending a message to a done chat reopens it: the flag is cleared
  with the save the message triggers, `{:done, false}` is broadcast when it was
  set (SESS-36), and the chat's status reads working, then idle again (DONE-2) —
  so a chat is never both done and working on something. The user's message is
  not refused, delayed or annotated in any way; no confirmation is asked.
- **DONE-10** Opening the chat list (`/chats`, UI-77) and the dashboard's
  "Continue" card (DASH-3) skip a done chat: `Elia.Store.latest/0` (STORE-29)
  leaves it out as it leaves out a task chat, so they resume the most recently
  started chat that is neither, and start a fresh one when every chat is done
  or a task. A done chat is still listed — the sidebar (UI-4), the dashboard's
  recent chats (DASH-7) and its needs-attention rows (DASH-5) — with its done
  status (DONE-2).

## Out of scope

- The harness working out by itself that a chat's branch was merged: no git
  inspection, no hook on the shell tool and no deploy step marks a chat done.
  The agent's own tool call (DONE-6) is the trigger, and a chat nobody marks
  stays open.
- Hiding or filtering done chats: a done chat stays in the chat list where it
  always was (DONE-10).
- Marking a chat done from anywhere but its own page (a sidebar or dashboard
  control, a bulk action) and a "done at" time or history.
- Done as a lock: no chat becomes read-only, undeletable or inaccessible.
- Marking a task chat done ending anything but the task: it doesn't stop a
  turn, delete a chat or merge a child's branch, so a finished child's work
  still lands when its parent merges it (SUBTASK-23).

## Stored data

The stored shape doesn't change: `done` is the `true` it always was, written
only while the chat is done and read back the same way (STORE-34, STORE-35), so
this is backward compatible and needs no migration. What changes is what the
flag does on a task chat: it now ends the task (DONE-3, SUBTASK-33), so a task
chat's file is read by the task machinery for it too — a child whose file
carries the entry is a child that has finished, and one whose file hasn't is
still running (SUBTASK-34).

## Implementation

`Elia.Store` (the saved field, the listing, `latest/0`), `Elia.Agent` and
`Elia.Agent.Session` (`set_done/2` on any chat, the `{:done, on?}` event,
clearing it when a message starts a turn, the snapshot field), `Elia.Skills.Done`
(the skill and its `mark_done` tool) and `config/config.exs` (the built-in skill
list), `EliaWeb.ChatStatus` (the status and its icon and title), `EliaWeb.ChatLive`
(the toolbar control, on a task chat's page too, the sidebar, the event),
`EliaWeb.DashboardLive` (the statuses it shows, through `EliaWeb.ChatStatus`).

`AGENTS.md` gains one sentence in its merging bullet: after the merge, the chat
marks itself done (DONE-6), so an agent in this project does the usual thing
without being told each time.

## Tests

`test/elia/chat_done_test.exs` (the flag saved, loaded and listed, `latest/0`
skipping it, `set_done/2` on an ordinary chat and on a task chat, clearing it
with a message, the tool end to end, DONE-1, DONE-3, DONE-6 to DONE-10),
`test/elia_web/live/chat_done_test.exs` (the toolbar control and the sidebar
icon, on a task chat's page too, the event, a done chat that is continued,
DONE-2, DONE-4, DONE-5, DONE-9),
`test/elia/store_test.exs` and `test/elia_web/live/dashboard_test.exs`
(STORE-29, STORE-34, STORE-35, DASH-3).
