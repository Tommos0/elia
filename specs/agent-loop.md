# Agent loop

Status: Implemented

One turn of the agent: call the model, run the tools it asks for, send the
results back, and repeat until the model answers without calling a tool. At
the end, the turn's changes are verified.

## Requirements

- **LOOP-1** Each step sends the model the system prompt and tools of the
  currently loaded skills plus the full history. Skills and the project
  instructions (SKILL-10) are read again every step, so a skill reloaded or an
  `AGENTS.md` edited mid-turn applies from the next step.
- **LOOP-2** Text and reasoning deltas and provider notices are forwarded to
  the session as they stream.
- **LOOP-3** A turn stops with an error after 50 steps.
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

## Implementation

`Elia.Agent.Loop`, `Elia.Tool`.

## Tests

`test/elia/agent_test.exs`.
