# Shell tool

Status: Implemented

The `shell` tool runs a command on the user's machine, once the user has
approved it.

## Requirements

- **SHELL-1** Every `shell` call needs approval.
- **SHELL-2** The command runs with `sh -c` in the workspace root, with stdin
  connected to `/dev/null`, so it can never wait for input.
- **SHELL-3** The command runs in its own process group where `setsid` is
  available. On timeout the whole group is killed. The timeout is
  `timeout_seconds`, or the configured default (60s).
- **SHELL-4** The result is the combined stdout and stderr followed by
  `[exit: <status>]`. Exit status 0 is a success; anything else, including a
  timeout (`[exit: timeout after Ns]`), is an error result.
- **SHELL-5** Output longer than `max_output` characters (default 30,000) is
  cut in the middle and replaced with a marker that gives the number of
  characters removed.
- **SHELL-6** The workspace is checkpointed before the command runs (CKPT-2).
- **SHELL-7** The shell isn't sandboxed: an approved command can do anything,
  including get around the workspace policy. The approval prompt is the only
  safeguard.
- **SHELL-8** The skill's instructions open by telling the model not to use
  the shell to read, create or edit files (`cat`, `sed`, `echo >`, scripts that
  rewrite files) but to use the file tools, which apply the workspace policy.
  The `shell` tool's description says the same.

## Configuration

```elixir
config :elia, Elia.Skills.Shell, default_timeout: 60, max_output: 30_000
```

## Implementation

`Elia.Skills.Shell`, `Elia.Shell`.

## Tests

`test/elia/skills/shell_test.exs`, `test/elia/agent_test.exs`.
