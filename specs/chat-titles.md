# Chat titles

Status: Implemented

A chat's title is what its sidebar row, its page title and the chat list show,
and today it is always derived from the first user message, cut to 60
characters (STORE-7): a chat that opens with a long request — a spec, a bug
report, a pasted stack trace — is listed under an arbitrary prefix of it. This
spec lets a chat carry a title of its own, written by the agent from the request
it has in front of it, and keeps the derivation as the fallback, so a chat
without one is exactly as it is today. A chat can also be named by hand, from
its row in the chat list (TITLE-8, UI-104), and a name the user typed is the
user's: the agent leaves it alone (TITLE-9).

The trigger is the agent's own tool call, inside a turn it is already running:
the model has the whole request in context (more than a side-channel call would
see), the call can ride along with the turn's first real tool call instead of
costing a round trip, and a title that never gets written is a chat listed the
way it is now. Nothing else is added — no provider call, no timer, no
turn-count or end-of-turn hook (TITLE-7) — so no turn becomes slower or more
expensive because of this feature.

## Requirements

### The stored title

- **TITLE-1** A chat may have a title of its own, saved with it (STORE-32). It
  is the chat's title wherever a title is shown or listed — the sidebar row
  (UI-4, UI-74), the page title (UI-3), the chat page's own title row (UI-96),
  the chat settings header — in place of the STORE-7 derivation from the first
  user message. A chat without one lists and displays exactly as before, so
  every chat saved before this feature, and every chat the agent never names,
  is unchanged. The chat's `description` (STORE-10) is not affected: hovering
  a row (UI-33) still shows the first user message.
- **TITLE-2** A title is trimmed, its runs of whitespace collapsed to single
  spaces, and cut to 60 characters (the cut STORE-7 uses), so a long,
  multi-line or padded one can't break a sidebar row or a page title. A title
  that is blank after trimming is no title at all: it is refused (TITLE-6) and
  never stored (STORE-32), so no chat is ever listed under an empty title.
- **TITLE-3** A sub-task chat is named by its spawn (SUBTASK-2, SUBTASK-5): the
  `title` the spawn gave it is saved as the chat's own title when the chat is
  created (STORE-32), so it is the chat's title wherever a title is shown or
  listed, and its row in the chat list reads it (UI-45). The child may set a
  title of its own afterwards, like any chat (TITLE-4, TITLE-5): the spawn's
  title is its first name, not a rule it is held to. *Changed:* a task chat used
  to ignore any stored title and be listed under its task's title (STORE-17),
  with `set_title` refused in it (TITLE-6); both went with the task-only title
  rule.

### Setting it

- **TITLE-4** `Elia.Agent.set_title/2` (chat id, text) gives the chat its own
  title: the session applies TITLE-2's shape, saves it with the chat (STORE-32,
  writing a chat that has no messages is skipped as in SESS-14) and broadcasts
  `{:title, title}` on the chat's topic (SESS-6, SESS-33), so every view of the
  chat agrees.
- **TITLE-5** The built-in skill `titles` (SKILL-7) gives a chat a `set_title`
  tool whose input is `title` and which never needs approval (`:never`, so it is
  not a tool the approval popover offers, APPR-13). Its instructions tell the
  model that this is the name the chat list shows, that it should set one early
  in its first turn — alongside the first real tool call, in the same step, so it
  costs no extra round trip — and that it should set one again only if the chat
  turns to something else.
- **TITLE-6** `set_title` refuses a blank title (TITLE-2), as an error result
  to the model naming the reason; nothing is saved and nothing is broadcast. It
  also refuses a chat whose title was set by hand (TITLE-9), with an error
  naming that reason — that name is the user's, so overwriting it is the one
  thing the model must not do — saving and broadcasting nothing. It refuses
  nothing else. *Changed:* it used to refuse only a blank title; before that it
  also refused a chat whose session has task metadata (TITLE-3), and a sub-task
  may name itself like any chat.

### The trigger

- **TITLE-7** A title is set only by the agent's own tool call inside a running
  turn (TITLE-5). The harness never calls a provider for a title, and no timer,
  turn count or end-of-turn hook sets, refreshes or re-derives one. A chat named
  only by the STORE-7 derivation (TITLE-1) is therefore a normal outcome, not a
  failure, and no turn is made slower or more expensive by this feature.

### Naming a chat by hand

- **TITLE-8** A chat can be named by hand from its row in the chat list
  (UI-104): `Elia.Agent.rename/2` (chat id, text) takes the text as a name,
  shaped as TITLE-2 shapes any title, and when it is a name at all it gives the
  chat that title of its own (TITLE-1) — saved with the chat (STORE-32) and
  broadcast as `{:title, title}` (SESS-6, SESS-33), so its row (UI-4, UI-74), the
  page title (UI-3) and the chat settings header all read it at once — and
  returns it. A name that is blank once trimmed changes nothing and returns no
  name (TITLE-2), so the row goes back to what it showed. Renaming reaches a
  chat whose session isn't running by starting it, the way the chat settings
  page does (CSET-1), so the session that saves the chat next cannot write the
  older name back over it; a chat with no messages yet is saved with its new
  name, as a chat started from the UI is saved when it starts (STORE-22) — which
  is the case TITLE-4's save of a chat with no messages skips.
- **TITLE-9** A title set by hand is the user's: the chat records that it was
  set by hand, in a field of its own (STORE-55), so TITLE-6's refusal survives a
  restart and a session that resumes the chat holds to it, while the agent names
  a chat whose title is its own or derived (TITLE-1) as freely as before. The
  field is written only for a name set by hand — one the model set carries none
  — and a chat saved before this feature has none, so it reads exactly as it did
  (STORE-55, TITLE-1): the change needs no migration. A second hand-set name
  replaces the first, and the record with it.

## Out of scope

- Naming a chat anywhere but its row in the chat list: the chat page's own
  title row (UI-96) and the chat settings page show the name (TITLE-1), and
  nothing there edits it (TITLE-8).
- A harness-side provider call that generates a title, and any timer or
  turn-count trigger (TITLE-7). If compliance ever proves poor, this is the
  upgrade, and it writes the same stored field.
- Re-titling a chat as its subject shifts, beyond a second `set_title` the agent
  itself chooses to make (TITLE-5).

## Stored data

A chat's title is the `title` key of its saved file (STORE-1, STORE-32), and a
title set by hand carries the `title_by` key `"user"` beside it (STORE-55,
TITLE-9). A blank title, a title the model set and one derived from the first
message are not written at all (STORE-7, STORE-32), so a chat with no title of
its own carries neither key. Backward compatible: a chat saved before `title_by`
existed reads as one whose title was not set by hand, and no migration is
needed.

## Implementation

`Elia.Store` (the saved fields, the listing's precedence, the accessors for a
view with an id and for a title set by hand), `Elia.Skills.Titles` (the skill
and its `set_title` tool), `Elia.Agent` and `Elia.Agent.Session` (`set_title/2`
and `rename/2`, saving, the `{:title, title}` event, the snapshot field),
`EliaWeb.ChatLive` (the page title, the sidebar row, the tool card),
`EliaWeb.ChatList` (the row's menu and the rename input, UI-103, UI-104),
`config/config.exs` (the built-in skill list).

## Tests

`test/elia/chat_titles_test.exs` (the shape and the fallback, saving and
loading, the listing's precedence, and a spawn's title becoming the child's own
with `set_title` working in the child, its blank refusal, a name set by hand
saving and outliving the model's, and the refusal that follows it,
TITLE-1 - TITLE-9), `test/elia_web/live/chat_title_test.exs` (the page
title and the row, `{:title, title}` mid-turn, the card's summary, UI-74), and
`test/elia_web/live/chat_list_test.exs` (naming a chat by hand from its row —
TITLE-8, UI-104).
