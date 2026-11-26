# Speed review, 2026-11-12

A review of where wall-clock time goes in Elia's chats, and the changes that
would cut it. Not a spec: findings and proposals, for discussion. Numbers come
from the saved chats and can be reproduced (see **Method**).

Status: review, checked against the tree on 2026-11-13, and again the same day
after the last three proposals landed. Proposals **1** to **7** are implemented
(marked in the ranked table and in the findings they came from); **8** needs no
change, because the ladder already elides tool results before assistant prose
(COMPACT-14..16). The measurement its proposal 4 was built for has since been
taken: the first reading of the `.timing` records is **Speed review, 2026-11-26**
below.

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
commands is what provoked the overlay failures. ISOL-28/ISOL-27 fixed that
without namespace sharing (see **Open questions**), so the rule can cover shell
calls too.

**Done**, 2026-11-13 (`36ea73e`): it is the "Always" bullet *"In one step, ask
for everything you already know you need"* in `AGENTS.md` — it covers reads,
searches and shell commands, names what to batch (the topic docs the table
rows name, the files a change will touch, the greps that locate them), and says
a batched command still gets its own jail and its own `/tmp` and pid namespace
(ISOL-28), so batching shell calls is safe. How much it actually saves has not
been measured yet — that is finding 4's records, unread so far.

## 2. Orientation tax

In the 121 chats that edited code, the first `edit_file`/`write_file` came after
a mean of **16.6 steps** (max 59): docs, specs and greps before anything is
changed. At a few seconds a step, that is 1–5 minutes of every coding chat spent
before work starts.

Proposals: read only the topic doc for the change being made; `grep -n` to
locate before reading a whole file; merge `docs/agents/*.md` into one page (or
point `AGENTS.md`'s table at one) so the required reading is one step, not four.

**Done, without the merge** (2026-11-13, `36ea73e`): `AGENTS.md`'s *Read before
you…* section now says to open only the rows the change matches, in one step, to
locate with `grep -n` or `list_files` first and read the range (`offset`/`limit`,
or one section of a doc) rather than whole files, and to read the spec that owns
the behaviour rather than every spec that mentions it. The five pages were
deliberately not merged into one: together they are 20 kB (~5k tokens) held for
the rest of the chat, while a code change usually needs one or two of them
(`elixir.md` + `testing.md` is 8.7 kB), and the *step* saving the merge was for
is what finding 1's batching rule already gives — one message, several reads —
so merging would buy tokens nobody needs. Whether orientation is really cheaper
now is for a later pass over the chats, not for this file. Two stale claims in
those pages were fixed in the same commit: `harness.md` said there is no
`/recover` page (it is back, RECOVER-10..RECOVER-15), and `elixir.md` named only
two LLM adapters of the four.

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

**Proposal 5 done**, 2026-11-13 (`a4651d9 feat: search_files returns the matched
regions (FILE-24..FILE-30)`): `search_files` is a sixth file tool in
`lib/elia/skills/files.ex` that returns each match with its surrounding lines —
`path:line` headers, matched lines marked, a match budget with a `[+n more
matches not shown]` tail — so finding text is one call instead of `shell` +
`grep -n` + a `read_file`. It searches only what a jailed command could reach
(FILE-28, FILE-29), walks in Elixir with no new dependency, and the `shell`
skill and tool description now send finding text to it rather than to `grep`
(FILE-24, SHELL-8). Not measured yet: whether it really turns 4 steps into 1–2.

## 4. Calls that failed, and the overlay

509 failed results (1.05M chars) across all chats. Classes:

- **overlay mount failures: 35**, all from `shell`, in 11 chats, 2026-11-03 →
  2026-11-12. `bwrap: Can't make overlay mount on (null) with options
  upperdir=/proc/self/fd/N,…,userxattr: No such file or directory` + `[exit: 1]`.
  Every one is in a step that ran **2 or 3 shell calls** (33 and 2), never a
  single-call step. 399 of 10,676 steps run 2+ shell calls → **8.8% of those
  lose one of their commands**, and the command never ran at all. **Fixed**
  2026-11-13 (`9bf6184 feat: one jail at a time mounts a worktree's deps layer`)
  by ISOL-28/ISOL-27 in `specs/command-isolation.md`: a per-worktree lock around
  mount *setup* (one jail per command stays as it is), plus a retry and a
  read-only fallback so a command that never ran is never reported as failed.
  Overlapping lifetimes are not the problem — a mount started a moment after
  another succeeds while the first is still up — so a terminal's session-long
  mount is harmless, and the per-chat jail in the open questions isn't needed
  for correctness.
- **`edit_file` friction, ~80 calls**: "old_string not found in file" (52),
  "old_string occurs N times" (6), and 20 calls with a missing argument.
  Ideas: whitespace-tolerant retry, unique partial match, schema defaults.
  **Done**, 2026-11-13 (`f69986b`, FILE-31..FILE-38 in `specs/file-tools.md`):
  when the exact match finds nothing, a retry compares whole lines ignoring
  indentation, trailing whitespace and a `\r`, and is used only when exactly one
  run matches — several candidates stay an error naming the count and the lines,
  never a pick (FILE-33). An ambiguous exact match now names the lines too
  (FILE-36). **No** argument defaults were added (FILE-37): of the 20
  missing-argument calls, 13 sent their replacement text under a misspelled key,
  so defaulting `new_string` to `""` would have turned each into a silent
  deletion. Honest caveat on the expected yield: the sub-task sampled two of the
  52 "not found" failures and neither was a whitespace difference (one was
  pasted twice over, one had its line breaks elsewhere than the file's) — expect
  a share of that 52, not all of it. Not measured either way.
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

**Partly done**: the pointless `cd` is now an instruction (`SHELL-2`,
`24a31fc docs: never prefix a shell command with cd`) and the file tools' rule
covers `sed` and `cat`; `search_files` (finding 3, `a4651d9`) is where a search
goes now instead of `grep` (FILE-24). Nothing measures whether the habits
followed, so this is instruction, not evidence.

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

**Proposal 7 done**, 2026-11-13 (`56d6b6b`): `LLM-37`..`LLM-39` in
`specs/llm-providers.md`. OpenRouter now sends one `cache_control: ephemeral`
breakpoint on the system message — but only for an `anthropic/...` model, since
DeepSeek, OpenAI and Gemini cache server-side with nothing for the client to
send and a stray field there risks a 400 on every step; the shipped effort
default dropped from `high` to `medium`, and a configured effort goes to the
Anthropic family only. The user asked for more than the review proposed: a
per-chat reasoning-effort row on the chat settings page (`CSET-13`), which the
chat carries into its requests (`SESS-40`) and saves only when it has one of its
own (`STORE-37/38`, so a chat saved before this reads as "no effort of its own"
and no migration was needed).

**The lower compaction trigger too**, 2026-11-13 (`db414ac feat: compact earlier,
at 100k or 60% of the window (COMPACT-6, COMPACT-28)`): the trigger is
`min(100,000, 60% of the window)` instead of `min(150,000, 80%)`, and
`COMPACT-28`'s working set dropped from 40,000 estimated tokens to 25,000 to keep
its quarter-of-the-budget relationship, so the ladder still has room to reach the
50,000 target. For the 200k model the chats run on, that is 50% of the window
rather than 75%, and a large window can no longer grow past 100,000 whatever its
size. The cost is honest: more chats will compact — mostly by elision, with a
summary only when the ladder cannot reach the target — and an elided file has to
be re-read. A chat that saved its own compaction settings keeps them; one that
never did picks the new defaults up.

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
`Elia.StepTiming.load/1` (`lib/elia/step_timing.ex`). The measurement this
proposal was for was taken on 2026-11-26: see **Speed review, 2026-11-26**
below.

## Ranked proposals

| # | Change | Kind | Expected | Status 2026-11-13 |
| --- | --- | --- | --- | --- |
| 1 | Per-worktree lock around mount setup (ISOL-28/27) | code + spec | removes 8.8% failures | **done** (`9bf6184`) |
| 2 | `AGENTS.md`: batch known lookups in one step | instructions | up to −27% round trips | **done** (`36ea73e`) |
| 3 | `AGENTS.md`: cheaper orientation (one topic doc, grep first) | instructions | −10 steps per coding chat | **done** (`36ea73e`), five pages kept |
| 4 | Per-step timing recorded | code + spec | makes future reviews measurable | **done** (`11478c4`) |
| 5 | Search tool that returns matched regions | code + spec | 4 steps → 1–2 per "grep then read" | **done** (`a4651d9`), FILE-24..FILE-30 |
| 6 | `edit_file` whitespace-tolerant retry, argument defaults | code + spec | ~80 wasted calls | **done** (`f69986b`), FILE-31..FILE-38 — retry, but no defaults (FILE-37) |
| 7 | Cache breakpoints on OpenRouter; effort default | code + spec | shorter and cheaper steps | **done** (`56d6b6b`), LLM-37..39, CSET-13, SESS-40, STORE-37/38 |
| 8 | Compact tool results before prose | code + spec | smaller views in long chats | no change needed (COMPACT-14..16) |

## Open questions

Settled by the overlay work on 2026-11-12 (bwrap 0.12, scratch overlays):

- **Overlapping lifetimes don't collide.** Two mounts started at the same
  instant fail; a mount started a second after another succeeds while the first
  is still up. So a terminal's session-long mount (TERM-7) is harmless and the
  per-chat jail is not needed for correctness — the jail stays one per command
  (ISOL-28).
- **A shared jail per step is a speed option, not a fix.** It would mount once
  per step instead of once per command, but it needs a driver protocol inside the
  jail (framing, per-command timeouts and exits), and ISOL-28 removes the failure
  without it. Not proposed.
- **Batching shell calls stays safe without namespace sharing**, because each
  command keeps its own jail and its own `/tmp` and pid namespace.

Still open:

- The measurement half of proposal 4 was taken on 2026-11-26 — see **Speed
  review, 2026-11-26** below — and it no longer has to run outside a chat's jail:
  the `chat_timings` tool reads the `.timing` files through the harness (TIME-11),
  so a chat whose jail is on can take it, where `.elia/sessions` is out of a
  command's reach (ISOL-6). What is still owed is the other half — turning a
  measurement into a number for what 2, 3, 5 and 6 saved — which needs the
  records to say more than a chat's totals (proposal 1 below).

Landed alongside this review's proposals, but not one of them (2026-11-13): the
worktree build cache (`BUILD-1..BUILD-6`, `d35be55`/`1f9d17a` — a chat's first
compile 35 s → 5 s) and the shell and `run_tests` timeout bounds (SHELL-10,
VERIFY-1).

# Speed review, 2026-11-26

The first reading of the `.timing` records (TIME-1 to TIME-10), through the
`chat_timings` tool (TIME-11 to TIME-18) as the deployed app provides it. Not a
spec: findings and proposals, for discussion. Every figure below is one call of
that tool, so the whole pass can be taken again unchanged.

Status: review. The findings are measurements of what the records already held;
none of the proposals at the end is implemented.

## Method

`chat_timings` with no `id` — the 20 newest chats of this project that have
records, 1,134 steps — plus one older chat by id (`q150vbPWtfXA`, 79 steps) as a
check on the trouble figure. Where the 2026-11-12 pass counted messages in saved
chats, this reads the durations the loop measured while running (TIME-1, TIME-3),
so a step's 6 s is 6 s rather than an inference from counts.

What the method cannot see, and why it matters here:

- **No per-step or per-call detail.** `chat_timings` reports a chat's totals
  (TIME-13); the per-call timings (TIME-4) are in the `.timing` files, which a
  command cannot read (ISOL-6) and no tool surfaces. So "which tool call cost
  40 s" is not answerable today, and the per-step figures below are means
  standing in for distributions (proposal 1).
- **The newest 20 chats that have records** (TIME-12, TIME-17): older chats, and
  chats that ran before the records existed, are outside the sample.
- **A chat's sums are dominated by its longest idle stretches**, so a total over
  chats is not a measure of work (finding 1).
- **The figures are per chat and the chats ran in parallel**, so the totals are
  chat-time — a sum over chats, not a wall clock.
- **No record carries the model that answered** (TIME-2), so the cost below is
  priced at the model this chat runs.

## The shape of the work

| | 20 newest chats with records |
| --- | --- |
| steps | 1,134 |
| `model_ms` | 6,981,202 (116 min) |
| `tool_ms` | 7,351,877 (122 min) |
| `waited_ms` | 48,262,986 (804 min) |
| input tokens | 80,094,791 |
| output tokens | 1,233,689 |

Per step: **6.2 s** of model, **6.5 s** of tools, **70.6k** input tokens, **1.1k**
output tokens. At the price OpenRouter listed the model this chat runs on
2026-11-26 (`deepseek/deepseek-v4.1-flash`, $0.0507 per million in, $0.2028 per
million out) those 1,134 steps cost about **$4.31**, some $0.0038 a step — and
cached prompt reads would put it below that, since a record keeps no cache split
(TIME-5).

## 1. Almost all of the "waiting" is a chat sitting idle

`waited_ms` is 48.26M ms — 77% of everything the records measured — and 99.8% of
it is `answer_wait_ms` (48.18M; approval waits are 84k in total and retry waits
zero). Two chats are 92% of that: `ou9jtfbDN6UO` ("Chats that stop without an
error", 9.0 h) and `vEqnAezQYlNQ` ("bin/test retries a flaky partition", 3.4 h).
Take those two out and the other 18 chats wait 59 min over 1,021 steps: 3.5 s a
step of waiting against 10.4 s a step of work, a quarter of their time rather
than four fifths.

The figure is honest — a chat that asks a question and waits hours for the answer
did wait hours — but summing it turns a project's "where did the time go" into
"how long did we leave chats open". Those two chats are not slow. They were
waiting for a person.

## 2. Model time and tool time are equal, and tool time spreads 90×

116 min of model against 122 min of tools. Per chat, `tool_ms` per step runs from
0.3 s (`RwLR4vtzuY0W`, a reading-only chat) to 26.2 s (`q150vbPWtfXA`), and the
high end is uniformly a chat that ran the suite:

| chat | steps | tool s/step | model s/step |
| --- | --- | --- | --- |
| `q150vbPWtfXA` Deploy failed: jail_test failure | 79 | 26.2 | 15.0 |
| `pLbBqTs64tPa` 003 Lower the suite's floor | 66 | 18.5 | 6.3 |
| `VZMMKoau548P` Terminal icon in chat lists | 106 | 9.8 | 6.1 |
| `ziFDfYl0rUVr` Run credo and fix findings | 22 | 7.4 | 6.1 |
| `wy0uQDpi_-ET` Auto-dismissing flash toasts | 88 | 6.6 | 4.8 |
| `RwLR4vtzuY0W` Elia vs stem AGENTS.md | 19 | 0.3 | 6.7 |

A chat's tool time is therefore mostly a question of how often it runs
`mix precommit`, which is what the suite work (`d0af060`, SUITE-14..SUITE-18)
went after: the suite's critical path 104 s → 64 s, and `deployment_test.exs`
alone 60.2 s → 44.6 s. What the remaining 122 min went on, this pass cannot say —
that is what proposal 1 asks for.

## 3. Every step reads 70k tokens and writes 1.1k

65 input tokens for every output token, and a mean request of 70.6k against a
compaction trigger of 100k: `min(budget, fraction × window)` with a budget of
100,000 and a fraction of 0.6 (COMPACT-6, `config/config.exs`), where the window
is 1M for this model, so the budget is the binding limit. Chats therefore run
near the trigger for much of their life — the largest chat sampled
(`DECYZCppHlrb`, 128 steps) averaged 80.6k in and 1.2k out.

COMPACT-6 says the budget is there to bound cost and latency on purpose, so this
is not a defect. It is, however, the knob that model time and the token bill both
hang on, and it is per chat (COMPACT-9). Nothing in this pass says which way to
turn it; that needs a chat measured at a lower budget, which the records can now
do (proposal 4).

## 4. The trouble figure counts the trouble we don't have

`failed_or_retried` is **0** across all 1,213 steps sampled — including
`q150vbPWtfXA`, whose own title is a failed deploy. That is TIME-14 working as
written: it counts a step whose model request was retried or came back `error` or
`refused`. The failures this project actually hits are *tool* failures — a failing
test, a refused deploy — which TIME-4 records per call (`name`, `ms`, `failed`)
and no figure surfaces. A chat can be 26 s a step of failed deploys and read as
untroubled (proposal 2).

## 5. The model-retry path did not fire in the sample

`retry_wait_ms` is zero, and no step of the 1,213 has an attempt above 1. RETRY-1
to RETRY-5 is insurance these chats did not need, and the same reading means the
records cannot yet show what a retried step costs. 21 chats is a sample, not a
census.

## Ranked proposals

| # | Change | Kind | Expected | Status |
| --- | --- | --- | --- | --- |
| 1 | A per-step/per-call view over the records — the slowest steps and the calls in them, from TIME-4's data, as a `chat_timings` listing or a page | code + spec (TIME-13, TIME-15, the `Out of scope` line) | turns "122 min of tools" into the twenty calls that are half of it, and means into distributions — the missing half of every finding above | proposed |
| 2 | A trouble figure that includes tool failures: `failed_tool_calls`, and the slowest call, from the records | code + spec (TIME-14) | friction visible where it happens (finding 4) | proposed |
| 3 | Report waiting so it cannot mislead: keep `waited_ms`, add a per-step figure or a per-wait cap so one idle chat cannot dominate a project total | code + spec (TIME-13, TIME-15) | the headline total becomes a work figure (finding 1) | proposed |
| 4 | Measure the compaction budget: run a chat at a lower budget (COMPACT-9) and compare `model_ms` and tokens per step | measurement; a config default only if it wins | if model time tracks context, a lower trigger cuts both, at the cost of more compaction passes and lost context (finding 3) | proposed |
| 5 | A chat's own timing in the UI: model against tool against wait, and the slowest steps, on the chat page | code + spec (the `Out of scope` line) | the user sees a slow chat without asking an agent | proposed |
| 6 | Rotate the records: a size or age bound on `<chat id>.timing` | code + spec (TIME-6) | bounded files (the largest chat sampled has 128 steps) | proposed |

## Open questions

- Is `answer_wait_ms` a figure a *summary* should carry at all? It is the one
  number that measures the user rather than the app (finding 1).
- Should a listing include chats with no records, so "this chat has never been
  measured" is visible rather than absent (TIME-17)?
- Does the 20-chat window need a `since`, so the same measurement can be taken
  again in a month and compared (TIME-12)?
- The 2026-11-12 review closed its proposal 8 ("compact tool results before
  prose") as needing no change. With 70.6k tokens read per step against 1.1k
  written, view size is now measurable — worth re-checking rather than assuming.
