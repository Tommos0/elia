# Conversation persistence

Status: Implemented

Chats are saved to disk so they survive restarts and can be listed and
reopened.

## Requirements

- **STORE-1** A chat is saved to `.elia/sessions/<id>.term` as an Erlang term
  `%{version: 1, messages: [...], updated_at: DateTime}`. Terms are used
  instead of JSON so provider raw blocks are kept exactly (LLM-6).
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

## Implementation

`Elia.Store`, `Elia.Agent.new_id/0`.

## Tests

`test/elia/agent_test.exs` (history survives a restart),
`test/elia/store_test.exs`,
`test/elia_web/live/page_title_test.exs`.
