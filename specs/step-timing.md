# Step timing

Status: Implemented

Every model round trip of a turn is recorded: when it happened, how long it
took, where that time went and what the provider said it cost. A later review
can then measure a turn instead of inferring it from counts — today a saved chat
holds no timestamp per step at all (only the chat's `created_at`/`updated_at`
and a running turn's `started_at`, STORE-30), so nothing says whether a step
cost 5s or 60s or how much of a turn was spent waiting for the user. The record
lives beside the chat, not in it, and no turn's behaviour depends on it.

A summary of those records is what makes them usable from inside a chat: the
`chats` skill's `chat_timings` tool (TIME-11 to TIME-18) sums them for one chat
or for a project's newest chats, so where a chat's wall clock went — and how
much of it went to waiting rather than to work — is one call instead of a guess.

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

- **TIME-11** The built-in skill `chats` (`Elia.Skills.Chats`, HIST-1) provides
  a read-only tool `chat_timings` that answers where a chat's or a project's
  time went from the step records (TIME-1 to TIME-9) alone, and the skill's
  instructions say what the tool is for and that it reads the records through
  the harness rather than through a command, so a chat whose jail is on has it
  too (ISOL-16, ISOL-13), where `.elia/sessions` is out of a command's reach
  (ISOL-6).

- **TIME-12** `chat_timings` takes `id` — one chat of the chat's own project
  (HIST-11) — or, without it, `limit`: the newest chats of that project that
  have records, newest first (STORE-12), 5 by default and at most 20. An `id`
  that isn't a valid chat id (STORE-4), has no saved chat (STORE-24) or names a
  chat of another project (HIST-11) is a tool error naming what it was given, as
  `read_chat` answers it (HIST-8).

- **TIME-13** A chat's figures come from its records (TIME-9) and nothing else:
  `steps`, how many records it has; `model_ms`, `tool_ms`, `approval_wait_ms`,
  `answer_wait_ms` and `retry_wait_ms`, each the sum of that duration over them
  (TIME-3); and `waited_ms`, the sum of the three waiting figures — approval,
  answer and retry — so the wall clock a chat spent waiting on the user or on
  retries stands as its own figure beside the work it delayed.

- **TIME-14** A chat's summary counts the trouble its records show —
  `failed_or_retried`, how many of them have an `attempt` greater than 1 or an
  outcome of `error` or `refused` (TIME-2) — and the tokens they carry:
  `input_tokens` and `output_tokens`, each the sum of that count over the
  records that carry it (TIME-5), absent when none of them does.

- **TIME-15** The result is JSON: `chats`, one object per chat reported, in the
  order it reported them, each holding the chat's `id`, its `title` (STORE-33)
  and the figures of TIME-13 and TIME-14; and `total`, those figures summed over
  every record of every chat reported, with `chats` saying how many chats that
  is — so one call answers where the time of a chat, or of a project's newest
  chats, went.

- **TIME-16** `chat_timings` reads and changes nothing: no session is started
  for a chat it reads (SESS-14), no record is written, no chat and no setting is
  touched, and it needs no approval (HIST-10, APPR-1).

- **TIME-17** A chat with no records is not an error: a listing leaves it out,
  and one asked for by `id` is reported with `steps` 0 and every figure zero.

- **TIME-18** One record that can't be read never fails a summary: a line that
  isn't a record is skipped, as reading a chat's records skips it (TIME-9), and
  a field that isn't a whole number counts as zero.

## Stored data

Backward compatible: there is nothing to migrate. The records are a new file
(`<chat id>.timing`) that no older code reads — a chat saved before this change
has none and reads as no records (TIME-9) — and the chat's own saved term
(STORE-1, STORE-2) keeps exactly the shape an older version wrote: no field
added, removed or reshaped. Deleting a chat (TIME-10) removes a file that may
not be there, which is ignored.

The summary (TIME-11 to TIME-18) reads those same records and writes nothing
(TIME-16): it adds no field to a record and no file to the store, so a `.timing`
file written before this change reads exactly as it did (TIME-9) and there is
nothing to migrate.

## Out of scope

- Pruning or rotating the records.
- Showing them in the UI: no page, chart or per-step line in the transcript is
  required by this spec. Reading them is `Elia.StepTiming.load/1`, the
  `chat_timings` tool (TIME-11) or the file.
- A per-step listing from `chat_timings`: it reports a chat's totals (TIME-13,
  TIME-14), not its records one by one.
- A setting to turn recording off, and timing anything that isn't a loop step
  (a deploy, a compaction, a preview run).
- Attributing time inside a tool: TIME-4 gives a call's total, not what part of
  it was a jail mount or a `mix` compile.

## Implementation

`Elia.StepTiming` (records and reads them), `Elia.Agent.Loop` (measures a step,
reports it to the session as `{:loop_usage, usage}` already is,
`lib/elia/agent/loop.ex:214`), `Elia.Agent.Session` (writes the record),
`Elia.Store` (deletes it with the chat), `Elia.Skills.Chats` (the
`chat_timings` tool, TIME-11 to TIME-18) and `Elia.StepTiming` (`summary/1`, the
figures of TIME-13 and TIME-14).

## Tests

- `test/elia/step_timing_test.exs` covers every requirement, with the loop and
  session ones driven through a turn and checked in the file: the record and
  what it names, the durations and the tools, the usage, the file it is
  appended to, when it is written, a record that can't be written, reading it
  back and deleting it with the chat — TIME-1 to TIME-10.
- `test/elia/chat_timings_test.exs` (TIME-11 to TIME-18): the tool the `chats`
  skill provides and what it says it is for, the chats it reads and the `id` it
  refuses, a chat's figures and the total, a listing's newest chats with records
  and its limit, a chat with no records and a record that can't be read.
