# Speed review, 2026-11-12

A review of where wall-clock time goes in Elia's chats, and the changes that
would cut it. Not a spec: findings and proposals, for discussion. Numbers come
from the saved chats and can be reproduced (see **Method**).

Status: review, checked against the tree on 2026-11-13. Proposals **1** and
**4** are implemented (marked in the ranked table and in the findings they came
from); **2**, **3**, **5**, **6** and **7** are not started; **8** needs no
change, because the ladder already elides tool results before assistant prose
(COMPACT-14..16). Each proposal still needs its own spec and approval before
anyone writes code for it.

## Method

Read-only analysis of the 171 saved chats in `.elia/sessions/*.term` (Erlang
term files, `Elia.Store`), with throwaway `elixir` scripts that were deleted
afterwards. Each assistant message is one model round trip ("step"); each
`tool_call` block one call. The term format holds no timestamps and no
per-step usage, which is itself a finding (see **7**).

Caveat: a first pass counted 72 overlay-mount failures by grepping the bwrap
error text, which also matched files that *quote* it (`read_file` of
`specs/command-isolation.md`) and a script's own output. The honest count is 35
(see **4**); the method that gets it right is to attribute a failing result to
the tool call that produced it and require the marker to be short and singular.

## The shape of the work

| | |
| --- | --- |
| chats | 171 |
| user turns | 572 |
| assistant steps (model round trips) | 10,676 |
| tool calls | 12,978 |
| steps per turn | mean 18.5, median 5 |
| turns of 30+ steps | 112 (longest 100, the step cap) |
| reasoning text | 20.4M chars over 10.6k steps (~480 tokens/step) |
| tool results in context | 23.7M chars |

Steps are the unit of latency: each is a full provider request. Halving steps
halves the waiting.

## 1. One tool call per step (the main lever)

- **74% of steps ask for exactly one tool call** (7,833 of 10,612; 2,002 ask for
  two, 457 ask for none).
- 943 runs of two-or-more *consecutive* single-lookup steps (`read_file`,
  `list_files`, `grep`, `sed -n`, `ls`) cover **3,792 steps**. Lookups the model
  already knew it wanted, issued in one message, would be ~943 steps: **about
  2,850 fewer round trips, 27% of all of them**.
- The loop already runs a step's calls concurrently (`Task.async_stream`,
  LOOP-10), so batching costs nothing but the model's habit.

Proposal: an `AGENTS.md` rule — "in one step, ask for everything you already
know you need; several reads/searches in one message run at once; don't spend a
round trip per file". The blocker for shell calls was finding **4**: batching
commands is what provoked the overlay failures. ISOL-26/ISOL-27 fixed that
without namespace sharing (see **Open questions**), so the rule can cover shell
calls too. Open.

## 2. Orientation tax

In the 121 chats that edited code, the first `edit_file`/`write_file` came after
a mean of **16.6 steps** (max 59): docs, specs and greps before anything is
changed. At a few seconds a step, that is 1–5 minutes of every coding chat spent
before work starts.

Proposals: read only the topic doc for the change being made; `grep -n` to
locate before reading a whole file; merge `docs/agents/*.md` into one page (or
point `AGENTS.md`'s table at one) so the required reading is one step, not four.

## 3. What the model reads

| tool | calls | result chars | max |
| --- | --- | --- | --- |
| `read_file` | 3,136 | **14.3M** (avg 4.5k) | 83.4k |
| `shell` | 5,268 | 8.0M | 30.0k |
| `run_tests` | 331 | 1.1M | 30.0k |
| `await_task` | 12 | 57.8k | 12.8k |
| `edit_file` (input) | 3,515 | 3.4M of new text | |

Read results dominate every step's context, and whole files are read where a
range would do. Ideas: compact old *tool results* first (the cold-prefix ladder
treats all content alike, while tool results are 22M of the 24M chars and the
least useful when cold); a `read_file` that defaults lower; a search tool that
returns the matched regions (see **5**).

## 4. Calls that failed, and the overlay

509 failed results (1.05M chars) across all chats. Classes:

- **overlay mount failures: 35**, all from `shell`, in 11 chats, 2026-11-03 →
  2026-11-12. `bwrap: Can't make overlay mount on (null) with options
  upperdir=/proc/self/fd/N,…,userxattr: No such file or directory` + `[exit: 1]`.
  Every one is in a step that ran **2 or 3 shell calls** (33 and 2), never a
  single-call step. 399 of 10,676 steps run 2+ shell calls → **8.8% of those
  lose one of their commands**, and the command never ran at all. **Fixed**
  2026-11-13 (`9bf6184 feat: one jail at a time mounts a worktree's deps layer`)
  by ISOL-26/ISOL-27 in `specs/command-isolation.md`: a per-worktree lock around
  mount *setup* (one jail per command stays as it is), plus a retry and a
  read-only fallback so a command that never ran is never reported as failed.
  Overlapping lifetimes are not the problem — a mount started a moment after
  another succeeds while the first is still up — so a terminal's session-long
  mount is harmless, and the per-chat jail in the open questions isn't needed
  for correctness.
- **`edit_file` friction, ~80 calls**: "old_string not found in file" (52),
  "old_string occurs N times" (6), and 20 calls with a missing argument.
  Ideas: whitespace-tolerant retry, unique partial match, schema defaults.
- 59 results are `mix test` output and 50 compile output — real work, not waste.
- 31 "Cancelled by the user." (a stopped turn, not a defect).

## 5. Shell habits worth an instruction

Across 5,282 shell calls: ~1,400 `grep` (`grep -rn` 726, `grep -n` 696), 340
`sed -n` (viewing files — `read_file` is the tool for that), ~830 commands
prefixed with a pointless `cd` (`cd /home/ai/elia` 546, `cd …/worktrees/<id>`
~280 — the tools already run in the workspace root), 114 `mix precommit`, ~175
`mix test`, 104 `mix compile`, ~61 `bin/preview`, ~67 real-browser test runs.

Proposals: drop the `cd` prefix; `read_file` not `sed`; targeted tests while
iterating and one `mix precommit` at the end (the full suite is the slowest
command in the box).

## 6. Provider knobs nobody is turning

- The ten most recent chats all ran on **OpenRouter** (reasoning blocks tagged
  `Elia.LLM.OpenRouter`), but explicit prompt caching — `cache_control:
  ephemeral` — exists **only** in the Anthropic adapter
  (`lib/elia/llm/anthropic.ex:181`, LLM-8). On the provider actually in use,
  every step resends system + tools + the whole view with no cache breakpoint.
- `effort: "high"` is the default (`config/config.exs:93`,
  `lib/elia/llm/anthropic.ex:57`; OpenRouter's `:effort` default is `nil`) for a
  loop whose steps are mostly a grep and a read.
- Compaction triggers at `min(150k, 0.8 × window)` (`config/config.exs`,
  COMPACT-6/8); 49 of 171 chats compacted. The 250–300-step chats ran with very
  large views.

Ideas: cache breakpoints for Anthropic-family models behind OpenRouter; a
per-chat reasoning-effort setting with a lower default; a lower trigger.

## 7. Nothing records how long a step took

Saved chats hold no timestamps per message, and the `usage` event is broadcast
but not saved (`Elia.Agent.Session.handle_info({:loop_usage, …})`). This review
had to infer speed from counts; it cannot say whether a step costs 5s or 60s, or
how much of a turn is waiting for approvals.

Proposal (small, high value): record per step — model ms, tool ms, approval wait
ms, usage — in the chat (or a metrics file beside it), so the next review is a
measurement.

**Done**, 2026-11-13 (`11478c4 feat: record each loop step's timing beside its
chat`, TIME-1 to TIME-10 in `specs/step-timing.md`): the loop measures each
model request and the session appends one JSON line per step — turn id and
start, step and attempt, outcome, two ISO-8601 stamps, `model_ms`, `tool_ms`,
`approval_wait_ms`, `answer_wait_ms`, `retry_wait_ms`, per-call timings and the
provider's token counts — to `.elia/sessions/<chat id>.timing`, read back with
`Elia.StepTiming.load/1` (`lib/elia/step_timing.ex`). No review has read them
yet: the measurement this proposal was for is still to be taken.

## Ranked proposals

| # | Change | Kind | Expected | Status 2026-11-13 |
| --- | --- | --- | --- | --- |
| 1 | Per-worktree lock around mount setup (ISOL-26/27) | code + spec | removes 8.8% failures | **done** (`9bf6184`) |
| 2 | `AGENTS.md`: batch known lookups in one step | instructions | up to −27% round trips | open |
| 3 | `AGENTS.md`: cheaper orientation (one topic doc, grep first) | instructions | −10 steps per coding chat | open |
| 4 | Per-step timing recorded | code + spec | makes future reviews measurable | **done** (`11478c4`) |
| 5 | Search tool that returns matched regions | code + spec | 4 steps → 1–2 per "grep then read" | open |
| 6 | `edit_file` whitespace-tolerant retry, argument defaults | code + spec | ~80 wasted calls | open |
| 7 | Cache breakpoints on OpenRouter; effort default | code + spec | shorter and cheaper steps | open |
| 8 | Compact tool results before prose | code + spec | smaller views in long chats | no change needed (COMPACT-14..16) |

## Open questions

Settled by the overlay work on 2026-11-12 (bwrap 0.12, scratch overlays):

- **Overlapping lifetimes don't collide.** Two mounts started at the same
  instant fail; a mount started a second after another succeeds while the first
  is still up. So a terminal's session-long mount (TERM-7) is harmless and the
  per-chat jail is not needed for correctness — the jail stays one per command
  (ISOL-26).
- **A shared jail per step is a speed option, not a fix.** It would mount once
  per step instead of once per command, but it needs a driver protocol inside the
  jail (framing, per-command timeouts and exits), and ISOL-26 removes the failure
  without it. Not proposed.
- **Batching shell calls stays safe without namespace sharing**, because each
  command keeps its own jail and its own `/tmp` and pid namespace.

Still open:

- Proposals 2, 3, 5, 6 and 7 — none of them started. 2 and 3 are instructions
  only (`AGENTS.md` and one topic doc) and were unblocked by 1; 5, 6 and 7 each
  need a spec first.
- Proposal 4's other half: the records exist but no pass has read them, so
  nothing in this file has been turned into a measurement yet.
