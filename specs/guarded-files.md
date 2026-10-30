# Guarded files

Status: Implemented

Some files enforce the guardrails themselves. Changes to them must not slip
into the running app through the dev server's automatic reloading. They take
effect only through `hot_reload`, which runs the tests first.

## Requirements

- **GUARD-1** These workspace paths are guarded:
  `lib/elia/{harness,checkpoint,workspace,guarded,tool,shell,skills,application}.ex`,
  `lib/elia/agent/loop.ex`, `lib/elia/skills/*.ex`,
  `lib/elia_web/endpoint.ex`, `config/**`, `mix.exs`, `mix.lock`,
  `test/elia/self_modification_test.exs` and `test/elia/guarded_test.exs`.
  Only paths in the core class can be guarded.
- **GUARD-2** At boot, the SHA-256 hashes of the guarded files are recorded
  as loaded.
- **GUARD-3** A guarded file counts as changed when it was added, removed or
  modified since it was last loaded (at boot or by a successful `hot_reload`).
- **GUARD-4** The endpoint's code reloader skips automatic reloading entirely
  while any guarded file has changed, and logs a warning naming those files.
  The warning is logged once for each distinct set of changed files.
- **GUARD-5** Automatic reloading resumes once no guarded file has changed:
  after a successful `hot_reload`, or after a rollback restores the files.
- **GUARD-6** The approval UI flags writes to guarded files, and `hot_reload`
  calls that would load guarded changes (UI-19).
- **GUARD-7** Changes to non-guarded files are picked up by the dev server's
  automatic reloading without `hot_reload`. `hot_reload` is required only to
  load changes to guarded files, which are otherwise held out (GUARD-3..5).

## Implementation

`Elia.Guarded`, the code reloader setting in `config/runtime.exs`.

## Tests

`test/elia/guarded_test.exs`, `test/elia_web/live/chat_live_test.exs`.
