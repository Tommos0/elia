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

### Auto-approval

The user can let a chat run a tool without asking each time. This is a per-chat,
per-tool switch; it never loosens what a tool's own policy refuses.

- **APPR-8** Each chat has a set of auto-approved tool names, empty by default.
  When a call that needs approval (APPR-1) is for a tool in the set, it skips
  the user: its status goes straight to `:approved` and it never shows as
  `:awaiting_approval`.
- **APPR-9** Auto-approval only replaces the user's decision. A call denied by
  policy (APPR-2) is still refused, and a tool that never needs approval is
  unaffected.
- **APPR-10** If every call in a step that needs approval is auto-approved, the
  session stays `:running` and the step proceeds. If only some are, the rest are
  shown to the user as in APPR-3, and the step waits for them (APPR-5).
- **APPR-11** Turning auto-approval on for a tool also approves that tool's calls
  that are awaiting approval right now. Turning it off affects only calls
  that come later.
- **APPR-12** The set belongs to one chat: changing it never affects another
  chat. It is saved with the chat (STORE-14) so it survives restarts.
- **APPR-13** Auto-approval can be turned on only for tools that can need
  approval, meaning anything but `:never` in APPR-7. Toggling any other name
  is rejected with `{:error, :not_approvable}`. A name already in the set can
  always be turned off, e.g. after its skill was removed.

Auto-approving `shell`, `write_file`/`edit_file`, script tools,
`hot_reload` or `rollback` lets the model act in that chat without review. The
UI says so next to the switch (UI-39).

## Implementation

`Elia.Tool`, `Elia.Agent.Loop`, `Elia.Agent.Session` (auto-approval is applied
in the session when the loop asks for approval, so the loop is unchanged).

## Tests

`test/elia/agent_test.exs`, `test/elia/auto_approve_test.exs`,
`test/elia/self_modification_test.exs`,
`test/elia_web/live/chat_live_test.exs`,
`test/elia_web/live/auto_approve_test.exs`.
