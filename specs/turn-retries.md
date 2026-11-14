# Turn retries

Status: Draft

A model call can fail for reasons that are nobody's fault in the chat: the
network drops the connection mid-answer, the stream stalls until the idle
timeout cuts it (LLM-34), the provider is overloaded. Until now such a failure
ended the turn, and the chat sat there with a transcript that stopped
mid-thought until the user came back and sent a message to carry on. The
providers' own transport retries (LLM-10, LLM-30, LLM-31, LLM-35) only cover
failures that happen before a single byte arrived, since a stream that already
emitted events cannot be replayed. This feature closes the gap one level up, at
the step: a step whose model call failed in a way a retry may fix is asked
again, after a wait and on a fresh stream, so the turn carries on by itself.

## Requirements

- **RETRY-1** A step whose model call fails with a transient failure (RETRY-6)
  does not end the turn: the loop waits and sends that step's request again, on
  a fresh stream, until the retry schedule's attempts are used up (RETRY-4). A
  step that fails for any other reason — no API key (LLM-7, LLM-17), an
  authentication or request error, a response the service refuses — is not
  retried, and the turn ends at once with that error (LOOP-23, STOP-2).

- **RETRY-2** A retry is a retry of the step, not a new step: it doesn't count
  against the step limit (LOOP-3), and it sends the same request as the attempt
  that failed, since nothing from a failed attempt was appended to the history.
  The answer starts over: the partial text, reasoning and tool calls the failed
  attempt had streamed are dropped — none of them is run, appended or saved —
  so a retry is worth making even when the failed attempt had already streamed
  output, and no event is ever shown twice for one answer.

- **RETRY-3** Every retry is reported as it happens, so a chat that is waiting
  says why: before it waits, the loop sends the session
  `{:loop_retry, %{attempt: n, of: m, delay_ms: d, reason: text, text: sentence}}`
  — `n` the attempt about to be made (2 for the first retry), `m` the
  schedule's total attempts, `d` the wait before it, `reason` the provider's own
  message and `text` the sentence a page shows, e.g. "Anthropic API request
  failed: timeout. Retrying in 15 seconds (attempt 2 of 4)." — and the session
  broadcasts `{:retry, info}` (SESS-6, SESS-39). The turn stays running
  (SESS-4): it is neither paused nor stopped, and the retry is not written into
  the history, so a turn that recovered reads as one that ran without
  interruption.

- **RETRY-4** The schedule is the list of waits, from
  `config :elia, :step_retry, delays_ms: [...]` (default
  `[15_000, 30_000, 60_000]`) or the loop's `:step_retry` option (`delays_ms:`,
  which tests use). Its length is the number of retries, so the default makes up
  to four attempts and waits 105 seconds in all; `delays_ms: []` disables
  retrying, and a transient failure then ends the turn as it did before
  (RETRY-1). Time spent waiting doesn't count against the turn's wall-clock
  budget (LOOP-20) — the loop wasn't working, so the schedule, not the budget,
  is what bounds the waiting — and a failed attempt adds nothing to the turn's
  token total (LOOP-22), since it reported no usage.

- **RETRY-5** When the last attempt fails too, the turn ends the way any failed
  turn does (LOOP-23, STOP-1, STOP-2): the loop returns `{:error, text}`, where
  `text` is the provider's message followed by what was done about it —
  "(retried 3 times)", or "(retried once)" — so the transcript says both what
  went wrong and that a retry did not help. A failure the loop didn't retry
  keeps its message exactly as the provider gave it.

- **RETRY-6** Only a failure a retry may fix is retried, and the provider is
  what knows: `Elia.LLM.stream/2` returns
  `{:error, %Elia.LLM.Error{transient: true}}` for one, and a plain message (a
  binary) for every other failure (LLM-1, LLM-36). The loop retries exactly the
  former and nothing else, so a provider that knows better — a bad request, a
  revoked key, a content policy — is never asked again. `Elia.LLM.Error` reads
  as its text wherever a message is shown, so a stop's row is the provider's
  sentence (STOP-2).

## Configuration

```elixir
# RETRY-4: the waits before each retry of a failed model call. The length of
# the list is how many retries a step gets; [] turns retrying off.
config :elia, :step_retry, delays_ms: [15_000, 30_000, 60_000]
```

## Out of scope

- Running a turn again once it has stopped (RETRY-5): the user sends a message,
  or a parent spawns the sub-task again. A stopped chat is idle as before
  (SESS-4).
- A turn the app restarted while (INTR-1) — nothing is running to retry.
- The model call a compaction makes to summarize (COMPACT-17): compaction is
  not a turn.
- A tool's own failure, which is the tool result it is (LOOP-6, LOOP-7,
  LOOP-12).

## Implementation

`Elia.Agent.Loop` (the retry of a step, RETRY-1 to RETRY-5),
`Elia.LLM.Error` (the transient marker, RETRY-6), `Elia.LLM.Anthropic` and
`Elia.LLM.OpenRouter` (which failures are transient, LLM-36),
`Elia.Agent.Session` (the `{:retry, info}` broadcast, RETRY-3, SESS-39),
`EliaWeb.ChatLive` (the row and the cleared drafts, UI-86).

## Tests

`test/elia/agent_test.exs` (a transient failure retried and the turn finishing,
the schedule running out and the stop saying so, a permanent failure not
retried, no step counted and no history written by a failed attempt, RETRY-1 to
RETRY-6), `test/elia/llm/anthropic_test.exs` and
`test/elia/llm/open_router_test.exs` (which failures are marked transient,
LLM-36), `test/elia_web/live/chat_live_test.exs` (the notice row and the
cleared drafts, UI-86).