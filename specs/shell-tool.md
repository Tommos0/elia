# Shell tool

Status: Implemented

The `shell` tool runs a command on the user's machine, once the user has
approved it.

A call's timeout is a setting with a ceiling (SHELL-10): the default is 300s,
because a compile or a whole test suite is an ordinary command rather than a
long one, and the most a call may ask for is 1,800s. Before it was 60s with no
ceiling — a `mix precommit` through the tool was killed while it compiled, and
a call could equally have asked for a day. The deadline also had to hold for a
command that keeps writing output (SHELL-11), which is the shape a stuck tool
call takes.

## Requirements

- **SHELL-1** Every `shell` call needs approval.
- **SHELL-2** The command runs with `bash -c` where bash is installed,
  otherwise with POSIX `sh -c` (`Elia.Shell.shell/1`), in the workspace root,
  with stdin connected to `/dev/null`, so it can never wait for input. The
  shell can be overridden per call with the `:shell` option.
- **SHELL-3** The command runs in its own process group where `setsid` is
  available. On timeout the whole group is killed. The timeout is
  `timeout_seconds`, or the configured default (300s), and never more than the
  configured maximum (SHELL-10).
- **SHELL-4** The result is the combined stdout and stderr followed by
  `[exit: <status>]`. Exit status 0 is a success; anything else, including a
  timeout (`[exit: timeout after Ns]`), is an error result.
- **SHELL-5** Output longer than `max_output` characters (default 30,000) is
  cut in the middle and replaced with a marker that gives the number of
  characters removed.
- ~~**SHELL-6** The workspace is checkpointed before the command runs
  (CKPT-2).~~ Retired: nothing is checkpointed (CKPT).
- **SHELL-7** The shell isn't sandboxed: an approved command can do anything,
  including get around the workspace policy. The approval prompt is the only
  safeguard.
- **SHELL-8** The skill's instructions open by telling the model not to use
  the shell to read, create or edit files (`cat`, `sed`, `echo >`, scripts that
  rewrite files), or to find text in the tree (`grep` — `search_files` is the
  tool for that, FILE-24), but to use the file tools, which apply the workspace
  policy. The `shell` tool's description says the same.
- **SHELL-9** The skill's instructions and the `shell` tool's description say
  which shell runs commands (`bash -c` where bash is installed, POSIX `sh -c`
  otherwise) and warn that bash-only syntax (`${PIPESTATUS[0]}`, `[[ ... ]]`,
  arrays, `set -o pipefail`) fails where the shell is `sh`.
- **SHELL-10** A call's timeout is bounded: `timeout_seconds` above the
  configured `max_timeout` (default 1,800s, 30 minutes) runs with the maximum
  instead, and the result names both what was used and what was asked for
  (`[exit: timeout after 1800s (asked for 86400s, the most is 1800s)]`), so the
  model sees the ceiling it hit. A value below 1 is an error result and no
  command runs. The tool's description (SHELL-8, SHELL-9) names the default
  (300s) and the maximum, so a command that needs longer than the default — a
  cold compile, a whole suite — is asked for on purpose, and the result says
  which ceiling it hit when the call was clamped to it.
- **SHELL-11** The timeout is a deadline for the whole run, not a quiet period:
  the run ends at it whatever the command is doing, a command that keeps
  writing output included. The deadline is re-checked as output arrives, so a
  command that floods stdout — an endless loop that prints is the shape a stuck
  tool call usually takes — cannot outlive it. A run that reaches the deadline
  is killed (SHELL-3) and reported as a timeout (SHELL-4), never as a command
  that finished.

## Configuration

```elixir
config :elia, Elia.Skills.Shell,
  default_timeout: 300,       # seconds, used when a call gives none
  max_timeout: 1_800,         # seconds, the most a call may ask for (SHELL-10)
  max_output: 30_000          # characters returned to the model
```

## Out of scope

- Bounding what the run keeps of a command's output while it runs: SHELL-5
  truncates at the end, so a command that floods stdout is killed at the
  deadline (SHELL-11) but can grow the buffer first. A running cap on the
  collected output is a separate change.
- The timeout of a folder skill's script tool, which comes from its
  `tools.json` (`specs/folder-skills.md`), and of the terminal (TERM).

## Implementation

`Elia.Skills.Shell` (the call's timeout and its clamp, SHELL-10),
`Elia.Shell` (the deadline of a run, SHELL-11).

## Tests

- `test/elia/skills/shell_test.exs` (the clamped timeout and the rejected value,
  SHELL-10; the instructions and the tool description — SHELL-8, SHELL-9).
- `test/elia/shell_test.exs` (the shell it runs the command with, the process
  group, the result's shape, the output cap, a run that floods stdout still
  ending at its deadline — SHELL-2 to SHELL-5, SHELL-11).
- `test/elia/agent_test.exs` (a call needs approval before it runs, SHELL-1).
- No test: SHELL-7 — that an approved command is not confined by the workspace
  policy is not asserted anywhere; the approval prompt is the safeguard.
