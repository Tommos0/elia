# Marking a chat done

Status: Draft

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

A sub-task is left alone: it is finished by its `finish_task` result, and its
status is its task status (SUBTASK-3, UI-46), so a done flag on one is refused
rather than shown (DONE-3).

## Requirements

### The flag

- **DONE-1** An ordinary chat (one with no task metadata, STORE-16) may be
  marked done. The flag is saved with the chat (STORE-34), carried by each
  listed chat (STORE-35), loaded by a session on start (SESS-35) and part of
  its snapshot (SESS-7), so every view of the chat agrees without a call of its
  own. A chat that isn't done is exactly as before: every chat saved before
  this feature has no flag and is unchanged.
- **DONE-2** A done chat shows it wherever a chat's status is shown: its
  sidebar row (UI-80) and the dashboard's rows (DASH-3, DASH-5, DASH-7) read
  `done` — a check icon and the `title` "Done" — in place of `idle`. Anything
  that needs the user or is running now still comes first (UI-59): awaiting
  approval, awaiting an answer, paused, a turn running right now and a turn a
  restart cut short (UI-72) are all shown as they are, done or not.
- **DONE-3** A task chat has no done flag: it shows its task status (UI-46),
  and marking it done is refused (SESS-35) as an error the model can read and,
  in the chat page, as a control that isn't there (UI-79). A chat that carries
  a flag and then becomes a task chat keeps showing its task status.

### Marking it by hand

- **DONE-4** The open chat's composer toolbar — beside the "Focus" toggle
  (UI-60) and the settings link — carries a done control (`#done-toggle`): a
  button with `aria-pressed` that marks the chat done, and reopens it when it
  is done. Its label says which one it does ("Mark done" while the chat isn't
  done, "Reopen" while it is), so the state is readable without hovering, and
  it never needs a confirmation (DONE-9: nothing is lost by either).
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
  (DEPLOY-13), that a done chat is still resumable, and that a sub-task is
  refused (DONE-3).
- **DONE-7** The tool answers with the chat's flag as it now is ("This chat is
  marked done." / "This chat is open again."), so the model can tell that
  nothing stopped and that the chat can still be continued (DONE-8). A missing
  or non-boolean `done` is read as `true`; the only refusal is a task chat
  (DONE-3), which comes back as an error result as any tool error does
  (SUBTASK-4).

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
- Marking a sub-task done by hand or with a tool (DONE-3).

## Implementation

`Elia.Store` (the saved field, the listing, `latest/0`), `Elia.Agent` and
`Elia.Agent.Session` (`set_done/2`, the `{:done, on?}` event, clearing it when a
message starts a turn, the snapshot field), `Elia.Skills.Done` (the skill and
its `mark_done` tool) and `config/config.exs` (the built-in skill list),
`EliaWeb.ChatStatus` (the status and its icon and title), `EliaWeb.ChatLive`
(the toolbar control, the sidebar, the event), `EliaWeb.DashboardLive` (the
statuses it shows, through `EliaWeb.ChatStatus`).

`AGENTS.md` gains one sentence in its merging bullet: after the merge, the chat
marks itself done (DONE-6), so an agent in this project does the usual thing
without being told each time.

## Tests

`test/elia/chat_done_test.exs` (the flag saved, loaded and listed, `latest/0`
skipping it, `set_done/2` and its refusal, clearing it with a message, the tool
end to end, DONE-1, DONE-3, DONE-6 to DONE-10),
`test/elia_web/live/chat_done_test.exs` (the toolbar control and the sidebar
icon, the event, a done chat that is continued, DONE-2, DONE-4, DONE-5, DONE-9),
`test/elia/store_test.exs` and `test/elia_web/live/dashboard_test.exs`
(STORE-29, STORE-34, STORE-35, DASH-3).
