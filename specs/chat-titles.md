# Chat titles

Status: Draft

A chat's title is what its sidebar row, its page title and the chat list show,
and today it is always derived from the first user message, cut to 60
characters (STORE-7): a chat that opens with a long request — a spec, a bug
report, a pasted stack trace — is listed under an arbitrary prefix of it. This
spec lets a chat carry a title of its own, written by the agent from the request
it has in front of it, and keeps the derivation as the fallback, so a chat
without one is exactly as it is today.

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
  (UI-4, UI-74), the page title (UI-3), the chat settings header — in place of
  the STORE-7 derivation from the first user message. A chat without one lists
  and displays exactly as before, so every chat saved before this feature, and
  every chat the agent never names, is unchanged. The chat's `description`
  (STORE-10) is not affected: hovering a row (UI-33) still shows the first user
  message.
- **TITLE-2** A title is trimmed, its runs of whitespace collapsed to single
  spaces, and cut to 60 characters (the cut STORE-7 uses), so a long,
  multi-line or padded one can't break a sidebar row or a page title. A title
  that is blank after trimming is no title at all: it is refused (TITLE-6) and
  never stored (STORE-32), so no chat is ever listed under an empty title.
- **TITLE-3** A task chat is named after its task (STORE-17) and ignores any
  stored title: setting one is refused in a sub-task chat (TITLE-6), and a
  title stored on a chat that then became a sub-task is never shown.

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
- **TITLE-6** `set_title` refuses a blank title (TITLE-2) and refuses a chat
  whose session has task metadata (TITLE-3), both as an error result to the
  model, naming the reason; nothing is saved and nothing is broadcast.

### The trigger

- **TITLE-7** A title is set only by the agent's own tool call inside a running
  turn (TITLE-5). The harness never calls a provider for a title, and no timer,
  turn count or end-of-turn hook sets, refreshes or re-derives one. A chat named
  only by the STORE-7 derivation (TITLE-1) is therefore a normal outcome, not a
  failure, and no turn is made slower or more expensive by this feature.

## Out of scope

- Renaming a chat by hand in the UI. A stored title makes that easy to add
  later, but nothing in the sidebar or the settings page edits a title now.
- A harness-side provider call that generates a title, and any timer or
  turn-count trigger (TITLE-7). If compliance ever proves poor, this is the
  upgrade, and it writes the same stored field.
- Re-titling a chat as its subject shifts, beyond a second `set_title` the agent
  itself chooses to make (TITLE-5).

## Implementation

`Elia.Store` (the saved field, the listing's precedence, the accessor for a
view with an id), `Elia.Skills.Titles` (the skill and its `set_title` tool),
`Elia.Agent` and `Elia.Agent.Session` (`set_title/2`, saving, the `{:title,
title}` event, the snapshot field), `EliaWeb.ChatLive` (the page title, the
sidebar row, the tool card), `config/config.exs` (the built-in skill list).

## Tests

`test/elia/chat_titles_test.exs` (the shape and the fallback, saving and
loading, the listing's precedence, `set_title` end to end with its two
refusals, TITLE-1 - TITLE-7), `test/elia_web/live/chat_title_test.exs` (the page
title and the row, `{:title, title}` mid-turn, the card's summary, UI-74).
