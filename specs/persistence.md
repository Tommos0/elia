# Conversation persistence

Status: Implemented

Chats are saved to disk so they survive restarts and can be listed and
reopened.

## Requirements

- **STORE-1** A chat is saved to `.elia/sessions/<id>.term` as an Erlang term
  `%{version: 1, messages: [...], updated_at: DateTime}`, plus `model: selection`
  when the chat has its own model selection (MODEL-1), plus
  `auto_approve: [tool name]` when the chat auto-approves any tool (APPR-8);
  files without these load as having none. Terms are used instead of JSON so provider raw blocks are
  kept exactly (LLM-6).
- **STORE-2** Writes are atomic: the data goes to a `.tmp` file, which is then
  renamed into place.
- **STORE-3** Loading a chat that is missing, unreadable or corrupt returns
  an empty history. Decoding is safe and never creates new atoms; all of
  Elia's modules are loaded first, so atoms a saved chat uses exist even
  right after a restart, when modules haven't been loaded yet.
- **STORE-4** Valid chat ids are 1–64 characters from `[A-Za-z0-9_-]`. Save
  only accepts valid ids; load and delete reject invalid ones.
- **STORE-5** New ids are 12-character URL-safe random strings.
- **STORE-6** Listing returns up to N chats as `%{id, title, updated_at}`,
  newest first by file modification time.
- **STORE-7** A chat's title is its first user message that isn't a harness
  message, cut to 60 characters, or "New chat" if there is none.
- **STORE-8** `.elia/` is git-ignored and can't be written by the file tools
  (WS-3).
- **STORE-9** Loading a chat's model selection returns `nil` when the chat is
  missing, unreadable, corrupt or has none.
- **STORE-10** Each listed chat also carries `description`: the same source
  text as the title (STORE-7) but cut to 1000 characters instead of 60, or
  "New chat" if there is none.

- **STORE-11** A saved chat also records `created_at: DateTime`, set the first
  time it is saved and kept unchanged by later saves. Files saved before this
  field existed use their file modification time as the start date.
- **STORE-12** Each listed chat carries `created_at`, and listing orders
  chats by it, newest first (replacing the modification-time order of
  STORE-6; `updated_at` is still returned).
- **STORE-13** Loading a chat replaces invalid UTF-8 in its text and tool
  results as in LLM-32, so a chat saved with such bytes can still be opened.
  Provider raw blocks stay exact (LLM-6).

- **STORE-14** `save/3` takes `auto_approve:` (a list of tool-name strings) and
  stores it only when the list isn't empty, so turning the last tool off
  removes it from the file.
- **STORE-15** Loading a chat's auto-approved tools returns `[]` when the chat
  is missing, unreadable, corrupt or has none. The set a new chat starts with
  (APPR-14) is the session's, not the store's: it reaches the file when the chat
  is saved with it (STORE-14).

- **STORE-25** `save/3` takes `jail:` (a boolean) and stores it only when it is
  `false`, so a chat that keeps the default (`true`, ISOL-16) carries no entry
  and turning the jail back on removes it from the file.
- **STORE-26** `load_jail/1` returns `true` when the chat is missing,
  unreadable, corrupt or has no value, since the jail is on by default
  (ISOL-16).

- **STORE-16** `save/3` takes `task:` (a map) and stores it as `task` with the
  chat. It holds the metadata of a chat started by `spawn_task`: `parent_id`,
  `title`, `brief`, `started_at`, `status` (`"running"`, `"done"`, `"blocked"`,
  `"failed"`, `"unfinished"` or `"cancelled"`), `start_commit` and, once
  finished, `result`.
  `load_task/1` returns it, or `nil` when the chat is missing, unreadable,
  corrupt or has none.
- **STORE-17** A listed chat that has task metadata also carries `parent_id`
  and `task_status`, and its `title` is the task's title (STORE-7 doesn't
  apply). A task saved as `"running"` whose child isn't the active one
  (SUBTASK-11) is listed as `"interrupted"`, as its session was lost.
- **STORE-18** Task metadata also holds `parent_call_id`, the id of the parent's
  `spawn_task` call (SUBTASK-15), and a listed task chat carries it too.
  `Elia.Store.children/1` (parent chat id) returns the listed entries
  (STORE-17) of the task chats whose `parent_id` it is, oldest first, with no
  limit, so the parent's page can link each `spawn_task` call to its child.

- **STORE-19** `save/3` takes `project:` (a project id) and stores it as
  `project_id`; `load_project/1` returns it, or `nil` when the chat is missing,
  unreadable, corrupt or has none (PROJ-9).
- **STORE-20** Each listed chat carries `project_id`, or `nil` when it has none.
- **STORE-21** `save/3` takes `compaction:` (the chat's compaction state, a map,
  COMPACT-24) and stores it as `compaction`, so the summary, the ledger, the pin
  set, how far the ladder has gone and the chat's own compaction options
  outlive a restart. `load_compaction/1` returns it, or `nil` when the chat is
  missing, unreadable, corrupt or has none.

- **STORE-22** Starting a chat from the UI (`/chats` when it has no chat to
  resume (UI-77), `/p/<id>/new`, PROJ-26, or the dashboard's "New chat"
  button, DASH-4) saves it at once, with no messages
  and its project (STORE-19), so it
  is listed while it is still empty: its title is "New chat" (STORE-7) and its
  `created_at` is the moment it was started (STORE-11), which its later saves
  keep. Starting a session for an id that is only opened (`/c/<id>`, UI-2)
  writes nothing until it has a message (SESS-14).

- **STORE-23** `Elia.Store.delete/1` removes a valid chat's saved file and its
  worktree (`Elia.Deploy.remove_worktree/1`, DEPLOY-10) and returns `:ok`,
  whether or not a file exists yet; an invalid id (STORE-4) removes nothing and
  returns `{:error, :invalid_id}`. Deleting a chat never deletes other chats: a
  parent's task chats and a task chat's parent are left saved (UI-66).
- **STORE-24** `Elia.Store.exists?/1` reports whether a valid id has a saved
  chat file, without decoding it; it is `false` for an invalid id and for an id
  with no file.

- **STORE-27** `save/3` takes `limits:` (the chat's turn limits, LIMIT-1) and
  stores it as `limits`, with only the values that aren't the default, so a chat
  that sets none carries no entry and one that clears a limit drops it from the
  file.
- **STORE-28** `load_limits/1` returns the chat's saved limits, merged over the
  defaults (LIMIT-1, LIMIT-9: no step limit of its own, no time budget,
  `pause_on_limit` on), so it answers like LIMIT-1 for a chat that is missing,
  unreadable, corrupt or has none.

- **STORE-30** `save/3` takes `turn:` (a map with the turn's `id` and
  `started_at`) and stores it as `turn`; a save that doesn't give one writes no
  `turn` entry, so the key is gone from the file as soon as the turn ends
  (INTR-1). `load_turn/1` returns it, or `nil` when the chat is missing,
  unreadable, corrupt or has none (INTR-2).

- **STORE-31** Each listed chat carries `interrupted`: `true` when its saved
  chat holds a `turn` (STORE-30) and no session for it is running in this app
  instance (`Elia.Agent.live?/1`, SESS-32) — the app restarted while that turn
  ran (INTR-2) — and `false` otherwise. A task chat keeps its own listed status
  (STORE-17) as well.

- **STORE-29** `latest/0` returns the most recently started listed chat
  (STORE-12) that isn't a task chat (STORE-17) and isn't done (STORE-35,
  DONE-10), as a listed entry, or `nil`
  when there is none. It looks at every saved chat, not only the first page of
  `list/1`, so a run of task chats doesn't hide the chat to resume (UI-77), and
  it skips an entry whose id isn't valid (STORE-4), so `/chats` never sends the
  browser to a chat its own route rejects (UI-2). The dashboard uses it for its
  "Continue" card (DASH-3).

- **STORE-32** `save/3` takes `title:` (the chat's own title, TITLE-1) and
  stores it as `title` only when it isn't blank, so an empty one drops the
  entry from the file; `load_title/1` returns it, or `nil` when the chat is
  missing, unreadable, corrupt or has none.
- **STORE-33** A listed chat's `title` is its stored title (STORE-32) when it
  has one and the STORE-7 derivation otherwise, so a title that isn't a prefix
  of the first user message is listed like any other and a chat that never got
  one is unchanged; its `description` is still the derivation (STORE-10), and a
  task chat is still listed under its task title (STORE-17).
  `Elia.Store.chat_title/1` (chat id) answers the same way for a view that has
  an id and not a listing: the stored title, else the derivation from its saved
  history, else "New chat".

- **STORE-34** `save/3` takes `done:` (a boolean) and stores it as `done: true`
  only when it is `true`, so reopening a chat drops the entry from the file
  (DONE-1, DONE-9); `load_done/1` returns `false` when the chat is missing,
  unreadable, corrupt or has no value, since a chat is open by default.
- **STORE-35** Each listed chat carries `done`, a boolean like `interrupted`
  (STORE-31): `true` when the chat is marked done (DONE-1) and `false`
  otherwise, so a chat nobody marked is listed as open. A task chat still
  carries it, but its own listed status is its task's (STORE-17) and that is
  what is shown (DONE-3).

## Implementation

`Elia.Store`, `Elia.Agent.new_id/0`.

## Tests

`test/elia/agent_test.exs` (history survives a restart),
`test/elia/store_test.exs` (STORE-29, the chat to resume, including one that is
done),
`test/elia/chat_done_test.exs` (the saved flag and the listing, STORE-34,
STORE-35),
`test/elia/chat_titles_test.exs` (the stored title and the listing's
precedence, STORE-32, STORE-33),
`test/elia_web/live/page_title_test.exs`,
`test/elia_web/live/chat_live_test.exs` (a started chat is saved and listed,
STORE-22; `/chats` resumes the most recent chat, UI-77),
`test/elia_web/live/dashboard_test.exs` (the "Continue" card, DASH-3).
