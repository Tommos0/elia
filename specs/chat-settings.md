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
while typing.

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
  (COMPACT-24) — so a change made on the chat page or in another tab shows up
  here too, and vice versa.
- **CSET-4** A change made on the page applies to the chat at the moment it is
  made: it is the same session the chat page uses (SESS-1), so the next turn,
  the next tool call or the transcript follows it. Nothing on the page starts a
  turn.
- **CSET-5** The page has one section per kind of setting, each rendering the
  control that used to sit in the composer, with the ids the chat UI spec gives
  it: **Model** (the picker of MODEL-9 to MODEL-13), **Auto-approve** (the
  button, popover and switches of UI-38 to UI-42), **Jail** (the switch of
  UI-67 and UI-68), **Limits** (LIMIT-6) and **Context** (the chat's compaction
  options of COMPACT-9).
- **CSET-6** Every control that changes a chat's saved value does so through the
  session (SESS-14, SESS-16, SESS-30, LIMIT-2), so a chat with no messages yet
  is not written to disk by a change made here: the value lives in the running
  session and is saved with the chat's first message.
- **CSET-7** Each numeric setting is set in a form with a Save button, so a
  half-typed number is never a setting, and an invalid one is rejected with a
  message (`#settings-error`) instead of changing the chat (LIMIT-7,
  COMPACT-30). A setting that is on or off is a switch that applies the moment
  it is clicked, like the jail switch and the auto-approve switches
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
- **CSET-10** The Focus view toggle (UI-60), the Compact button (UI-54) and the
  deps-sync indicator (UI-70) stay in the composer: they act on the transcript
  the user is reading, not on the chat's saved settings.

## Out of scope

- Changing a chat's project (PROJ-9) after it is started: its workspace is its
  project's (PROJ-12).
- A per-chat choice of skills (they come from the project, PROJ-15, LOOP-17) and
  per-chat model request fields such as reasoning effort or an output-token cap
  (`config :elia, Elia.LLM.Anthropic`): both are candidates for this page, in a
  later change.

## Implementation

`EliaWeb.ChatSettingsLive` (the page, which the model picker, the auto-approve
picker and the jail switch move to), `EliaWeb.ChatLive` (the settings link and
the jail warning), `EliaWeb.Router`.

## Tests

`test/elia_web/live/chat_settings_test.exs` (the page, its sections, CSET-1 to
CSET-7), `test/elia_web/live/model_picker_test.exs`,
`test/elia_web/live/auto_approve_test.exs` and
`test/elia_web/live/jail_test.exs` (the moved controls),
`test/elia_web/live/chat_live_test.exs` (the composer toolbar, CSET-8 to
CSET-10).
