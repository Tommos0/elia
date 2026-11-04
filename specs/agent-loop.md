# Agent loop

Status: Implemented

One turn of the agent: call the model, run the tools it asks for, send the
results back, and repeat until the model answers without calling a tool.

## Requirements

- **LOOP-1** Each step sends the model the system prompt and tools of the
  currently loaded skills plus the **request view** (COMPACT-2) derived at that
  step from the full history it was given and the chat's compaction state, so the
  ladder may run deeper while the turn is running (COMPACT-5, COMPACT-29).
  Skills and the project instructions (SKILL-10) are read again every step, so a
  skill reloaded or an `AGENTS.md` edited mid-turn applies from the next step.
  They are the chat's project's skills and `AGENTS.md` (PROJ-15).
- **LOOP-2** Text and reasoning deltas and provider notices are forwarded to
  the session as they stream.
- **LOOP-3** A turn ends after the step limit: 100 steps unless the `:max_steps`
  option says otherwise (LOOP-16). The loop returns `{:limit, {:steps, n}}`, and
  the session writes why the turn stopped into the transcript (STOP-1, STOP-2).
  With the `:pause_on_limit` option it pauses instead (LOOP-19).
- **LOOP-4** If the model refuses (`stop_reason: :refusal`), the loop returns
  `:refused` and runs none of that response's tool calls.
- **LOOP-5** If a response hits the output limit without calling a tool, the
  turn ends with an error. If it hits the limit with tool calls, none of them
  run; each gets an error result saying the call may be incomplete.
- **LOOP-6** A tool call whose input wasn't valid JSON gets an error result
  containing the raw input as `{"INVALID_JSON": "<raw>"}`.
- **LOOP-7** A call to an unknown tool gets the error result
  "Unknown tool: <name>".
- **LOOP-8** Input is checked against the tool's schema: required keys,
  top-level primitive types and, for an array, the type of its items and any
  `maxItems` (ASK-12). Invalid input gets an error result and the tool doesn't
  run.
- **LOOP-9** Approval is resolved as described in [Tool approval](tool-approval.md)
  before any tool in the step runs.
- **LOOP-10** The step's tools run concurrently. Results go back in the
  order the calls were made, as one tool message.
- **LOOP-11** Each running tool's status is reported as `:running`, then
  `:done`.
- **LOOP-12** A tool that raises gets the error result
  "Tool crashed: <message>"; the turn continues.
- ~~**LOOP-13** When the model finishes, the turn is verified (VERIFY-3). If
  verification rolled the workspace back, the model gets a harness message
  explaining the rollback, with the test output, and the turn continues.~~
  Retired: a turn is not verified (see `specs/verification.md`).
- ~~**LOOP-14** If a second verification in the same turn rolls back, the turn
  ends with an error saying tests kept failing.~~ Retired: nothing is rolled
  back.
- ~~**LOOP-15** Verification can be disabled with the `verify: false` option
  (used in tests).~~ Retired: there is no verification step to disable.

- **LOOP-16** The `max_steps` option sets the step limit of LOOP-3 for the
  turn. Sessions pass it from their loop options (used by sub-tasks, SUBTASK-12).
- **LOOP-17** The `skills` option is resolved against the chat's project
  (`Elia.Skills.resolve/2`, PROJ-21): a list of skills, a function of no
  arguments returning one, or `nil` meaning the project's own skills. A function
  is called every step (LOOP-1); the session also uses it for the context
  breakdown and for which tools can be auto-approved.
- **LOOP-18** Besides `session_id` and `turn_id`, the tool context holds
  `call_id` (the id of the call being run), `loop_opts` (the loop's options, so
  a tool can start a session like this one, SUBTASK-5), `workspace` (the
  workspace root the turn runs in: the chat's project folder, PROJ-12, or Elia's
  own root when unset) and `project` (the chat's project map, PROJ-9), `jail`
  (whether this chat's commands run in the jail, ISOL-15; `nil` means no chat,
  and the default, which is jailed) and `answer` (the user's answer, for a tool
  that asks one, LOOP-21; `nil` for every other call).

- **LOOP-19** With the `:pause_on_limit` option (default false), a limit pauses
  the turn instead of ending it: the loop sends the session
  `{:loop_pause, pid, limit}` (`limit` is `{:steps, n}`, `{:time, ms}` or
  `{:tokens, n}`, LOOP-22) and blocks. `{:pause_decision, :continue}` resumes it
  with the step count, the wall-clock budget and the token total started over;
  `{:pause_decision, :fail}` ends the turn, reporting the limit the turn was
  paused at (LOOP-3, LOOP-20, LOOP-22), so the session says the turn stopped
  there (STOP-1, STOP-2).
- **LOOP-20** The `:budget_ms` option (default nil) is a wall-clock budget for
  the turn. The loop checks it at the start of each step: when the time spent
  exceeds it, it is a limit like LOOP-3. Time spent waiting for the user's
  approval decisions (LOOP-9), for an answer to a question (LOOP-21) and time
  spent paused (LOOP-19) don't count.

- **LOOP-21** A call to a tool that asks the user (`asks_user`, ASK-1) is put to
  the user instead of being run: the loop sends the session
  `{:loop_await_input, pid, calls}` and blocks until it replies
  `{:input_answers, %{call_id => answer}}` (SESS-34). The answers are handed to
  those tools as `ctx[:answer]` when they run (LOOP-18), so the tool turns the
  answer into the call's result (ASK-5). The step's approvals are resolved first
  (LOOP-9), then its questions, then the step's tools run (LOOP-10); a denied
  call (APPR-6) is not put to the user.

- **LOOP-22** The `:token_budget` option (default nil) is a token budget for the
  turn (LIMIT-12). The loop adds up what the provider reported for each step it
  has run — input counted as CTX-6 counts it, prompt-cache reads and writes
  included, plus output — and checks the total at the start of every step, as it
  checks the wall-clock budget (LOOP-20): when the total exceeds the budget, it
  is a limit like LOOP-3, reported as `{:tokens, n}` (LOOP-19) and ended with
  the same option's choice of pause or stop. A usage report that carries no
  counts adds nothing to the total. A resume starts the total over (LOOP-19).

## Implementation

`Elia.Agent.Loop`, `Elia.Tool`.

## Tests

`test/elia/agent_test.exs`.
