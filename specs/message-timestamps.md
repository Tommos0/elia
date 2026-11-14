# Message timestamps

Status: Implemented

A transcript says what happened and in what order, but not when: a saved chat
carries only its own `created_at`/`updated_at` (STORE-1, STORE-11) and a running
turn's `started_at` (STORE-30), so nothing in the chat says whether an item
arrived seconds or days before the one under it. This feature stamps each
message with the moment the chat appended it, saves that stamp with the chat,
and shows it in the transcript as a small relative time ("just now", "10
minutes ago", "3 hours ago"), with the exact moment on hover.

## Requirements

- **MSGAT-1** The moment a message is appended to a chat's history is recorded
  on the message itself, in its `meta` — the harness bookkeeping a provider is
  never sent (LLM-5) — as a `DateTime` in UTC, so the stamp travels with the
  message wherever it is saved, loaded or copied.

- **MSGAT-2** `Elia.Agent.Session.append/2` is the one place a message is
  stamped as it enters the chat's history, before the message is broadcast and
  saved, so the item the page shows and the message on disk carry the same
  moment; a message that already carries a stamp keeps it.

- **MSGAT-3** A message that carries no stamp — one saved before this change —
  is read as having none, `Elia.LLM.Message.at/1` answering `nil` rather than
  failing.

- **MSGAT-4** The stamp is saved with the chat (STORE-1, STORE-2) and loaded
  with it, so a chat reopened after a restart shows the same times it showed
  when its items arrived.

- **MSGAT-5** Each transcript item shows how long ago it was added, in small dim
  text: UI-34's human-readable relative form, in a `<time>` element whose
  `datetime` is the stamp in ISO-8601 and whose `title` is the exact moment in
  UTC, and whose id names the item so a test can find it.

- **MSGAT-6** The relative text refreshes while the page is open, at least once
  a minute, with no reload and no action by the user, on the page's existing
  tick (UI-34).

- **MSGAT-7** The time is shown for every transcript item that came from a
  message — the user's messages, the assistant's text and reasoning, the tool
  cards and the harness messages that read as notices (UI-9) — and, for an item
  the page shows only while a turn runs, the moment it was shown; an item that
  carries no stamp shows no time.

- **MSGAT-8** A stamp changes nothing else: a provider is still sent none
  (LLM-5), the transcript's order, the compaction view and an item's request
  annotations are as they were (UI-61, COMPACT-25), and the chat's saved shape
  keeps the keys STORE-1 lists, since a stamp lives inside a message.

- **MSGAT-9** The sample chat a preview saves carries stamps, so a picture of a
  chat shows the times (PREVIEW-10).

## Stored data

Backward compatible, with nothing to migrate: the stamp lives inside a
message's `meta` (MSGAT-1), so the saved chat's own keys are exactly the ones
STORE-1 states and an older version reads the file as it did before. A message
saved before this change carries no stamp and reads as none (MSGAT-3), which the
transcript shows as no time (MSGAT-7); no stored file is rewritten.

## Out of scope

- A setting to turn the times off, and a time on anything that isn't a
  transcript item.
- Changing `created_at`/`updated_at` (STORE-11) or the per-step records
  (TIME).
- Backfilling stamps for the messages a chat already holds: they show no time.

## Implementation

`Elia.LLM.Message` (`at/1`, `stamp/1`), `Elia.Agent.Session` (stamps a message as
it is appended), `EliaWeb.ChatLive` (the stamp an item carries, the `<time>` it
renders, and the stamped items it keeps by id so the page's tick can send an
item again once its text has moved on), `EliaWeb.TimeAgo`, `Elia.Preview`
(stamps the sample chat).

## Tests

- `test/elia/message_timestamps_test.exs` (the stamp written on append, that it
  is one place, that a message with one keeps it, reading a message without one,
  the stamp saved and loaded with the chat, and that nothing else about the
  message or the chat changes — MSGAT-1 to MSGAT-4, MSGAT-8).
- `test/elia_web/live/chat_message_time_test.exs` (the item's `<time>`: the
  relative text, the `datetime`, the `title` and the id, the items that carry
  one, an item without one, and the refresh — MSGAT-5 to MSGAT-7).
- `test/elia/preview_test.exs` (the sample chat's stamps, MSGAT-9).
