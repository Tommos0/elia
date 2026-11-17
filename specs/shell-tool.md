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
  otherwise with POSIX `sh -c` (`Elia.Shell.shell/1`), in the chat's working
  directory (WD-9), which is its workspace root until `cd` changes it,
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
- **SHELL-12** A command never outlives the process that is waiting on it in
  `Elia.Shell.run/2`. If that process exits before the command ends — its turn
  was stopped (SESS-43), its chat was deleted, or it crashed — the command's
  whole process group is killed, as on a timeout (SHELL-3): the shell and every
  process it started that is still in the group, jailed or not (ISOL-10).
  The kill happens as soon as that exit is seen, with no wait for the command's
  deadline. A command that ends on its own is never killed after it ends.
- **SHELL-13** A run whose output goes to the model — a `shell` call, a folder
  skill's script tool, and `Elia.Harness.run_tests/3` (VERIFY-1) — holds a
  bounded amount of that output while the command runs, however much the
  command writes and for however long: only the start and the end that SHELL-5
  can keep, and the bytes in between are counted and dropped as they arrive.
  The result is the same SHELL-5 cut, with one marker in the middle. When
  nothing was dropped while running, the marker gives the number of characters
  removed, exactly as before. When output was dropped while running, the
  dropped part is counted in bytes and added to that number, so for output with
  multi-byte characters it may count more than were really removed, never
  fewer. Output that fits within SHELL-5's cap is returned whole, as before.

## Configuration

```elixir
config :elia, Elia.Skills.Shell,
  default_timeout: 300,       # seconds, used when a call gives none
  max_timeout: 1_800,         # seconds, the most a call may ask for (SHELL-10)
  max_output: 30_000          # characters returned to the model
```

## Out of scope

- A cap on the output of the harness's own commands — its git calls, which
  parse what git prints, and the deploy's `mix deps.get`, asset build and
  compile. Their output is not the model's, and a cut there would silently
  change what is parsed, so `Elia.Shell.run/2` keeps all of it unless the caller
  asks for the cap of SHELL-13. A chat's terminal (TERM) has its own screen and
  no such buffer.
- The timeout of a folder skill's script tool, which comes from its
  `tools.json` (`specs/folder-skills.md`), and of the terminal (TERM).
- A process that leaves the command's process group (`setsid`, a daemon that
  detaches itself): SHELL-12 kills the group, and what has left it is out of
  reach. A chat's terminal keeps its own lifetime (TERM) and is not ended by a
  stopped turn.

## Implementation

`Elia.Skills.Shell` (the call's timeout and its clamp, SHELL-10),
`Elia.Shell` (the deadline of a run, SHELL-11).

## Tests

- `test/elia/skills/shell_test.exs` (the clamped timeout and the rejected value,
  SHELL-10; the instructions and the tool description — SHELL-8, SHELL-9).
- `test/elia/shell_test.exs` (the shell it runs the command with, the process
  group, the result's shape, the output cap, a run that floods stdout still
  ending at its deadline, a command whose waiting process exits being killed
  with its group, the output a capped run holds while it runs — SHELL-2 to
  SHELL-5, SHELL-11 to SHELL-13).
- `test/elia/agent_test.exs` (a call needs approval before it runs, SHELL-1).
- No test: SHELL-7 — that an approved command is not confined by the workspace
  policy is not asserted anywhere; the approval prompt is the safeguard.
