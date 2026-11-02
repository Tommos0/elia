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
  is missing, unreadable, corrupt or has none.

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

- **STORE-22** Starting a chat from the UI (`/` or `/p/<id>/new`, UI-1,
  PROJ-26) saves it at once, with no messages and its project (STORE-19), so it
  is listed while it is still empty: its title is "New chat" (STORE-7) and its
  `created_at` is the moment it was started (STORE-11), which its later saves
  keep. Starting a session for an id that is only opened (`/c/<id>`, UI-2)
  writes nothing until it has a message (SESS-14).

## Implementation

`Elia.Store`, `Elia.Agent.new_id/0`.

## Tests

`test/elia/agent_test.exs` (history survives a restart),
`test/elia/store_test.exs`,
`test/elia_web/live/page_title_test.exs`,
`test/elia_web/live/chat_live_test.exs` (a started chat is saved and listed,
STORE-22).
