# Guarded files

Status: Retired

Retired: the filesystem isolation of per-chat worktrees (DEPLOY) replaced this
feature. The tree a chat edits is never the tree that runs, so holding edits
"pending" until a reload protects nothing, and the guarded-file list was only a
nudge in the approval UI. The one behaviour worth keeping — the running app
never reloads code on a request — moved to DEPLOY-8. See `specs/deployment.md`.

## Requirements

- ~~**GUARD-1** These workspace paths are guarded:
  `lib/elia/{harness,checkpoint,workspace,guarded,tool,shell,skills,application}.ex`,
  `lib/elia/agent/loop.ex`, `lib/elia/skills/*.ex`,
  `lib/elia_web/endpoint.ex`, `lib/elia_web/recovery.ex`, `config/**`, `mix.exs`, `mix.lock`,
  `test/elia/self_modification_test.exs` and `test/elia/guarded_test.exs`.
  Only paths in the core class can be guarded.~~ Retired: there is no
  guarded-file list (DEPLOY-11).
- ~~**GUARD-2** At boot, the SHA-256 hashes of the guarded files are recorded
  as loaded.~~ Superseded by GUARD-9.
- ~~**GUARD-3** A guarded file counts as changed when it was added, removed or
  modified since it was last loaded.~~ Superseded by GUARD-10.
- ~~**GUARD-4** The endpoint's code reloader skips automatic reloading entirely
  while any guarded file has changed.~~ Superseded by GUARD-8 and GUARD-11.
- ~~**GUARD-5** Automatic reloading resumes once no guarded file has
  changed.~~ Superseded by GUARD-8: automatic reloading no longer exists.
- ~~**GUARD-6** The approval UI flags writes to guarded files, and `hot_reload`
  calls that would load pending changes (UI-19).~~ Retired: no guarded-file
  list (DEPLOY-11).
- ~~**GUARD-7** Changes to non-guarded files are picked up by the dev server's
  automatic reloading without `hot_reload`.~~ Removed: every change now needs
  `hot_reload` (GUARD-8).
- ~~**GUARD-8** The endpoint's code reloader (and the LiveView live-reload
  notifier) never recompiles or loads code on a request. Only `hot_reload`
  loads code (HOT-5), whichever file changed.~~ Superseded by DEPLOY-8.
- ~~**GUARD-9** The code files are `lib/**`, `config/**`, `mix.exs` and
  `mix.lock`. At boot, the SHA-256 hashes of the code files are recorded as
  loaded.~~ Retired: pending tracking is gone (DEPLOY-11).
- ~~**GUARD-10** A code file is pending when it was added, removed or modified
  since it was last loaded (at boot or by a successful `hot_reload`).~~
  Retired: DEPLOY-11.
- ~~**GUARD-11** While any code file is pending, a request makes the code
  reloader log a warning naming those files. The warning is logged once for
  each distinct set of pending files.~~ Retired: DEPLOY-11.
- ~~**GUARD-12** A file stops being pending after a successful `hot_reload`, or
  when a rollback restores its loaded contents.~~ Retired: DEPLOY-11.
- ~~**GUARD-13** The dev server's browser live reload doesn't watch `lib/`
  files, since saving them doesn't change the running app (GUARD-8). Static
  asset changes still reload the page.~~ Retired: the running app's own tree is
  never edited (DEPLOY).

## Implementation

Removed: `Elia.Guarded`; the reloader plug in `lib/elia_web/endpoint.ex`
becomes an inert no-op (DEPLOY-8); the guarded-file banner in
`lib/elia_web/live/chat_live.ex` and the pending list in
`lib/elia_web/recovery.ex` are dropped.

## Tests

The retired guarded-file test file is removed, as are the guarded-file
assertions in `test/elia/self_modification_test.exs`.
