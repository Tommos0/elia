# Log viewer

Status: Implemented

A Logs page shows what the running Elia server has been logging — the same
lines you would otherwise read from the terminal or `journalctl`. It answers
"what did Elia just do / why did it fail?" without leaving the app. It is
linked from the [System dashboard](system-dashboard.md).

The output is captured in memory from the Erlang/Elixir logger, so it is the
server's own log, not a log file, and it does not survive a restart or a
deploy.

## Requirements

### Capture

- **LOG-1** The running server keeps its most recent log events in memory,
  captured from the Erlang/Elixir logger, so the app can show its own output.
  Every event the logger emits is captured; events below the configured level
  are never emitted and so are not captured.
- **LOG-2** Each captured entry records its UTC timestamp, its level, its
  formatted message and its metadata: the `mfa` (module, function, arity) and
  the pid when the logger provides them.
- **LOG-3** The buffer keeps at most 500 entries, newest first; a new entry
  past that drops the oldest.
- **LOG-4** Capturing never crashes or blocks the logger: an event is
  formatted and handed over without waiting, and a failure (for example the
  buffer not running yet) is ignored.

### Logs page

- **LOG-5** `/logs` lists the captured entries, newest first, with a count of
  those shown.
- **LOG-6** The page updates live as new entries arrive, without a reload.
- **LOG-7** The page filters the list by a minimum level (debug, info,
  notice, warning, error, critical, alert, emergency) and by a
  case-insensitive substring of the message. Both filters combine.
- **LOG-8** A "Clear" button empties the buffer; every open Logs page reflects
  it.
- **LOG-9** Each entry shows its time, level, message, and its source (module
  and pid) when present.
- **LOG-10** The System page has a "Logs" link to `/logs`.

## Out of scope

- Reading log files, persisting logs to disk, or a history across restarts and
  deploys.
- Aggregating logs across nodes: the buffer is per running server.
- Structured search, highlighting, or downloading.
- Access control: like Sessions, anyone who can reach the app sees it.

## Implementation

`Elia.Logs` (the ring buffer and its PubSub topic), `Elia.Logs.Handler` (the
logger handler that forwards events), `EliaWeb.LogsLive` (the page).

## Tests

`test/elia/logs_test.exs`, `test/elia_web/live/logs_live_test.exs`.
