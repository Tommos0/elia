# Chat search

Status: Draft

`search_chats` is how a chat answers "have I done this before?" (HIST-1), but it
answers it expensively and narrowly. It walks the saved chats newest first and
decodes each chat's file until it has enough matches
(`Elia.Skills.Chats.find_matches/2`), so a search with few hits reads the whole
history, and the listing cache of STORE-45 keeps a chat's metadata and not its
messages, so that text comes off the disk again at every search. And it matches
one literal string (HIST-9), so a chat that reached the same conclusion in other
words cannot be found at all — which is the case that matters, because a
question is rarely worded the way the answer was.

This spec adds an index the server keeps in memory over the text of the saved
chats, and reads a query as terms that must all be there, ordered so that the
chat which is *about* the subject comes first. The files stay the only record:
the index is derived from them, keyed on the same file identity as the listing
cache (STORE-45), rebuilt after a restart and never written to disk. The cost is
memory proportional to the text of the saved chats, which is the price of not
reading them again.

This supersedes HIST-9, whose literal-substring query a query of one term still
describes: the change that implements this spec strikes that requirement in
`specs/chat-history.md` and says so there.

## Requirements

- **SEARCH-1** The server keeps an index in memory over the saved chats: for a
  term, which saved chats hold it and in which of their messages.
- **SEARCH-2** A chat's messages, its title and its description (STORE-10) are
  indexed, folded the way a query is folded, so a term is found whatever its
  case.
- **SEARCH-3** The index is derived from the saved chat files and nothing else:
  it is in memory only, nothing about it is written to `.elia/`, and a restart
  builds it again from the files.
- **SEARCH-4** The index follows the files rather than its own copy of them: a
  chat saved, replaced or deleted by this server, by another one or by an
  outside process is indexed as it is now at the next search, without a restart.
- **SEARCH-5** The index is built when a search first needs it: that build
  decodes every saved chat's messages once, and a later search decodes no chat
  it has already indexed whose file has not changed (SEARCH-4).
- **SEARCH-6** A search decodes the chats it reports matches from — for the
  snippet of SEARCH-10 — and no other: once the index is built, a query whose
  terms match nothing decodes no chat's messages.
- **SEARCH-7** `search_chats`'s `query` is split into terms on whitespace, and
  each term is a case-insensitive literal substring of a message's text, of a
  tool result's content or of a tool call's input JSON, as HIST-9 read one.
- **SEARCH-8** A message matches when every term appears in it, and a chat whose
  title holds every term whose messages do not match contributes one match of
  its own: its first message.
- **SEARCH-9** Matches are ordered with a chat whose title holds every term
  before one whose title does not, then by the newer chat (STORE-12), then by
  the earlier message within that chat, and `limit` keeps that many from the
  front of that order.
- **SEARCH-10** A match carries `id`, `title`, `index` and `role` as HIST-9
  carried them, and `snippet`: up to 200 characters of the matched text around
  its first match, or, for the match of SEARCH-8 that the title alone makes, the
  message's text from its start.
- **SEARCH-11** `query` is required and non-blank, and a query that is missing
  or blank is a tool error saying so; `limit` is 20 by default and at most 100,
  and a value outside that is clamped rather than refused.
- **SEARCH-12** The `chats` skill's instructions (HIST-1) say how a query is
  read: its terms, that every one of them has to be there, and that a chat's
  title counts as well as its messages.

## Out of scope

- **A database or an index on disk**, such as SQLite with full-text search or a
  file of terms. It would be a second copy of every chat with a consistency of
  its own to keep, where the files are the only record — the same thing
  `specs/persistence.md` excludes for the listing cache — and the index here is
  derived from the files and rebuilt from them, so nothing has to be migrated
  and nothing can go stale on disk.
- **Finding a chat by meaning rather than by words.** Embeddings would be a
  provider call per saved chat and a stored vector per chat: a decision of its
  own, not an index over the files.
- **Stemming, fuzzy matching, phrase or boolean operators**, and a ranking of
  anything but the title, the chat's recency and the message's position.
- **Searching anything but the saved chats**: the settings database, saved
  skills, workflows, or the files in a chat's workspace.
- **`list_chats`'s `query`**, which stays the title-and-description match of
  HIST-2.

## Stored data

Nothing stored changes shape and there is nothing to migrate. The index is in
memory only (SEARCH-3) and no file is written for it, so `.elia/sessions/` holds
exactly what it held: a chat saved by an older version is indexed and searched
like any other, and a chat saved by this version is what an older version wrote.
STORE-45's cache keeps its shape and its rule; the index adds no key to a chat's
file.

## Implementation

- `Elia.Store` (the index, beside the listing cache of STORE-45, whose file
  identity it keys on: `list/1` and `load/1` are what it reads the chats with).
- `Elia.Skills.Chats` (the query, the order, the snippets and the tool error,
  SEARCH-7 to SEARCH-11, and its instructions, SEARCH-12).
- `specs/chat-history.md` (HIST-9 struck as superseded).

## Tests

- No test: SEARCH-1 to SEARCH-12 — the code this spec names is not written yet.
  This spec is `Draft`, and the change that implements it replaces this line with
  the test files and moves the status to `Implemented`.
