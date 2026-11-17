# Conversation persistence

Status: Implemented

Chats are saved to disk so they survive restarts and can be listed and
reopened. A saved chat's shape is stated in one place — the table under STORE-1
(STORE-40) — and the fields a listed chat carries in one place — the table under
STORE-6 (STORE-41). A key or a field added later is a row there, and each one's
own save or load rule is the requirement its row cites. The requirements below
are grouped by topic: the file, saving a chat, listing chats, the per-chat
values a save can carry, deleting a chat, and the two tables themselves.

## Requirements

### The file

- **STORE-1** A chat is saved to `.elia/sessions/<id>.term` as an Erlang term
  holding the keys of the table below and no others; each key's own save and
  load rule is the requirement its row cites. Terms are used instead of JSON so
  provider raw blocks are kept exactly (LLM-6).

  | Key | Type | When it is written | Dropped at its default |
  | --- | --- | --- | --- |
  | `version` | `1` | every save | no — every save writes it |
  | `messages` | a list of `Elia.LLM.Message` | every save | no — every save writes it |
  | `created_at` | `DateTime` | the chat's first save, kept unchanged by every later one (STORE-11) | no — every save writes it |
  | `updated_at` | `DateTime` | every save | no — every save writes it |
  | `model` | a map: the chat's model selection | when the chat has a model selection of its own (MODEL-1) | yes — a chat with none carries no entry (STORE-9) |
  | `auto_approve` | a list of tool-name strings | when the chat auto-approves a tool (STORE-14, APPR-8) | yes — an empty list is not written (STORE-14) |
  | `project_id` | a project id (a string) | when the chat belongs to a project (STORE-19, PROJ-9) | yes — `nil` is not written (STORE-19) |
  | `task` | a map: the sub-task metadata of a chat started by `spawn_task` (STORE-16) | when the chat is a sub-task chat | yes — a chat that is no sub-task carries no entry (STORE-16) |
  | `compaction` | a map: the chat's compaction state (STORE-21, COMPACT-24) | when the chat has compaction state | yes — a chat with none carries no entry (STORE-21) |
  | `jail` | `false` | only when the chat's jail is off (STORE-25) | yes — the jail is on by default (ISOL-16) |
  | `limits` | a map of only the limits that aren't the default (STORE-27, LIMIT-1) | when the chat sets a limit of its own | yes — a chat that sets none carries no entry (STORE-27) |
  | `effort` | `"low"`, `"medium"` or `"high"` | when the chat has a reasoning effort of its own (STORE-37, LLM-39) | yes — the configured default is not written (LLM-38) |
  | `title` | a string | when the chat's own title isn't blank (STORE-32, TITLE-1) | yes — a blank or missing title is not written (STORE-32) |
  | `turn` | a map: the turn's `id` and `started_at`, and `resumed: true` for a turn an automatic resume started (STORE-30, RESUME-5) | while a turn is in flight | yes — the turn's end takes the entry off the file (STORE-30) |
  | `done` | `true` | only when the chat is marked done (STORE-34) | yes — a chat is open by default (STORE-34) |
  | `cwd` | an absolute path (a string) | when the chat's working directory isn't its workspace root (STORE-46, WD-7) | yes — a chat working in its workspace root carries no entry (STORE-46) |

- **STORE-2** Writes are atomic: the data goes to a temporary file of that
  write's own, which is flushed to disk and then renamed into place. Saves of
  one chat that run at the same time each leave the file whole — one of them,
  whichever renames last — and never a truncated or mixed file, nor one that
  fails because another save renamed its temporary file away. A write that fails
  leaves no temporary file behind, and a temporary file a crash left behind is
  never read or listed as a chat. *Changed:* every save of a chat used to share
  the one `<id>.term.tmp`.
- **STORE-3** Loading a chat that is missing, unreadable or corrupt returns
  an empty history. Decoding is safe and never creates new atoms; all of
  Elia's modules are loaded first, so atoms a saved chat uses exist even
  right after a restart, when modules haven't been loaded yet.
- **STORE-4** Valid chat ids are 1–64 characters from `[A-Za-z0-9_-]`. Save
  only accepts valid ids; load and delete reject invalid ones.
- **STORE-5** New ids are 12-character URL-safe random strings.
- **STORE-8** `.elia/` is git-ignored and can't be written by the file tools
  (WS-3).
- **STORE-13** Loading a chat replaces invalid UTF-8 in its text and tool
  results as in LLM-32, so a chat saved with such bytes can still be opened.
  Provider raw blocks stay exact (LLM-6).

### Saving a chat

- **STORE-11** A saved chat also records `created_at: DateTime`, set the first
  time it is saved and kept unchanged by later saves. Files saved before this
  field existed use their file modification time as the start date.
- **STORE-22** Starting a chat from the UI (`/chats` when it has no chat to
  resume (UI-77), `/p/<id>/new`, PROJ-26, or the dashboard's "New chat"
  button, DASH-4) saves it at once, with no messages
  and its project (STORE-19), so it
  is listed while it is still empty: its title is "New chat" (STORE-7) and its
  `created_at` is the moment it was started (STORE-11), which its later saves
  keep. Starting a session for an id that is only opened (`/c/<id>`, UI-2)
  writes nothing until it has a message (SESS-14).

### Listed chats

- **STORE-6** Listing returns up to the number of chats it is asked for, in
  STORE-12's order (newest started first), each one a listed entry carrying the
  fields of the table below.

  | Field | What it holds | Which chats carry it | The requirement it comes from |
  | --- | --- | --- | --- |
  | `id` | the chat's id: the name of its file without `.term` | any | STORE-4, STORE-5 |
  | `title` | the chat's own title (STORE-32) when it has one, else its first user message cut to 60 characters (STORE-7), else "New chat" | any | STORE-7, STORE-32, STORE-33 |
  | `description` | the same source text as the title, cut to 1000 characters instead of 60, or "New chat" (STORE-10) | any | STORE-10 |
  | `created_at` | when the chat was started (STORE-11) | any | STORE-11, STORE-12 |
  | `updated_at` | when the chat was last saved (STORE-1) | any | STORE-1, STORE-12 |
  | `project_id` | the id of the project the chat belongs to, or `nil` (STORE-20) | any | STORE-20 |
  | `interrupted` | whether a restart cut the chat's turn short (STORE-31) | any | STORE-31 |
  | `done` | whether the chat is marked done (STORE-35) | any | STORE-35 |
  | `parent_id` | the id of the chat that spawned it (STORE-17) | task only | STORE-17 |

- **STORE-7** A chat's title is its first user message that isn't a harness
  message, cut to 60 characters, or "New chat" if there is none.
- **STORE-10** Each listed chat also carries `description`: the same source
  text as the title (STORE-7) but cut to 1000 characters instead of 60, or
  "New chat" if there is none.
- **STORE-12** Each listed chat carries `created_at`, and listing orders
  chats by it, newest first (`updated_at` is still returned; the order was a
  chat's file modification time before this change).
- **STORE-17** A listed chat that has task metadata also carries `parent_id`, the
  id of the chat that spawned it (STORE-16). Its `title` is its own (STORE-33,
  TITLE-3) and its status the status any chat's is (STORE-31, UI-59), so a
  sub-task is listed as the ordinary chat it is. *Changed:* the task status a
  task chat used to be listed under, and the derivation a listing needed to work
  out whether a running task still ran, went with the task status itself
  (SUBTASK-33), and the task's own title it was listed under went with the
  task-only title rule (TITLE-3).
- **STORE-18** `Elia.Store.children/1` (parent chat id) returns the listed entries
  (STORE-17) of the task chats whose `parent_id` it is, oldest first, with no
  limit: what `list_chats`'s `children` filter reads (HIST-2), and what a parent
  stopped ends the turns of (SESS-22). *Changed:* the task metadata's
  `parent_call_id`, which no longer exists (STORE-16), went with the task card it
  existed for (SUBTASK-15).
- **STORE-20** Each listed chat carries `project_id`, or `nil` when it has none.
- **STORE-29** `latest/0` returns the most recently started listed chat
  (STORE-12) that isn't a task chat (STORE-17) and isn't done (STORE-35,
  DONE-10), as a listed entry, or `nil`
  when there is none. It looks at every saved chat, not only the first page of
  `list/1`, so a run of task chats doesn't hide the chat to resume (UI-77), and
  it skips an entry whose id isn't valid (STORE-4), so `/chats` never sends the
  browser to a chat its own route rejects (UI-2). The dashboard uses it for its
  "Continue" card (DASH-3).
- **STORE-31** Each listed chat carries `interrupted`: `true` when its saved
  chat holds a `turn` (STORE-30) and no session for it is running in this app
  instance (`Elia.Agent.live?/1`, SESS-32) — the app restarted while that turn
  ran (INTR-2) — and `false` otherwise. A task chat keeps its own listed status
  (STORE-17) as well.
- **STORE-33** A listed chat's `title` is its stored title (STORE-32) when it
  has one and the STORE-7 derivation otherwise, so a title that isn't a prefix
  of the first user message is listed like any other and a chat that never got
  one is unchanged; its `description` is still the derivation (STORE-10), and a
  sub-task's title is its own like any chat's (STORE-32, TITLE-3).
  `Elia.Store.chat_title/1` (chat id) answers the same way for a view that has
  an id and not a listing: the stored title, else the derivation from its saved
  history, else "New chat".
- **STORE-35** Each listed chat carries `done`, a boolean like `interrupted`
  (STORE-31): `true` when the chat is marked done (DONE-1) and `false`
  otherwise, so a chat nobody marked is listed as open. A task chat carries it
  too, and it is shown where the task is over (DONE-2, DONE-3).
- **STORE-36** `Elia.Store.entry/1` returns one chat's listed entry — the same
  fields `list/1` gives that chat (STORE-12, STORE-17, STORE-20, STORE-31,
  STORE-33, STORE-35), derived the same way — without reading the other chats'
  files, or `nil` when the id is invalid (STORE-4) or has no saved chat
  (STORE-24). It is what a view that has one chat's id and wants its listing
  uses, rather than listing every chat to find it.
- **STORE-39** `Elia.Store.interrupted/0` returns the listed entry (STORE-12,
  STORE-31) of every saved chat whose record holds a `turn` (STORE-30) and which
  no session is running for, newest first. It reads every saved chat rather than
  one page of `list/1` (STORE-12) and skips an id that isn't valid (STORE-4) and
  a chat whose file can't be read, so a scan at boot sees the chats a restart
  cut a turn short in and not only the ones its page holds (RESUME-1).
- **STORE-45** Listing (`list/1`, `entry/1`, `latest/0`, `children/1`,
  `interrupted/0`) and the per-chat loaders (`load_meta/1`, STORE-44, and the
  `load_*` loaders it backs) decode a chat's file only when the file has changed
  since it was last decoded. A cache keeps, per chat, the file's identity — its
  inode, size and modification time — with the saved keys other than
  `messages` and the fields STORE-6 derives from the messages (its title and
  description, STORE-7, STORE-10). An entry is used only while the file's
  identity is the one it was made from, so a file written or replaced by
  anything — this session, another one, the sub-task fallback (STORE-43), another
  OS process — is decoded afresh at the next read; every save renames a new file
  into place (STORE-2), which always changes the identity. A file that is gone
  is dropped from the cache at the next listing and is never listed, and a save
  or a delete through `Elia.Store` drops its chat's entry at once. What depends
  on running state rather than on the file — whether a chat was interrupted
  (STORE-31) — is worked out at
  every listing and never cached. A listing answers exactly what it answered
  before, field for field (STORE-6, STORE-42). `load/1` always reads the
  messages from the file.

### Per-chat values

- **STORE-44** `Elia.Store.load_meta/1` returns a chat's saved keys other than
  `messages` — the rows of STORE-1's table but that one — as one map, from a
  single decode of its file (or none, STORE-45), or `nil` for an invalid id
  (STORE-4) or a chat that is missing, unreadable or corrupt. Each per-key loader
  (`load_model/1`, `load_auto_approve/1`, `load_task/1`, `load_project/1`,
  `load_compaction/1`, `load_jail/1`, `load_limits/1`, `load_effort/1`,
  `load_title/1`, `load_done/1`, `load_turn/1`) answers what `load_meta/1` holds
  for its key, with the same default and the same rule as before (STORE-9,
  STORE-15, STORE-26, STORE-28, STORE-38 and the rest), so a session that starts
  reads its chat's settings with one decode rather than one per key.
- **STORE-9** Loading a chat's model selection returns `nil` when the chat is
  missing, unreadable, corrupt or has none.
- **STORE-14** `save/3` takes `auto_approve:` (a list of tool-name strings) and
  stores it only when the list isn't empty, so turning the last tool off
  removes it from the file.
- **STORE-15** Loading a chat's auto-approved tools returns `[]` when the chat
  is missing, unreadable, corrupt or has none. The set a new chat starts with
  (APPR-14) is the session's, not the store's: it reaches the file when the chat
  is saved with it (STORE-14).
- **STORE-19** `save/3` takes `project:` (a project id) and stores it as
  `project_id`; `load_project/1` returns it, or `nil` when the chat is missing,
  unreadable, corrupt or has none (PROJ-9).
- **STORE-16** `save/3` takes `task:` (a map) and stores it as `task` with the
  chat. It holds the metadata of a chat started by `spawn_task`: `parent_id`,
  `started_at` and, once the chat is marked done, the task's `result`
  (SUBTASK-9, SUBTASK-13, SUBTASK-15). It holds no status: a chat's status is
  derived from the chat itself and never saved (UI-59, STORE-31), and a
  `status` key an earlier version wrote is ignored when the metadata is read
  (SUBTASK-34). It holds no title and no brief either: a child's title is its
  chat's own (STORE-32, TITLE-3) and its brief is the first message of its
  transcript (SUBTASK-5). *Changed:* `title`, `brief` and `start_commit` went,
  as the result's `commit` and `files` did (SUBTASK-9, SUBTASK-21); a file
  written with them is read for the keys it has, the extra ones ignored.
  `load_task/1` returns it, or `nil` when the chat is missing, unreadable,
  corrupt or has none.
- **STORE-21** `save/3` takes `compaction:` (the chat's compaction state, a map,
  COMPACT-24) and stores it as `compaction`, so the summary, the ledger, the pin
  set, how far the ladder has gone and the chat's own compaction options
  outlive a restart. `load_compaction/1` returns it, or `nil` when the chat is
  missing, unreadable, corrupt or has none.
- **STORE-25** `save/3` takes `jail:` (a boolean) and stores it only when it is
  `false`, so a chat that keeps the default (`true`, ISOL-16) carries no entry
  and turning the jail back on removes it from the file.
- **STORE-26** `load_jail/1` returns `true` when the chat is missing,
  unreadable, corrupt or has no value, since the jail is on by default
  (ISOL-16).
- **STORE-27** `save/3` takes `limits:` (the chat's turn limits, LIMIT-1) and
  stores it as `limits`, with only the values that aren't the default, so a chat
  that sets none carries no entry and one that clears a limit drops it from the
  file.
- **STORE-28** `load_limits/1` returns the chat's saved limits, merged over the
  defaults (LIMIT-1, LIMIT-9: no step limit of its own, no time budget,
  `pause_on_limit` on), so it answers like LIMIT-1 for a chat that is missing,
  unreadable, corrupt or has none.
- **STORE-37** `save/3` takes `effort:` (the chat's reasoning effort: one of
  `"low"`, `"medium"`, `"high"`, LLM-39) and stores it as `effort` only when it
  is one of those, so a chat that keeps the configured default (`nil`, LLM-38)
  carries no entry and giving the chat no effort of its own again removes the
  key from the file.
- **STORE-38** `load_effort/1` returns the chat's saved effort, or `nil` when
  the chat is missing, unreadable, corrupt or has none — `nil` meaning no
  effort of its own, so the configured default applies (LLM-38). A chat saved
  before this change has no `effort` key and is read exactly as it was, so the
  change needs no migration.
- **STORE-32** `save/3` takes `title:` (the chat's own title, TITLE-1) and
  stores it as `title` only when it isn't blank, so an empty one drops the
  entry from the file; `load_title/1` returns it, or `nil` when the chat is
  missing, unreadable, corrupt or has none.
- **STORE-30** `save/3` takes `turn:` (a map with the turn's `id` and
  `started_at`, and `resumed: true` for a turn an automatic resume started,
  RESUME-5) and stores it as `turn`; a save that doesn't give one writes no
  `turn` entry, so the key is gone from the file as soon as the turn ends
  (INTR-1). `load_turn/1` returns it, or `nil` when the chat is missing,
  unreadable, corrupt or has none (INTR-2).
- **STORE-34** `save/3` takes `done:` (a boolean) and stores it as `done: true`
  only when it is `true`, so reopening a chat drops the entry from the file
  (DONE-1, DONE-9); `load_done/1` returns `false` when the chat is missing,
  unreadable, corrupt or has no value, since a chat is open by default.
- **STORE-46** `save/3` takes `cwd:` (the chat's working directory as an
  absolute path, WD-1) and stores it as `cwd` only when it is given, so a chat
  working in its workspace root carries no entry; `load_cwd/1` returns the
  saved path, or `nil` when the chat is missing, unreadable, corrupt or has
  none, which is what a chat saved before this key existed gives (WD-7).

### Deleting a chat

- **STORE-23** `Elia.Store.delete/1` removes a valid chat's saved file and its
  worktree (`Elia.Deploy.remove_worktree/1`, DEPLOY-10) and returns `:ok`,
  whether or not a file exists yet; an invalid id (STORE-4) removes nothing and
  returns `{:error, :invalid_id}`. Deleting a chat never deletes other chats: a
  parent's task chats and a task chat's parent are left saved (UI-66).
- **STORE-24** `Elia.Store.exists?/1` reports whether a valid id has a saved
  chat file, without decoding it; it is `false` for an invalid id and for an id
  with no file.
- **STORE-43** `Elia.Store.update/2` changes some keys of a saved chat and
  keeps every other key the file holds as it was — the messages exactly as
  stored, `created_at`, and each optional key of STORE-1's table — with
  `updated_at` the moment of the update. It writes as a save does (STORE-2). For
  an invalid id, or a chat with no file, it writes nothing and returns
  `{:error, :not_found}`, so it never creates a chat.

### The shape, stated once

- **STORE-40** The table under STORE-1 is the one place a saved chat's shape is
  stated: every key a saved chat can carry is a row there, with the type the key
  holds, when it is written and whether it is dropped when it is at its default.
- **STORE-41** The table under STORE-6 is the one place the fields a listed chat
  carries are stated: every field `list/1` and `entry/1` give a chat is a row
  there, with what it holds, which chats carry it and the requirement it comes
  from.
- **STORE-42** A test reads both tables out of this spec and compares them with
  the code: a save through `save/3` that gives every option it takes writes
  exactly the keys of STORE-1's table — and a save that gives none writes no key
  that table marks dropped at its default — while a listed chat carries exactly
  the fields of STORE-6's table.

## Out of scope

- A cache on disk, such as an index file of the listed fields. It would be a
  second copy of every chat with a consistency of its own to keep; the cache of
  STORE-45 is in memory, rebuilt from the files after a restart, so the files
  stay the only record.
- A file rewritten in place, keeping its inode, its size and its modification
  time to the second (the resolution the VM reads it at). STORE-45 does not see
  such a write. Nothing in Elia writes that way — every save renames a new file
  into place (STORE-2) — and an outside tool would have to match the size to the
  byte within the same second.

## Stored data

Unchanged and backward compatible, with nothing to migrate. The cache of
STORE-45 lives in memory only, and `load_meta/1` (STORE-44) reads the keys
STORE-1's table already states, so nothing written to `.elia/sessions/` changes:
an older file loads and lists as it did before, and a file written now is what
an older version wrote. STORE-2 and STORE-43 are unchanged.

## Implementation

`Elia.Store`, `Elia.Agent.new_id/0`.

## Tests

- `test/elia/store_test.exs` (the file and its atomic write, loading, valid ids,
  listing and the fields an entry carries, saving and loading each one, deleting
  a chat, `entry/1` — STORE-1 to STORE-4, STORE-6 to STORE-7, STORE-9 to
  STORE-29, STORE-36 to STORE-38, STORE-43).
- `test/elia/store_cache_test.exs` (one decode for a session's settings, a
  listing that decodes only what changed, and a write, a replacement or a removal
  by another process seen at the next read — STORE-44, STORE-45).
- `test/elia/store_shape_test.exs` (the two tables in this spec read out of it
  and compared with what `save/3` writes and what a listed chat carries,
  STORE-40 to STORE-42).
- `test/elia/auto_approve_test.exs` (`.elia` is a protected path, so the file
  tools can't write the harness's own data even where auto-approval is on,
  STORE-8).
- `test/elia_web/file_links_test.exs` (an id is 12 URL-safe characters,
  STORE-5).
- `test/elia/agent_test.exs` (history survives a restart, STORE-4).
- `test/elia/chat_done_test.exs` (the saved flag and the listing, STORE-34,
  STORE-35).
- `test/elia/working_directory_test.exs` (the saved working directory and its
  loader, STORE-46).
- `test/elia/chat_titles_test.exs` (the stored title and the listing's
  precedence, STORE-32, STORE-33).
- `test/elia/auto_approve_test.exs` (the auto-approved set saved and loaded,
  STORE-14, STORE-15).
- `test/elia_web/live/chat_title_test.exs` and
  `test/elia_web/live/page_title_test.exs` (the title a saved chat gives a
  page, STORE-7, STORE-10).
- `test/elia_web/live/chat_live_test.exs` (a started chat is saved and listed,
  STORE-22; `/chats` resumes the most recent chat, UI-77).
- `test/elia_web/live/chat_list_test.exs` (a page is a prefix of the order,
  STORE-12).
- `test/elia_web/live/dashboard_test.exs` (the "Continue" card, DASH-3).
