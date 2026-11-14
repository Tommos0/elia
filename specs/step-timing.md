# Step timing

Status: Implemented

Every model round trip of a turn is recorded: when it happened, how long it
took, where that time went and what the provider said it cost. A later review
can then measure a turn instead of inferring it from counts — today a saved chat
holds no timestamp per step at all (only the chat's `created_at`/`updated_at`
and a running turn's `started_at`, STORE-30), so nothing says whether a step
cost 5s or 60s or how much of a turn was spent waiting for the user. The record
lives beside the chat, not in it, and no turn's behaviour depends on it.

## Requirements

- **TIME-1** A *step record* is written for every model request a turn makes:
  each step's request (LOOP-1), every further attempt of a step a transient
  failure caused (RETRY-1 to RETRY-5), and a request that failed for good. A
  step the turn never reached records nothing.

- **TIME-2** A record carries the identity of what it measures: the turn's id
  and the turn's start (STORE-30), the step's number in the turn (1-based, the
  number the step limit counts, LOOP-3) and the attempt's number within that
  step (1 for the first request), plus the outcome of the request: `ok`, `error`
  for a model call that failed (LOOP-23) or `refused` for one the model refused
  (LOOP-4). It carries two wall-clock stamps in ISO-8601 UTC: when the request
  started and when the step finished (its tools done). The stamps make the file
  readable on its own, without the chat's saved term, whose turn entry is taken
  off when the turn ends (STORE-30, INTR-1).

- **TIME-3** The record's durations are milliseconds measured with the monotonic
  clock (`System.monotonic_time(:millisecond)`, as LOOP-20 measures the turn's
  budget), so a wall-clock adjustment cannot make one negative or absurd:
  `model_ms` from sending the request to the provider's response being complete,
  `tool_ms` for running the step's tools (LOOP-10; zero when the step calls
  none), `approval_wait_ms` waiting for the step's approval decisions (LOOP-9),
  `answer_wait_ms` waiting for an answer to a question (LOOP-21) and
  `retry_wait_ms` the wait before a retry (RETRY-4; zero otherwise). Waiting is
  kept apart from the work it delayed, as LOOP-20 keeps it out of the turn's
  budget.

- **TIME-4** Each tool call the step ran is recorded with its name, its duration
  in ms and whether it failed (the result is an error, as LOOP-12 answers a
  crash). A call that didn't run records no duration: nothing is recorded for
  the calls of a refused response (LOOP-4), of one that hit the output limit
  (LOOP-5) or of a call the user denied (APPR-6).

- **TIME-5** When the provider reported usage for the step's request, the record
  carries the input and output token counts as CTX-6 counts them
  (`Elia.LLM.Context.provider_input_tokens/1` and `provider_output_tokens/1`),
  so the same field means the same thing whichever provider answered
  (LLM-1). A request whose usage is missing or carries no counts records no
  counts (LOOP-22).

- **TIME-6** A chat's records are appended to `<chat id>.timing` in
  `Elia.Store.dir()` (`.elia/sessions/`), one JSON object per line, so the file
  reads and greps as plain text. Recording doesn't touch the chat's saved term
  (STORE-1, STORE-2): it doesn't grow with the records, and saving the chat
  doesn't rewrite them.

- **TIME-7** A record is written when its step finishes, not when the turn ends,
  so a turn the app restarts during keeps every step it completed (INTR-1,
  INTR-2), and a turn running now can be watched as it goes.

- **TIME-8** Recording never changes a turn: a record that can't be written is
  ignored — no error reaches the turn, the transcript, the model or the chat
  list — and a chat that never ran a step has no `.timing` file.

- **TIME-9** A chat's records are read back with `Elia.StepTiming.load/1` (the
  chat's id), oldest first, as maps holding the fields of TIME-2 to TIME-5. An
  invalid id (STORE-4) or a chat with no records returns `[]`.

- **TIME-10** Deleting a chat deletes its records with it (STORE-23), so no
  `.timing` file outlives its chat. A `.timing` file is not a chat: the chat
  list, the resume target and everything else that reads saved chats behave
  exactly as before (STORE-12, STORE-24, STORE-29).

## Stored data

Backward compatible: there is nothing to migrate. The records are a new file
(`<chat id>.timing`) that no older code reads — a chat saved before this change
has none and reads as no records (TIME-9) — and the chat's own saved term
(STORE-1, STORE-2) keeps exactly the shape an older version wrote: no field
added, removed or reshaped. Deleting a chat (TIME-10) removes a file that may
not be there, which is ignored.

## Out of scope

- Pruning, rotating or aggregating the records across chats.
- Showing them in the UI: no page, chart or per-step line in the transcript is
  required by this spec. Reading them is `Elia.StepTiming.load/1` or the file.
- A setting to turn recording off, and timing anything that isn't a loop step
  (a deploy, a compaction, a preview run).
- Attributing time inside a tool: TIME-4 gives a call's total, not what part of
  it was a jail mount or a `mix` compile.

## Implementation

`Elia.StepTiming` (records and reads them), `Elia.Agent.Loop` (measures a step,
reports it to the session as `{:loop_usage, usage}` already is,
`lib/elia/agent/loop.ex:214`), `Elia.Agent.Session` (writes the record),
`Elia.Store` (deletes it with the chat).

## Tests

- `test/elia/step_timing_test.exs` covers every requirement, with the loop and
  session ones driven through a turn and checked in the file: the record and
  what it names, the durations and the tools, the usage, the file it is
  appended to, when it is written, a record that can't be written, reading it
  back and deleting it with the chat — TIME-1 to TIME-10.
