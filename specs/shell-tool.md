# Shell tool

Status: Implemented; SHELL-10 and SHELL-11 are Draft

The `shell` tool runs a command on the user's machine, once the user has
approved it.

## Requirements

- **SHELL-1** Every `shell` call needs approval.
- **SHELL-2** The command runs with `bash -c` where bash is installed,
  otherwise with POSIX `sh -c` (`Elia.Shell.shell/1`), in the workspace root,
  with stdin connected to `/dev/null`, so it can never wait for input. The
  shell can be overridden per call with the `:shell` option.
- **SHELL-3** The command runs in its own process group where `setsid` is
  available. On timeout the whole group is killed. The timeout is
  `timeout_seconds`, or the configured default (60s), and never more than the
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
  rewrite files) but to use the file tools, which apply the workspace policy.
  The `shell` tool's description says the same.
- **SHELL-9** The skill's instructions and the `shell` tool's description say
  which shell runs commands (`bash -c` where bash is installed, POSIX `sh -c`
  otherwise) and warn that bash-only syntax (`${PIPESTATUS[0]}`, `[[ ... ]]`,
  arrays, `set -o pipefail`) fails where the shell is `sh`.
- **SHELL-10** A call's timeout is bounded: `timeout_seconds` above the
  configured `max_timeout` (default 1,800s, 30 minutes) runs with the maximum
  instead, and the result names both what was used and what was asked for
  (`[exit: timeout after 1800s (asked for 86400s, the most is 1800s)]`), so the
  model sees the ceiling it hit. A value below 1 is an error result and no
  command runs. The tool's description (SHELL-8, SHELL-9) names the default and
  the maximum, so a long build or a cold compile can be asked for on purpose —
  the default is for the common command, not for the longest one.
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
  default_timeout: 60,        # seconds, used when a call gives none
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

`test/elia/skills/shell_test.exs` (the clamped timeout and the rejected value,
SHELL-10), `test/elia/shell_test.exs` (a run that floods stdout still ends at
its deadline, SHELL-11), `test/elia/agent_test.exs`.
