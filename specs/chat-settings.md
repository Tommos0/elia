# Chat settings

Status: Implemented

Every per-chat switch, limit and option lives on the chat's own settings page,
`/c/<id>/settings`, rather than in the chat composer. The composer row held the
model picker, the auto-approve button and the jail switch on every screen and in
every chat, whether or not the user ever touched them, and it crowded the
transcript on a phone. Each of those belongs to one chat and to no other, so
each has a home on that chat's settings page, together with the settings the
composer never showed at all (turn limits, [LIMIT](turn-limits.md), and the
chat's compaction options, COMPACT-9). The chat page keeps one way in: the
composer's chat menu (UI-97) shows the model in use, and holds the single entry
that leads to that page. The page is a detour from the conversation, so its
single Save goes back to the chat when the chat accepts the values (CSET-11),
where they show up; so does the Compact button (CSET-12).

The agent can read them as well: the `get_chat_settings` tool (CSET-14) reports
what applies to the chat it runs in, so it can answer "which model am I, and
what are my limits?" from the conversation rather than by asking.

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
  session's snapshot (SESS-7), and follows the chat's own events — `{:settings,
  settings}` (SESS-41, which carries the model, auto-approval, jail, limits and
  effort alike) and `{:compaction, state}`
  (COMPACT-24) — so a change made on the chat
  page or in another tab shows up here too, and vice versa.
- **CSET-4** A change made on the page applies to the chat at the moment it is
  made: it is the same session the chat page uses (SESS-1), so the next turn,
  the next tool call or the transcript follows it. Nothing on the page starts a
  turn.
- **CSET-5** The page has one section per kind of setting, each rendering the
  control that used to sit in the composer, with the ids the chat UI spec gives
  it: **Model** (the picker of MODEL-9 to MODEL-13, and the chat's reasoning
  effort, CSET-13), **Auto-approve** (the button, popover and switches of UI-38
  to UI-42), **Jail** (the switch of UI-67 and UI-68), **Network** (the mode
  control and, in allowlist mode, the chat's own host list of NET-38 and the
  project's of NET-22 to NET-24),
  **Limits** (LIMIT-6) and **Context** (the chat's compaction options of
  COMPACT-9 and the "Compact" button of UI-54, COMPACT-10).
  *Changed:* the page gained the Network section, whose controls NET-22 to
  NET-24 and NET-38 give.
- **CSET-6** Every control that changes a chat's saved value does so through the
  session (SESS-14, SESS-16, SESS-30, LIMIT-2), so a chat with no messages yet
  is not written to disk by a change made here: the value lives in the running
  session and is saved with the chat's first message.
- **CSET-7** Every numeric setting on the page is set in **one** form
  (`#settings-form`) with **one** Save button (`#save-settings`), which saves
  them all: the turn limits (LIMIT-6) and the compaction options (COMPACT-30) of
  the Limits and Context sections alike. A half-typed number is never a setting.
  *Changed:* the form used to save the Network section's host list too; the
  entries a chat names of its own have a Save of their own in that section
  (NET-38), and its project's are changed on the projects page
  (NET-24, PROJ-50).
  The save is all or nothing: a value that isn't one (LIMIT-7, COMPACT-30)
  changes nothing — no limit and no option — and the page shows the message for
  the first bad value (`#settings-error`), keeping what was typed so it can be
  corrected. A setting that is on or off is a switch that applies the moment it
  is clicked, like the jail switch and the auto-approve switches
  (UI-42, UI-67), and says its state in words.

### The chat page

- **CSET-8** The composer toolbar no longer holds the model picker, the
  auto-approve button or the jail switch: the chat's settings are one entry of
  the composer's chat menu (UI-97), a "Chat settings" link
  (`#chat-settings-link`) to `/c/<id>/settings`, and the menu shows the model
  in use above it as text — the selected model's name (`#chat-settings-model`)
  and its provider badge — so the click that used to open the picker now leads
  to where the picker lives. *Changed:* the model's name used to sit in the
  toolbar itself, in the link to the page, so what was answering was visible
  while typing; the menu holds it now (UI-97).
- **CSET-9** While a chat's jail is off, or the host has no jail at all, the
  chat page still says so in its composer toolbar, beside the chat menu's
  trigger (`#jail-warning`, `#jail-unavailable`) and never inside the menu —
  which is shut most of the time — as ISOL-17 and UI-68 require: the warning
  belongs where commands run, and in sight.
- **CSET-10** The Focus view toggle (UI-60) stays in the composer toolbar,
  outside the chat menu (UI-97): it acts on the transcript the user is reading,
  not on the chat's saved settings.
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
  "Default" is the way back to). The page follows the chat's `{:settings,
  settings}` event (CSET-3), so a change made in another tab shows up here.

### Reading them, for the agent

- **CSET-14** The built-in `settings` skill (`Elia.Skills.Settings`, listed in
  the `builtin` config, SKILL-7) carries one tool, `get_chat_settings`, which
  takes no input and reports the settings of the chat it runs in — in a
  sub-task too, where they are that child's own (LIMIT-5, ISOL-18). It answers
  with the chat's `id`, the project it belongs to (PROJ-9), its own title,
  `nil` when it has none (SESS-33, TITLE-1), and whether it is marked done
  (SESS-35, DONE-1).
- **CSET-15** The tool reads the chat's running session, not its saved file
  (SESS-7, SESS-41), so a setting is reported as it stands at that moment: one
  changed on the settings page, in another tab or by a tool (CSET-4) shows up
  in the next call, and a chat that has never been saved reports its settings
  all the same (CSET-6, SESS-14). It reads and changes nothing — no setting, no
  turn, no save — and never needs approval (APPR-7). A call with no chat to
  read is an error result.
- **CSET-16** The tool reports the settings the chat's page holds (CSET-5), as
  one JSON object whose entries are one per kind of setting — `model`,
  `effort`, `auto_approve`, `jail`, `network`, `limits` and `compaction` —
  beside the chat's identity (CSET-14): the model in use, with its provider
  key, its model id, its display name and its context window when it is known
  (MODEL-1, CTX-7); the chat's reasoning effort (CSET-13, LLM-39); the
  auto-approved tool names (APPR-8); the jail setting (ISOL-16) and whether a
  jail can be built on this host at all (ISOL-12); the network setting, with
  its mode, the entries the chat names of its own and the ones its project
  names (NET-1, NET-36, NET-28); the four turn limits (LIMIT-1); and the chat's
  compaction options (COMPACT-9). No API key is part of it: a provider's key is
  the settings database's, never a chat's (CONF-5).
- **CSET-17** Every value reported is the one that applies, and the report says
  where it came from: the model resolves as a turn resolves it — the chat's own
  selection (MODEL-1), the stored default (MODEL-15) or the configured default
  (MODEL-2) — the effort says whether it is the chat's own or the provider's
  configured default applies (CSET-13, LLM-38), and each turn limit the chat
  can leave empty is reported with the value that applies and whether it is the
  chat's own, one it left empty standing in the loop's own default (LIMIT-1,
  LIMIT-9, LOOP-16).

## Out of scope

- Changing a chat's project (PROJ-9) after it is started: its workspace is its
  project's (PROJ-12).
- Reading or changing another chat's settings: the tool reports the chat it
  runs in, and one chat's settings are set from its own page (CSET-1, LIMIT-5).
- Changing a setting with a tool: `get_chat_settings` only reads them, so a
  setting is set on the page (CSET-5) or by the tool that owns it (TITLE-5,
  WD-1).
- What the chat is doing rather than what it is set to — its context size, what
  the last request spent, and its compaction state — which the context
  indicator and the transcript report (CTX-1, CTX-6, COMPACT-24).
- A per-chat choice of skills (they come from the project, PROJ-15, LOOP-17) and
  per-chat model request fields other than reasoning effort — such as an
  output-token cap (`config :elia, Elia.LLM.Anthropic`) — which is a candidate
  for this page in a later change.

## Implementation

`EliaWeb.ChatSettingsLive` (the page, which the model picker, the auto-approve
picker, the jail switch and the "Compact" button move to),
`EliaWeb.ChatLive` (the settings link and the jail warning),
`EliaWeb.ProjectsLive` (a project's allowlist, which the Network section links
to), `EliaWeb.Router`, `Elia.Skills.Settings` (the tool that reads them,
CSET-14).

## Tests

`test/elia_web/live/chat_settings_test.exs` (the page, its sections, CSET-1 to
CSET-7, CSET-11 to CSET-13), `test/elia_web/live/network_test.exs` (the Network
section, NET-11, NET-22 to NET-25, NET-32, NET-38),
`test/elia_web/live/projects_live_test.exs` (a project's allowlist field,
PROJ-50), `test/elia_web/live/model_picker_test.exs`,
`test/elia_web/live/auto_approve_test.exs` and
`test/elia_web/live/jail_test.exs` (the moved controls),
`test/elia_web/live/chat_live_test.exs` and
`test/elia_web/live/chat_menu_test.exs` (the composer toolbar, CSET-8 to
CSET-10), `test/elia_web/live/compaction_test.exs` (the moved Compact button,
UI-54),
`test/elia/skills/settings_test.exs` (`get_chat_settings`: what it reports,
where each value comes from, and that it reads the chat it runs in, CSET-14 to
CSET-17).
