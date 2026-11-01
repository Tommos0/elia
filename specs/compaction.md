# Compaction

Status: Draft

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
  full history. A single pure function derives it, used by both
  `Elia.Agent.Loop` (which sends it) and `EliaWeb.ChatLive` (which annotates the
  transcript with it), so the two can never disagree.
- **COMPACT-3** Deriving the request view is deterministic given the history,
  the chat's compaction state (COMPACT-22) and its options. Given the same
  inputs it yields the same view.

### Boundary safety

- **COMPACT-4** The request view begins at a user message and is cut only at
  turn boundaries: a `tool_call` and its matching `tool_result` are always kept
  or dropped together (LLM-10's pairing), and provider-produced blocks (text,
  reasoning, tool calls with `raw`) are either sent byte-for-byte or dropped
  whole — never rewritten (the provider checks history is append-only).
- **COMPACT-5** Compaction runs only at the start of a turn, never mid-turn, so
  the running tool loop's own calls and results stay intact, and approval state
  keyed by `call_id` is never invalidated.

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
  set (COMPACT-11) and whether automatic compaction is on are configurable per
  chat.
- **COMPACT-10** A manual "compact now" action compacts an idle chat on demand,
  ignoring the threshold and the target.

### What is always kept

- **COMPACT-11** Every user message is kept verbatim, whatever its age; an
  individual user message larger than a cap is truncated with an explicit marker
  rather than dropped.
- **COMPACT-12** The most recent `K` turns (a "working set", 6 by default) are
  kept verbatim, as are all pinned items (COMPACT-19).
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

`Elia.LLM.Compaction` (the pure request view and its ladder),
`Elia.Agent.Session` (compaction state, pins, the manual action),
`Elia.Agent.Loop` (sends the request view), `Elia.Store` (saving the summary,
ledger and pins), `Elia.LLM.Context` (estimate over the request view),
`EliaWeb.ChatLive` (annotations, the summary notice, "compact now").

## Tests

`test/elia/llm/compaction_test.exs` (the ladder, boundary safety, bounded
folding, pinning), `test/elia/agent_test.exs` (state, persistence, reset),
`test/elia_web/live/chat_live_test.exs` (annotations, the notice, the estimate).
