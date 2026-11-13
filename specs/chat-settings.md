# Chat settings

Status: Draft

Every per-chat switch, limit and option lives on the chat's own settings page,
`/c/<id>/settings`, rather than in the chat composer. The composer row held the
model picker, the auto-approve button and the jail switch on every screen and in
every chat, whether or not the user ever touched them, and it crowded the
transcript on a phone. Each of those belongs to one chat and to no other, so
each has a home on that chat's settings page, together with the settings the
composer never showed at all (turn limits, [LIMIT](turn-limits.md), and the
chat's compaction options, COMPACT-9). The chat page keeps one control that
leads there, carrying the model's name, so what is answering is still visible
while typing. The page is a detour from the conversation, so its single Save
goes back to the chat when the chat accepts the values (CSET-11), where they
show up; so does the Compact button (CSET-12).

## Requirements

### The page

- **CSET-1** `GET /c/<id>/settings` opens that chat's settings page. An id that
  fails `Elia.Store.valid_id?/1` redirects to `/` (UI-2). The page starts the
  chat's session when needed (SESS-1, UI-2) and writes no chat file of its own.
- **CSET-2** The page shows the chat's title (STORE-7) and its project
  (PROJ-9; a chat with no project is in the default one, PROJ-8), and a link
  back to the chat (`#chat-settings-back`). Its page title (UI-3) is the chat's
  title.
- **CSET-3** Every control on the page is right on first render, from the
  session's snapshot (SESS-7), and follows the chat's own events — `{:model,
  selection}` (MODEL-1), `{:auto_approve, names}` (SESS-16), `{:jail, on?}`
  (SESS-30), `{:limits, limits}` (LIMIT-2), `{:compaction, state}`
  (COMPACT-24), `{:effort, effort}` (SESS-40) — so a change made on the chat
  page or in another tab shows up here too, and vice versa.
- **CSET-4** A change made on the page applies to the chat at the moment it is
  made: it is the same session the chat page uses (SESS-1), so the next turn,
  the next tool call or the transcript follows it. Nothing on the page starts a
  turn.
- **CSET-5** The page has one section per kind of setting, each rendering the
  control that used to sit in the composer, with the ids the chat UI spec gives
  it: **Model** (the picker of MODEL-9 to MODEL-13, and the chat's reasoning
  effort, CSET-13), **Auto-approve** (the button, popover and switches of UI-38
  to UI-42), **Jail** (the switch of UI-67 and UI-68), **Limits** (LIMIT-6) and
  **Context** (the chat's compaction options of COMPACT-9 and the "Compact"
  button of UI-54, COMPACT-10).
- **CSET-6** Every control that changes a chat's saved value does so through the
  session (SESS-14, SESS-16, SESS-30, LIMIT-2), so a chat with no messages yet
  is not written to disk by a change made here: the value lives in the running
  session and is saved with the chat's first message.
- **CSET-7** Every numeric setting on the page is set in **one** form
  (`#settings-form`) with **one** Save button (`#save-settings`), which saves
  them all: the turn limits (LIMIT-6) and the compaction options (COMPACT-30) of
  the Limits and Context sections alike. A half-typed number is never a setting.
  The save is all or nothing: a value that isn't one (LIMIT-7, COMPACT-30)
  changes nothing — no limit and no option — and the page shows the message for
  the first bad value (`#settings-error`), keeping what was typed so it can be
  corrected. A setting that is on or off is a switch that applies the moment it
  is clicked, like the jail switch and the auto-approve switches
  (UI-42, UI-67), and says its state in words.

### The chat page

- **CSET-8** The composer toolbar no longer holds the model picker, the
  auto-approve button or the jail switch: it has a "Chat settings" link
  (`#chat-settings-link`) to `/c/<id>/settings`, labelled with the selected
  model's name (`#chat-settings-model`) and its provider badge, so the model in
  use is still visible while typing, and the click that used to open the picker
  now leads to where the picker lives.
- **CSET-9** While a chat's jail is off, or the host has no jail at all, the
  chat page still says so next to that link (`#jail-warning`,
  `#jail-unavailable`), as ISOL-17 and UI-68 require: the warning belongs where
  commands run, not only on a settings page.
- **CSET-10** The Focus view toggle (UI-60) stays in the composer: it acts on
  the transcript the user is reading, not on the chat's saved settings.
- **CSET-11** A Save (`#save-settings`) the chat accepts (CSET-7) returns to the
  chat (`/c/<id>`): the settings show up there (CSET-4) and the settings page
  was a detour. A save the chat rejects leaves the user on the page, with the
  message (`#settings-error`) and the values as typed, to correct them.
- **CSET-12** The "Compact" button (UI-54) compacts the chat and returns to it
  (`/c/<id>`), so the user sees the result in the transcript. A chat that is
  mid-turn keeps the user on the page with the error (UI-54).

- **CSET-13** The Model section also holds this chat's reasoning effort
  (LLM-39): a row of buttons — `#effort-default`, `#effort-low`,
  `#effort-medium`, `#effort-high` — with the chat's current choice marked,
  each setting it the moment it is clicked (CSET-4) through the session
  (SESS-40), and a line (`#effort-state`) saying what applies in words: the
  chat's own effort, or that the provider's configured default applies (which
  "Default" is the way back to). The page follows the chat's `{:effort, effort}`
  event (CSET-3), so a change made in another tab shows up here.

## Out of scope

- Changing a chat's project (PROJ-9) after it is started: its workspace is its
  project's (PROJ-12).
- A per-chat choice of skills (they come from the project, PROJ-15, LOOP-17) and
  per-chat model request fields other than reasoning effort — such as an
  output-token cap (`config :elia, Elia.LLM.Anthropic`) — which is a candidate
  for this page in a later change.

## Implementation

`EliaWeb.ChatSettingsLive` (the page, which the model picker, the auto-approve
picker, the jail switch and the "Compact" button move to),
`EliaWeb.ChatLive` (the settings link and the jail warning), `EliaWeb.Router`.

## Tests

`test/elia_web/live/chat_settings_test.exs` (the page, its sections, CSET-1 to
CSET-7, CSET-11 to CSET-13), `test/elia_web/live/model_picker_test.exs`,
`test/elia_web/live/auto_approve_test.exs` and
`test/elia_web/live/jail_test.exs` (the moved controls),
`test/elia_web/live/chat_live_test.exs` (the composer toolbar, CSET-8 to
CSET-10), `test/elia_web/live/compaction_test.exs` (the moved Compact button,
UI-54).
