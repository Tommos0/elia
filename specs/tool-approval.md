# Tool approval

Status: Implemented

Tools that can affect the machine wait for the user to approve them. Each
tool decides, per call, whether it runs freely, needs approval, or is
refused.

## Requirements

- **APPR-1** A tool's approval is `:never`, `:required`, or a function of the
  input and context that returns one of those or `{:deny, reason}`.
- **APPR-2** A call that is denied by policy doesn't run and gets `reason` as
  an error result. The user isn't asked.
- **APPR-3** All calls in a step that need approval are shown to the user at
  once. The session status becomes `:awaiting_approval` and each of those
  calls gets the status `:awaiting_approval`.
- **APPR-4** The user decides on each call separately. Approving sets the call
  to `:approved`; denying sets it to `:done`. Deciding on a call that isn't
  pending returns `{:error, :not_pending}`.
- **APPR-5** No tool in the step runs until every pending call is decided.
  Then the session goes back to `:running`.
- **APPR-6** A denied call gets the error result "The user denied this tool
  call." Approved calls and calls that needed no approval run normally.
- **APPR-7** The approval required by each built-in tool:

  | Tool | Approval |
  | --- | --- |
  | `shell` | always |
  | folder skill script tools | always |
  | `read_file` | only outside the workspace |
  | `write_file`, `edit_file` | see FILE-5 |
  | `hot_reload`, `rollback` | always |
  | `reload_skills`, `run_tests`, `list_checkpoints` | never |

## Implementation

`Elia.Tool`, `Elia.Agent.Loop`, `Elia.Agent.Session`.

## Tests

`test/elia/agent_test.exs`, `test/elia/self_modification_test.exs`,
`test/elia_web/live/chat_live_test.exs`.
