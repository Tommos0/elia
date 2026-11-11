# Process priority

Status: Implemented

Elia runs heavy OS processes for a chat: a compile, a test suite, a preview's
asset build. They contend for the same CPU and the same disk as the server
that draws the UI, runs the agent loops, streams the model's answer and saves
the transcript, so a heavy command makes the app feel slow exactly while the
user is watching it. This feature starts every process Elia spawns *below* the
server's own scheduling priority: the CPU and the disk go to the server first
and the heavy work takes what is left. It needs no privileges and no
deployment change, because the lever is per child — a positive `nice` and a
low I/O class are what an unprivileged process may set for itself.

## Requirements

- **PRIO-1** Every OS process Elia starts runs at a lower CPU scheduling
  priority than the server: `Elia.Shell.run/2` starts the command through
  `nice` at the configured value (default 10, where the server runs at 0), so
  the BEAM's scheduler threads — and with them the LiveViews, the agent loops
  and the model streaming — are served first when a compile or a suite
  saturates the machine. `nice` *adds* to the priority the process would
  otherwise inherit, which is what makes this safe: lowering a priority is
  always allowed and can never fail, where setting an absolute value would ask
  to raise one. So a command that a command starts is lower still, down to 19,
  the most there is.
- **PRIO-2** It covers every process Elia spawns, not just the `shell` tool:
  the single spawn point is `Elia.Shell.execute/3`, which every tool call and
  harness step goes through (ISOL-1) — the `shell` tool, `run_tests`
  (VERIFY-1), a folder skill's script tools (FOLDER), the harness's own git
  calls (DEPLOY-9), the worktree dependency compile (ISOL-7) and a preview the
  chat runs by command (PREVIEW).
- **PRIO-3** The whole process tree gets it, jailed or not: `nice` (and
  `ionice`) set the priority on themselves and then `exec` the command, so the
  process Elia started is still the one the port reports — the session and
  process group leader whose group the timeout kills (SHELL-3, ISOL-10) — and
  everything the command starts inherits the priority. A jail doesn't change
  it: the values are the process's own, which the mount and pid namespaces
  leave alone.
- **PRIO-4** I/O priority too, so a compile's writes don't push the server's
  own reads (the chat list, the transcript save, a log line) behind them:
  where `ionice` is installed the command runs in the best-effort I/O class at
  the configured level (default 6), or in the idle class when configured as
  `:idle`. `ionice -t` is what runs it, so a host whose I/O scheduler refuses
  the setting still runs the command rather than failing it. `nil` turns it
  off.
- **PRIO-5** Both are configured, not hardcoded, and each is independently
  optional: `config :elia, Elia.Priority, nice: 10, ionice: 6`. A call may
  override them through `Elia.Shell.run/2`'s `:priority` (e.g.
  `priority: [nice: 0]`), so a step that should run at the server's own
  priority can ask for it: `nice: 0` adds nothing, and the command inherits
  the priority of whoever asked for it.
- **PRIO-6** Only the children are lowered: nothing raises the server's own
  priority and no privilege is ever needed — a positive `nice` and I/O class 2
  or 3 are what an unprivileged process may set for itself, while class 1
  (realtime) is not used. `nice: 0` or `nil`, a missing value, or a host
  without `nice` installed means the command runs as it did before, exactly as
  `ionice` does on its own. A configured value that isn't usable — a negative
  `nice`, an I/O value that isn't a level and isn't `:idle` — is not forced
  into a value of its own: that half is simply left out.
- **PRIO-7** Nothing else about a command changes: the same shell and script
  (SHELL-2), empty stdin, the same timeout, output truncation and result
  (SHELL-4, SHELL-5), the same jail, environment and profiles (ISOL-8,
  ISOL-10, ISOL-13) — the wrapper is a prefix on the executable and its
  arguments, and it says nothing in the command's output.
- **PRIO-8** The `shell` skill's instructions and the `shell` tool's
  description say a command runs at a lower scheduling priority than the
  server (SHELL-8, SHELL-9), so a command that seems slow while a compile runs
  is expected rather than broken, and a test of wall-clock speed is not run
  this way.
- **PRIO-9** A long-running process Elia spawns directly, rather than through
  `Elia.Shell`, is started through `Elia.Priority.spawn_argv/3` too, so PRIO-1
  and PRIO-4 hold for it as they do for a command: the terminal's tmux
  (TERM-8) and the local model server (LOCAL-12) are both started that way.

## Configuration

```elixir
config :elia, Elia.Priority,
  nice: 10,        # 1..19: how far below the server a command runs; 0/nil: as before
  ionice: 6        # 0..7 best-effort level, :idle, or nil for no I/O priority
```

## Out of scope

- **Raising the server's own priority.** A negative `nice` needs
  `CAP_SYS_NICE`, so a service unit or a sudoers rule would have to grant it.
  Lowering the children gives the server its priority without any of that.
- **A cgroup or a systemd slice** (`CPUWeight`, `CPUQuota`, `IOWeight`) around
  tool calls, which would bound their CPU and I/O in one place. It needs
  privileges, a deployment change, and it restricts the machine rather than
  ordering it.
- **A cap on how many heavy commands run at once**, and a queue for them; the
  one place that would matter today is the shared dependency compile, which is
  already serialised (ISOL-7).
- **A UI for it.** The values are configuration, shown nowhere: there is
  nothing to decide per chat, and a switch that only takes effect after a
  deploy would sit next to settings that apply at once (CONF).
- **Processes that aren't Elia's tool calls**: the small data-collection calls
  (`df` in `Elia.SystemStats`) and the browser the real-browser tests drive,
  which is a port of the test run rather than of `Elia.Shell` (BROWSER). A
  preview started by command is covered, since the whole tree under it is
  (PRIO-2).

## Implementation

`Elia.Priority` (the wrapper argv and the configuration), `Elia.Shell`
(`execute/3` starts the command through it, `run/2` takes `:priority`),
`Elia.Skills.Shell` (what the instructions and the tool description say,
PRIO-8).

## Tests

`test/elia/priority_test.exs` (the argv: the nice value, the I/O level and
class, the two switches, a missing program, a per-call override),
`test/elia/shell_test.exs` (a run reports the configured niceness and I/O
class for itself, `priority: [nice: 0]` reports none, a niced command is still
its own session leader, and a timeout still leaves nothing running).
