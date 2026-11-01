# Agent loop

Status: Implemented

One turn of the agent: call the model, run the tools it asks for, send the
results back, and repeat until the model answers without calling a tool. At
the end, the turn's changes are verified.

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
- **LOOP-3** A turn stops with an error after the step limit: 100 steps unless
  the `:max_steps` option says otherwise (LOOP-16).
- **LOOP-4** If the model refuses (`stop_reason: :refusal`), the loop returns
  `:refused` and runs none of that response's tool calls.
- **LOOP-5** If a response hits the output limit without calling a tool, the
  turn ends with an error. If it hits the limit with tool calls, none of them
  run; each gets an error result saying the call may be incomplete.
- **LOOP-6** A tool call whose input wasn't valid JSON gets an error result
  containing the raw input as `{"INVALID_JSON": "<raw>"}`.
- **LOOP-7** A call to an unknown tool gets the error result
  "Unknown tool: <name>".
- **LOOP-8** Input is checked against the tool's schema: required keys and
  top-level primitive types. Invalid input gets an error result and the tool
  doesn't run.
- **LOOP-9** Approval is resolved as described in [Tool approval](tool-approval.md)
  before any tool in the step runs.
- **LOOP-10** The step's tools run concurrently. Results go back in the
  order the calls were made, as one tool message.
- **LOOP-11** Each running tool's status is reported as `:running`, then
  `:done`.
- **LOOP-12** A tool that raises gets the error result
  "Tool crashed: <message>"; the turn continues.
- **LOOP-13** When the model finishes, the turn is verified (VERIFY-3). If
  verification rolled the workspace back, the model gets a harness message
  explaining the rollback, with the test output, and the turn continues.
- **LOOP-14** If a second verification in the same turn rolls back, the turn
  ends with an error saying tests kept failing.
- **LOOP-15** Verification can be disabled with the `verify: false` option
  (used in tests).

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
  own root when unset) and `project` (the chat's project map, PROJ-9).

## Implementation

`Elia.Agent.Loop`, `Elia.Tool`.

## Tests

`test/elia/agent_test.exs`.
