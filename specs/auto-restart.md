# Auto restart

Status: Implemented

If the application crashes (for example its top supervisor exceeds its restart
intensity), the Erlang VM used to stay up with no server in it, and someone had
to restart it by hand. `bin/serve` runs the server in a loop and starts it
again whenever it dies, and the application is marked permanent so that a
crash takes the VM down instead of leaving it empty.

## Requirements

- **RESTART-1** `bin/serve` runs the server command (by default
  `elixir --sname elia -S mix phx.server`, overridable with `ELIA_SERVE_CMD`)
  from the project root and starts it again whenever it exits with a non-zero
  status or is killed by a signal it didn't receive from the script.
- **RESTART-2** A command that exits with status 0 ends the loop, and
  `bin/serve` exits with 0. A deliberate clean shutdown therefore stays down.
- **RESTART-3** On `SIGINT` or `SIGTERM`, `bin/serve` forwards `SIGTERM` to the
  server, waits for it to exit and then exits itself without restarting.
- **RESTART-4** A run that lasted less than `ELIA_SERVE_MIN_UPTIME` seconds
  (default 10) counts as a quick failure. After one, the script waits before
  restarting: 1 second, doubling after each further quick failure up to
  `ELIA_SERVE_MAX_DELAY` seconds (default 30). A longer run resets the delay,
  and the next restart is immediate.
- **RESTART-5** Each start, exit and wait is announced on stderr with a
  `[serve]` prefix, including the exit status.
- **RESTART-6** `bin/serve` turns off the Erlang crash dump
  (`ERL_CRASH_DUMP_SECONDS=0`) so a crash loop doesn't fill the disk with
  `erl_crash.dump` files.
- **RESTART-7** In the `dev` and `prod` environments the application is
  permanent (`start_permanent` in `mix.exs`): if it stops, the VM halts with a
  non-zero status, which `bin/serve` turns into a restart. In `test` it isn't.

## Out of scope

- Restarting a server that wasn't started through `bin/serve`: nothing outside
  the VM exists to bring it back. Use a service manager (systemd, etc.) for
  that, with `bin/serve` as the command.
- Keeping the interactive IEx shell: `bin/serve` runs without one. Attach with
  `iex --sname dbg --remsh elia`.
- Restoring in-memory state. Chats are on disk (`Elia.Store`), but a turn
  that was running when the VM died isn't resumed.

## Implementation

`bin/serve`; `start_permanent` in `mix.exs`.

## Tests

`test/elia/serve_script_test.exs`.
