# Reading earlier chats

Status: Implemented

The agent can look at chats other than the one it is running in: list them,
read one's transcript, and search across them. Everything the user and the
agent decided in an earlier chat — a path, a decision, what was already tried —
is in that chat's saved file (STORE-1), and without a way to read it the agent
either asks the user again or starts from nothing. Unjailed a command could open
`.elia/sessions`, but those files are Erlang terms, not text (STORE-1), so what
an unjailed chat can do is awkward; and with the jail on (ISOL-16) they are out
of reach entirely (ISOL-6). These tools read the
saved chats through the harness instead — the way a parent reads a child chat's
result with `await_task` (SUBTASK-27) — so a chat can consult the earlier ones
whether or not it is jailed, and without a command or an approval prompt.

They are confined to the chat's own project (HIST-11): what a chat can consult
is its own project's history and not another project's.

## Requirements

- **HIST-1** The built-in skill `chats` (`Elia.Skills.Chats`, listed in the
  `builtin` config, SKILL-7) provides `list_chats`, `read_chat` and
  `search_chats` in every project, and in a sub-task chat as well: a child's
  skills are the registry's without `tasks` and with `task` (SUBTASK-1), so
  `chats` reaches it unchanged. Its instructions say what the three tools are
  for, that a chat id is the one in its URL (`/c/<id>`, UI-2), that the tools
  read Elia's own saved chats through the harness rather than through a command
  — so they work in a jailed chat too (ISOL-16, ISOL-13),
  where `.elia/sessions` is out of reach and its files are Erlang
  terms rather than text anyway (STORE-1) — and that what they read is the chat
  as it was last saved (STORE-1), so a chat that is running now may not have its
  current turn in its file yet, and that they see the chats of the chat's own
  project and no other (HIST-11).
- **HIST-2** `list_chats` takes `query`, `limit` and `children`, all optional,
  and returns the matching chats of the chat's own project (HIST-11) newest
  first (STORE-12) as a JSON array of objects with `id`, `title` (STORE-33),
  `created_at` and `updated_at`
  (ISO 8601 UTC, STORE-11), `project` (the chat's project id or `null`,
  STORE-20), `parent` (the id of the chat that spawned it, or `null` for a chat
  nothing spawned, STORE-17), `status` (HIST-3) and `messages` (how many
  messages the chat holds). `query` keeps a chat whose title or description
  (STORE-10) contains it, ignoring case; `limit` is how many are returned, 20 by
  default and at most 100.
  `children` keeps this chat's own sub-tasks (STORE-18) and nothing else:
  `true` lists the chats this one started, and `"all"` lists those together with
  their own children — without it (or with `false`) nothing is filtered by
  parent. It is the chat the call runs in that is the parent: a chat that is
  itself a sub-task has no children of its own (SUBTASK-1, depth is one), so
  both values keep nothing for it, and a call whose tool context names no chat
  keeps nothing either. An entry's `parent` says whose child it is (STORE-17),
  so a child can be told from a chat nothing spawned. Nothing matching is not an
  error: the result is `[]`.
- **HIST-3** A listed chat's `status` is what its saved chat says, in this
  order: `"working"` while a session for it is running a turn in this app
  instance (SESS-4); `"done"` when it is marked done (STORE-35, DONE-1);
  `"interrupted"` when a restart cut its turn short (STORE-31); otherwise
  `"open"`. It is the status the chat as a whole is in, not the progress of a
  turn that isn't running. A sub-task's status is its chat's own like this
  (SUBTASK-34, UI-59). *Changed:* a task chat used to be listed under its task's
  own status (STORE-17); that vocabulary went with the task status itself
  (SUBTASK-33).
- **HIST-4** `read_chat` takes `id` (a chat id, STORE-4) and returns that
  chat's saved transcript (STORE-1), or, instead of `id`, `query`: a non-blank
  string that must match exactly one title among the chats of the chat's own
  project (HIST-11), ignoring case, as a substring of the title (STORE-33),
  whose chat is then read. `offset` (the 1-based index of the first message
  shown, default 1) and `limit` (how many messages, 100 by default and at most
  200) page through a long transcript.
- **HIST-5** `read_chat`'s result is text: a header naming the chat and its
  saved state — `# <title> (<id>)`, then `created <ISO 8601>, updated <ISO
  8601>, project <id|none>, <status> (HIST-3), <n> messages` — then
  `[messages <first>-<last> of <n>]`, then one line per message.
- **HIST-6** Each message is one line, `[<index>] <role>: <text>` with the
  index its 1-based position in the whole transcript, so HIST-4's paging can
  carry on from it; the role is `user`, `assistant` or `tool`, and a message
  the harness wrote itself is `user (harness)` (UI-9, STORE-7). `<text>` is the
  message's text blocks joined in order; an assistant message's tool calls
  follow it as further indented lines `  → <name> <input JSON>`, and a tool
  message's results as `  ← <content>`, with `← [error] <content>` for a result
  that is an error. Reasoning and opaque blocks aren't rendered — they are not
  the conversation (UI-29) — and a message left with nothing to show is still
  its own line, reading `(no text)`. A message's text is cut at 2,000
  characters and a tool result at 1,000, each with `…[+<n> more characters]` in
  place of the rest.
- **HIST-7** When messages are left out, the result ends with `[+<n> more
  messages: read again with offset=<next>]`. An `offset` that isn't the index of
  a message in the chat — including one past the end — is a tool error naming
  the chat's message count, and a chat that holds no message reads as its
  header and `[messages 0-0 of 0]` alone.
- **HIST-8** `read_chat` is a tool error, naming what it was given and changing
  nothing, when its `id` isn't a valid chat id (STORE-4), has no saved chat
  (STORE-24) or names a chat of another project (HIST-11), and when its `query`
  matches no chat of the chat's own project or more than one — the error
  names the matching chats' ids and titles (up to 10) so the model can pick
  rather than guess. `id` and `query` are both required, or the call is a tool
  error saying so.
- ~~**HIST-9** `search_chats` takes `query` (required, non-blank) and `limit`
  (default 20, at most 100) and returns the matches as a JSON array of objects
  with `id`, `title`, `index` (the message's 1-based position, HIST-6), `role`
  and `snippet`. `query` is a literal case-insensitive substring of a message's
  text, a tool result's content or a tool call's input JSON (HIST-6); `snippet`
  is up to 200 characters of the matched text around the first match in that
  message, cut with `…` and starting with `…` when the match isn't at the
  start. Chats are searched newest first (STORE-12) and their matches are
  returned in message order; the search stops as soon as it has `limit` matches,
  so a match in an older chat can be left out, and `[]` is returned when there
  is none at all.~~ Superseded by SEARCH-7 to SEARCH-11 (`specs/chat-search.md`),
  which read a query as terms that all have to be there, count a chat's title as
  well as its messages, and put a match a title makes first; a query of one term
  still means what this described.
- **HIST-10** The three tools never write: no saved chat is changed, no session
  is started for a chat they read — reading a chat is not a way to resume it
  (SESS-14) — and no approval is asked, as for `await_task` (SUBTASK-27, APPR-1).
- **HIST-11** The three tools see the chats of the project the chat they run in
  belongs to (PROJ-9) and no other: `list_chats` lists that project's chats,
  `read_chat` reads one of them — an `id` naming another project's chat is a
  tool error (HIST-8) — and `search_chats` searches that project's chats
  (SEARCH-13). The project is the one the chat's tool context carries (PROJ-12),
  and a context that names no project works in Elia's own (PROJ-9), so a chat
  with no `project_id` and one whose project has been deleted (PROJ-7) see Elia's
  own project's chats. `list_chats` therefore takes no `project` argument, and
  none of the three can be pointed at another project's history.

## Out of scope

- **Changing another chat.** Marking one done or reopened, deleting one, or
  sending it a message: these tools only read.
- **A chat's compaction state and a task chat's result** (COMPACT-24,
  STORE-16). The transcript is what is read; a task chat's own result is read
  from its chat by the parent that spawned it (`await_task`, SUBTASK-27), and a
  transcript's last assistant text carries what a child summarised.
- **The UI.** These are model-facing tools: no page changes, and a tool card
  renders as any other call does (UI-15).
- **A per-chat switch.** The tools are in every chat, jailed or not (HIST-1);
  what they may read is Elia's own saved chats and nothing else — not the
  settings database and not a file outside `.elia/sessions`.
- **Another project's chats.** A chat consults its own project's history
  (HIST-11), as the chat list holds the open project's chats and no other's
  (PROJ-31).

## Stored data

Old data: nothing stored changes shape. The three tools only read the saved
chats (STORE-1, HIST-10) — a chat saved by an older version lists and reads the
same way, and none of the tools writes a chat, a turn record or a setting — and
`Elia.Store.entry/1` (STORE-36) derives the same fields `list/1` already did,
from the same file. No migration is needed.

## Implementation

`Elia.Skills.Chats` (the three tools — the skill's own module, like
`Elia.Skills.Tasks` — and `list_chats`'s `children` filter, HIST-2),
`Elia.Store` (`list/1`, `load/1`, `entry/1` and `children/1`, STORE-18,
STORE-36),
`Elia.Agent` (`running/0` for HIST-3's `working`),
`Elia.Projects` (`chats_of/1` and `chat_project_id/2`, PROJ-31: the project the
three tools see, HIST-11),
`config/config.exs` (the skill in `builtin`).

## Tests

- `test/elia/skills/chats_test.exs` (the skill and its instructions, listing,
  filtering — the `children` filter among it, HIST-2, SUBTASK-26 — and statuses,
  reading a chat with paging and truncation, reading by query and the errors, and
  searching — HIST-2 to HIST-8, HIST-10, HIST-11; how a search reads a query is
  SEARCH-7 to SEARCH-13, `specs/chat-search.md`).
- `test/elia/store_test.exs` (`entry/1`, STORE-36) and `test/elia/agent_test.exs`
  (a session's tool list names the three, HIST-1).
