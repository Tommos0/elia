# Guarded files

Status: Implemented

Code changes must not reach the running app halfway through an edit: two
sequential edits can leave the project in a state that doesn't compile. In
development the endpoint therefore never reloads code on its own. Every change
to a code file stays pending until `hot_reload` runs the tests and loads it.

Some of those files also enforce the guardrails themselves. They are
*guarded*: the approval UI flags writes to them (GUARD-6).

## Requirements

- **GUARD-1** These workspace paths are guarded:
  `lib/elia/{harness,checkpoint,workspace,guarded,tool,shell,skills,application}.ex`,
  `lib/elia/agent/loop.ex`, `lib/elia/skills/*.ex`,
  `lib/elia_web/endpoint.ex`, `lib/elia_web/recovery.ex`, `config/**`, `mix.exs`, `mix.lock`,
  `test/elia/self_modification_test.exs` and `test/elia/guarded_test.exs`.
  Only paths in the core class can be guarded.
- ~~**GUARD-2** At boot, the SHA-256 hashes of the guarded files are recorded
  as loaded.~~ Superseded by GUARD-9.
- ~~**GUARD-3** A guarded file counts as changed when it was added, removed or
  modified since it was last loaded.~~ Superseded by GUARD-10.
- ~~**GUARD-4** The endpoint's code reloader skips automatic reloading entirely
  while any guarded file has changed.~~ Superseded by GUARD-8 and GUARD-11.
- ~~**GUARD-5** Automatic reloading resumes once no guarded file has
  changed.~~ Superseded by GUARD-8: automatic reloading no longer exists.
- **GUARD-6** The approval UI flags writes to guarded files, and `hot_reload`
  calls that would load pending changes (UI-19).
- ~~**GUARD-7** Changes to non-guarded files are picked up by the dev server's
  automatic reloading without `hot_reload`.~~ Removed: every change now needs
  `hot_reload` (GUARD-8).
- **GUARD-8** The endpoint's code reloader (and the LiveView live-reload
  notifier) never recompiles or loads code on a request. Only `hot_reload`
  loads code (HOT-5), whichever file changed.
- **GUARD-9** The code files are `lib/**`, `config/**`, `mix.exs` and
  `mix.lock`. At boot, the SHA-256 hashes of the code files are recorded as
  loaded.
- **GUARD-10** A code file is pending when it was added, removed or modified
  since it was last loaded (at boot or by a successful `hot_reload`).
- **GUARD-11** While any code file is pending, a request makes the code
  reloader log a warning naming those files. The warning is logged once for
  each distinct set of pending files.
- **GUARD-12** A file stops being pending after a successful `hot_reload`, or
  when a rollback restores its loaded contents.
- **GUARD-13** The dev server's browser live reload doesn't watch `lib/`
  files, since saving them doesn't change the running app (GUARD-8). Static
  asset changes still reload the page.

## Implementation

`Elia.Guarded`, the code reloader setting in `config/runtime.exs`.

## Tests

`test/elia/guarded_test.exs`, `test/elia_web/live/chat_live_test.exs`.
