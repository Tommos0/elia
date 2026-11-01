# Compaction

Status: Implemented

A long chat grows without bound: every step (LOOP-1) sends the model the whole
history, so cost and latency rise with the length of the conversation until the
request no longer fits the model's window. Compaction bounds the request without
losing the conversation. The session keeps and shows the **full history**; the
model is sent a smaller **request view** derived from it, and the UI is honest
about which parts the model did or didn't see.

The design follows a survey of this project's own saved chats (67 chats, 3,395
messages, ~2.19M estimated tokens):

| Bucket | Share |
| --- | --- |
| User text | 0.7% |
| Assistant text | 4.2% |
| Reasoning (thinking) | 30.9% |
| Files (`read_file`/`write_file`/`edit_file`) | 39.1% |
| Shell | 20.5% |
| Other tools | 4.7% |

Everything the human said and everything the model concluded is under 5% of the
context; ~95% is tool output and reasoning, almost all of it re-derivable from
the workspace (re-read the file, re-run the command, check git). So compaction
**keeps the spoken record verbatim and elides the machinery**, and only reaches
for a model-written summary when elision alone is not enough. Tool results are
~50% of the context and tool *call inputs* ~14% (mostly `edit_file`/`write_file`,
the record of what was written), so results are the safe lever and call inputs
are not.

## Requirements

### The request view

- **COMPACT-1** Compaction never removes a message from the chat's saved history
  (STORE) or from the transcript. The conversation the user reads, reloads and
  audits is always complete.
- **COMPACT-2** What the model is sent is a **request view** derived from the
  full history. A single pure function derives it; the session derives it when
  a turn starts (SESS-24), and both `Elia.Agent.Loop` (which sends it) and
  `EliaWeb.ChatLive` (which annotates the transcript with it) use the same
  function, so the two can never disagree.
- **COMPACT-3** Deriving the request view is deterministic given the history,
  the chat's compaction state (COMPACT-22) and its options. Given the same
  inputs it yields the same view.

### Boundary safety

- **COMPACT-4** The request view begins at a user message and is cut only at
  turn boundaries: a `tool_call` and its matching `tool_result` are always kept
  or dropped together (LLM-10's pairing), and provider-produced blocks (text,
  reasoning, tool calls with `raw`) are either sent byte-for-byte or dropped
  whole — never rewritten (the provider checks history is append-only).
- **COMPACT-5** Compaction runs at the start of a turn **and at each step of the
  running loop** (COMPACT-29), so a turn that grows past the trigger mid-flight
  is compacted too. Two constraints keep the running tool loop safe: the turn
  being run is never cold — the cold region always ends at or before its user
  message — so the loop's own calls and results stay intact and approval state
  keyed by `call_id` is never invalidated; and a mid-turn pass elides only, never
  summarizing, so no model call happens inside a step.

### Trigger

- **COMPACT-6** A turn compacts first when the estimated request context (CTX-1,
  over the request view) exceeds a trigger that is the **lower of two limits**:
  an absolute token budget (150,000 by default) and a fraction of the model's
  known context window (80% by default, CTX-7). The window is a hard ceiling; the
  budget bounds cost and latency and keeps the context at a size the model still
  uses well, so a large window (e.g. 1M) does not let a chat grow to fill it:
  `trigger = min(budget, fraction * window)`.
- **COMPACT-7** With no known window (CTX-7) no automatic compaction happens;
  the budget alone could still be used, but a chat is not compacted unattended
  without a window.
- **COMPACT-8** Compacting reduces the request view to a **target** below the
  trigger (half the trigger by default), so a chat does not recompact on every
  turn once it reaches the trigger.
- **COMPACT-9** The budget, the fraction, the target, the size of the working
  set — in turns and in tokens (COMPACT-12, COMPACT-28) — and whether automatic
  compaction is on are configurable per chat.
- **COMPACT-10** A manual "compact now" action compacts an idle chat on demand,
  ignoring the threshold and the target.

### What is always kept

- **COMPACT-11** Every user message is kept verbatim, whatever its age; an
  individual user message larger than a cap is truncated with an explicit marker
  rather than dropped.
- **COMPACT-12** The most recent `K` turns (a "working set", 6 by default) are
  kept verbatim, as are all pinned items (COMPACT-19). The turn count is an
  upper bound only: the working set is also bounded by size, so older turns fall
  out of it (COMPACT-28).
- **COMPACT-28** The working set is the most recent turns that fit in
  `working_set_tokens` estimated tokens (40,000 by default), but **never more
  than `working_set` turns and always at least the current (last) turn**, so a
  chat of few but very long turns — where the turn count alone puts every turn
  inside the working set and nothing can be elided (COMPACT-12) — can still be
  compacted, and the turn being worked on is never cold even when it alone
  exceeds the budget. The cold prefix starts at the user message that begins the
  oldest turn kept, so the boundary is always a turn boundary (COMPACT-4). The
  default is about a quarter of the default budget of 150,000 (COMPACT-6), so
  after the working set is set aside the ladder still has room to reach the
  target (COMPACT-8).
- **COMPACT-13** The first user message (the task statement) and any sub-task's
  brief are always kept.

### The ladder

Compaction elides the cold prefix (the turns older than the working set) in this
order, stopping as soon as the estimate is at or below the target:

- **COMPACT-14** First, **reasoning blocks** in the cold prefix are dropped
  (they are the model's self-talk about work already done and acted on, and the
  provider already tolerates dropping stale thinking).
- **COMPACT-15** Then old **tool results** are elided: each is replaced by a
  one-line note naming the call and its input summary, with an explicit marker
  saying the output was elided and the tool should be re-run or the file
  re-read. Tool call *inputs* are not elided on their own — a call and its
  result go together (COMPACT-4) and a `write_file`/`edit_file` input is the
  record of what was written.
- **COMPACT-16** Then whole **old turns** (the assistant text and calls of a
  turn) are dropped, oldest first, down to the working set.

### Within a turn

- **COMPACT-29** A running turn is compacted too, not only at its start: at
  every step of the loop the request view is derived again, from the full history
  and the chat's compaction state, by the same pure derivation the turn start
  uses (COMPACT-2, COMPACT-3), so the view can shrink while the history keeps
  growing. The current turn is never cold: the cold region always ends at or
  before its user message (COMPACT-28), so every message of the turn being run is
  sent in full and approval state keyed by `call_id` stays valid (COMPACT-4,
  COMPACT-5). The pass is **elision only**: it may take the ladder (COMPACT-14,
  COMPACT-15, COMPACT-16) deeper towards the target (COMPACT-8), starting from
  the level already reached — the ladder never moves back up (COMPACT-12) — but
  it never folds a summary (COMPACT-17), so no model call happens inside a step,
  and a ladder that cannot reach the target leaves the pruned view and no error
  (COMPACT-20). What it is measured against is the view's tokens plus the
  request's overhead (CTX-1): at or below the trigger nothing changes and nothing
  is reported; when the ladder advances, `Elia.Agent.Loop` reports the new state
  to `Elia.Agent.Session`, which saves it and broadcasts `{:compaction, state}`,
  so the transcript's annotations and the context estimate stay honest about what
  the model was sent (COMPACT-24, COMPACT-25, COMPACT-26) and a changed request
  view resets the CTX-10 provider adjustment (COMPACT-27).

### Summary (the fallback)

- **COMPACT-17** Only when the ladder (COMPACT-14..16) cannot get to the target
  is the cold prefix **summarized** by a model call, into one summary block.
  Pruning happens before summarizing, always.
- **COMPACT-18** The summary is **folded incrementally**: it is produced from
  the *previous summary plus the turns newly aged out of the working set*, never
  re-derived from the whole history, so the summarizer's input is bounded by
  `summary size + chunk` and does not grow with the conversation.
- **COMPACT-19** The summary is a harness message (`meta.harness`, UI-9) placed
  at the head of the request view, so it renders as a notice in the transcript
  at the boundary of the region it covers, and the user sees the compression in
  place rather than a gap.
- **COMPACT-20** The summarizer is injectable (as `:llm` is, LOOP-16), so tests
  never call a provider. If summarization fails, the turn proceeds with the
  pruned view alone (no error).

### Pinning and the ledger

- **COMPACT-21** A message or block can be **pinned**. Pinned items are never
  elided by any rule above. The user pins from the UI; the model can pin by
  writing to the ledger.
- **COMPACT-22** Alongside the summary there is an append-only **ledger** of
  exact facts — file paths, decisions, requirement IDs, open questions — kept
  verbatim and sent in the request view. It is append-and-trim only, never
  re-summarized, so the identifiers that matter survive folding.
- **COMPACT-23** The request view carries an explicit marker naming how much was
  elided and telling the model to re-read or re-run rather than rely on memory,
  so silent loss becomes a knowable gap.

### State and the UI

- **COMPACT-24** The summary, the ledger, the pin set and the aged-out marker
  are saved with the conversation (STORE) and reloaded on restart, so a
  restart neither re-summarizes nor loses pins.
- **COMPACT-25** The transcript annotates each message and block with its
  request-view status — **Sent**, **Truncated** (with the elided amount and a
  way to reveal the full text), **Elided** ("not sent to the model"),
  **Summarized** (covered by a summary block) or **Pinned** — reusing the
  existing dim/collapse patterns (UI-20, UI-29). The UI never implies the model
  saw something it did not.
- **COMPACT-26** The context indicator (CTX) estimates the **request view**, not
  the full history, and shows the elided amount, so its total matches what the
  model was sent.
- **COMPACT-27** Changing the request view resets the CTX-10 provider
  adjustment, as a conversation reset does, since the calibrated figure
  described a different history.

## Out of scope

- Summarizing the whole conversation into a fresh one ("start over"): a manual
  reset is a different feature.
- Model-driven selection of *individual* messages to drop (only whole
  boundaries are cut; the model is used only to summarize).

## Implementation

`Elia.LLM.Compaction` (the pure request view, its ladder, `compact/3` at the
turn start and the elision-only `trim/3` mid-turn), `Elia.Agent.Session`
(compaction state, pins, the manual action, the loop's mid-turn report),
`Elia.Agent.Loop` (derives and sends the request view at every step,
COMPACT-29), `Elia.Store` (saving the summary, ledger and pins),
`Elia.LLM.Context` (estimate over the request view), `EliaWeb.ChatLive`
(annotations, the summary notice, "compact now").

The state the session keeps per chat (`Elia.LLM.Compaction.t/0`) is a `level`
(how far down the ladder the cold region has been taken), the `covered` index
the cold region ended at last time (the aged-out marker), the `folded` index the
summary has already taken in, the `summary`, the `ledger`, the `pins` and the
chat's own option overrides. Rules apply only to messages before `covered`, so
the view does not drift as the chat grows, and the ladder never moves back up:
a region that was elided or summarized stays that way.

The cold prefix starts where the working set does, and
`Elia.LLM.Compaction.working_set_start/2` finds it: the last `working_set`
turns, trimmed from the oldest while their estimate exceeds
`working_set_tokens`, and never below the current turn (COMPACT-12,
COMPACT-28).

Two things are deliberately not literal, and the code is where the choice
lives:

* **The summary is additive.** It is produced when the ladder cannot reach the
  target (COMPACT-17) and is placed at the head of the view, but a user message
  is never dropped (COMPACT-11), so the summarized region's own user messages
  stay in the view and it can still exceed the target. The summary preserves the
  *meaning* of what was dropped; the elision is what bounds the request.
* **The summarizer sees pruned content.** Its input is the previous summary plus
  the newly aged-out turns with reasoning dropped, tool results cut to 1,000
  characters and user turns to 4,000 (COMPACT-18), so pruning happens before
  summarizing.

The summarizer is `loop_opts[:summarizer]`, a `(input -> {:ok, text} |
{:error, term})` function, injectable exactly as `:llm` is (LOOP-16) so tests
never call a provider; without one a provider call is made through the turn's
own request (`:llm`), and any failure leaves the pruned view and no error
(COMPACT-20). It is only ever reached from the turn start: `trim/3` shares
`walk/5` with `compact/3` but has no path to `fold/4` (COMPACT-29).

## Tests

`test/elia/llm/compaction_test.exs` (the ladder, the size-bounded working set,
boundary safety, bounded folding, pinning, the elision-only `trim/3` and its
stopping point, COMPACT-29), `test/elia/agent_test.exs` (state, persistence, the
trigger, the manual action, the ledger, and the mid-turn pass end to end: a later
request smaller than an earlier one, the current turn sent in full, the
`{:compaction, state}` broadcast before the turn ends, COMPACT-29),
`test/elia_web/live/compaction_test.exs` (annotations, the notice, the estimate,
the pin, "compact now").
