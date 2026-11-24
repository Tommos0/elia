# Tool approval

Status: Implemented

Tools that can affect the machine wait for the user to approve them. Each
tool decides, per call, whether it runs freely, needs approval, or is
refused.

## Requirements

- **APPR-1** A tool's approval is `:never`, `:required`,
  `{:required, :always}`, or a function of the input and context that returns
  one of those or `{:deny, reason}`. `:required` is a call the chat's
  auto-approved set may wave through (APPR-8); `{:required, :always}` is one it
  may not (APPR-19).
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

  | Tool | Approval | Who has it |
  | --- | --- | --- |
  | `shell` | always (SHELL-1) | both |
| `spawn_task` | always (SUBTASK-2) | parent |
| `await_task` | never (SUBTASK-27) | parent |
  | `terminal_start` | always (TERM-10, TERM-25) | both |
  | `terminal_send` | always (TERM-32) | both |
  | `terminal_read` | never (TERM-26) | both |
  | `terminal_stop` | never (TERM-27) | both |
  | `set_title` | never (TITLE-5) | both |
  | `mark_done` | never (DONE-6) | both |
  | `list_chats`, `read_chat`, `search_chats` | never (HIST-10) | both |
  | `cd` | never (WD-6) | both |
  | `reload_skills`, `update_ledger` | never | both |
  | `ask_user` | never (ASK-1) | both |
  | `request_network_host` | never (NET-30) | both |
  | `view_image` | never (VISION-12) | both |

### Auto-approval

The user can let a chat run a tool without asking each time. This is a per-chat,
per-tool switch; it never loosens what a tool's own policy refuses.

- **APPR-8** Each chat has a set of auto-approved tool names. A new chat starts
  with every tool that can need approval in it (APPR-14); any other chat starts
  from its file, empty when it has none (STORE-15).
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

- **APPR-14** A chat that has no messages and no saved set is new (STORE-22),
  and its session starts with every tool that can need approval (APPR-13) in
  the auto-approved set, so the chat runs those tools without asking. The set is
  worked out from the project's skills when the session starts (PROJ-15), so a
  folder skill's script tools (FOLDER) are in it too. A chat that has messages
  keeps the set its file holds, empty when it has none (APPR-8, STORE-15), so a
  chat that existed before this change is not loosened; a caller that starts a
  session with its own list overrides the default (SESS-17), as a sub-task does
  with its parent's set (SUBTASK-6). The default is not a switch of its own:
  turning a tool off (UI-39) removes it from the set like any other (APPR-11),
  and the set is saved with the chat's first message (APPR-12, STORE-14).

- **APPR-19** Auto-approval never covers a call whose approval is
  `{:required, :always}` (APPR-1): while its tool is in the chat's set (APPR-8),
  the call is still shown to the user and the step waits for them (APPR-3,
  APPR-5). This is what a call that asks to run without the jail is (ISOL-32).
  A decision the user makes about it is unaffected: approving it, or a control
  that approves that tool's waiting calls (APPR-11), is theirs either way.

Auto-approving `shell` or a script tool lets the model act in that chat without
review. The UI says so next to the switch (UI-39).

A new chat starts with every approvable tool auto-approved (APPR-14), because
the jail (ISOL-1) is what made the prompt the only safeguard for the tools that
run processes. With the file tools retired (FILE) every file operation is a
command, so `shell` is the one tool left that can change a file in the
workspace, and in a new chat it is auto-approved like any other approvable tool;
a chat that wants its commands reviewed turns that switch off (UI-39).

### The table

- **APPR-15** The APPR-7 table names every built-in tool the harness can offer
  an agent, by the tool's own name — not by a description of a class of tools
  where a name would do — with one row per tool or per group of tools. A row may
  name several tools, comma-separated, and may carry a note naming the
  requirement the row's facts come from. A folder skill's script tool has no
  fixed name and so has no row: it always needs approval (FOLDER-8).
- **APPR-16** An approval cell in the APPR-7 table is either `never` or
  `always`: `never` is a tool that never needs approval, and `always` one that
  needs it for every call. The `path read` and `path write` kinds this
  requirement used to allow retired with the file tools (FILE), since no tool
  left judges a path for its approval.
- **APPR-17** The APPR-7 table's third column says which chats a tool is offered
  to: `parent` for one only a chat that can spawn sub-tasks has, `child` for one
  only a sub-task chat has, and `both` for one every chat has (SUBTASK-1).
- **APPR-18** A test reads the APPR-7 table out of `specs/tool-approval.md` and
  compares it with the tools the built-in skills offer and with the approval
  each tool declares (APPR-1), naming the tool and what differs: a tool that is
  offered and not in the table, one in the table that is not offered, and one
  whose row states an approval or a role the tool doesn't have each fail the
  suite.

## Implementation

`Elia.Tool`, `Elia.Agent.Loop`, `Elia.Agent.Session` (auto-approval is applied
in the session when the loop asks for approval, which passes each call's
approval with it, so a call that must ask always does — APPR-19).

`test/elia/tool_approval_test.exs` derives what a row claims from the tool
itself, not from a second list: a tool whose approval is a function (APPR-1) is
asked for its decision on a sample input, so the row's kind (APPR-16) and the
approval the cell names come from the tool and cannot drift in their turn. A
hand-written list would be a copy of the table, free to disagree with it. The
role column (APPR-17) is derived the same way, from the built-in skills and the
`task` skill a sub-task chat gets (SUBTASK-1), and the toolset comes from
`config :elia, Elia.Skills, builtin:`, so a built-in skill or tool added later
is compared without an entry in the test.

## Tests

- `test/elia/agent_test.exs` (a tool's approval, a denial by policy, the calls of
  a step shown together and decided one at a time, nothing running until every
  one is decided, the result a denied call gets — APPR-1 to APPR-6).
- `test/elia/tool_approval_test.exs` (every tool the built-in skills offer in the
  APPR-7 table, the approval a row states against the one the tool declares and
  its role against the toolset — APPR-7, APPR-15 to APPR-18).
- `test/elia/auto_approve_test.exs` (the saved set, a chat's own set, what
  auto-approval replaces, a step all auto-approved, a tool turned on, the
  default set, and a call an auto-approval does not cover — APPR-8 to APPR-14,
  APPR-19).
- `test/elia_web/live/chat_live_test.exs` (the approval prompt and the toolbar,
  APPR-14).
- `test/elia_web/live/auto_approve_test.exs` (the popover, its switches and what
  turning one on does — APPR-8, APPR-11 to APPR-14).