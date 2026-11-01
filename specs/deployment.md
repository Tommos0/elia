# Deployment

Status: Draft

Elia develops its own code in isolated git worktrees, one per chat, and the
running server only changes through a deliberate *deploy* step. The server runs
from a *live* tree; a chat in Elia's own project works in its own worktree, on
its own branch, forked from `live`. Deploying merges the chat's branch into
`live` and then loads it into the running app, either by hot reload (keeping
running state) or by restart (a clean process). Because the tree a chat edits
is never the tree that runs, an in-progress or broken edit cannot reach the
running app at all — the isolation is the filesystem, not a gate.

## Terms

- **live tree** — the tree the server runs from, where Elia's data lives
  (`:runtime_root`) and where the code reloader reloads; the target of a
  deploy.
- **chat worktree** — the isolated git worktree (branch `chat/<chat id>`) a
  chat in Elia's own project works in; its workspace root (PROJ-12).

## Requirements

### Worktrees

- **DEPLOY-1** A chat in Elia's own project works in its own git worktree, on
  branch `chat/<chat id>`, forked from `live` when the chat starts. That
  worktree is the chat's workspace root: the file and shell tools, checkpoints
  and end-of-turn verification operate there (PROJ-12).
- **DEPLOY-2** The live tree is where the server runs, where the code reloader
  reloads, and where Elia's data lives: `.elia` sits directly under it, so
  chats and checkpoints are the same across a chat's worktrees and across a
  deploy. It is `config :elia, :runtime_root` (default: the server's working
  directory).
- **DEPLOY-3** Elia's own project's folder is the live tree (PROJ-3), while
  each of its chats works in a worktree (DEPLOY-1). Chats in other projects are
  unchanged: the project's folder is the workspace and no worktree is created
  (PROJ-12).
- **DEPLOY-4** The file explorer shows the live tree for Elia's own project
  (PROJ-22).

### Deploy

- **DEPLOY-5** A deploy merges `chat/<chat id>` into `live`, fast-forward only
  (the chat rebases on `live` first), and then loads it into the running app.
  It runs the full test suite in the chat's worktree first; if it fails,
  nothing is merged or loaded and the running app is unaffected (HOT-4).
- **DEPLOY-6** Hot reload is the existing `hot_reload` tool: it runs the tests,
  merges (DEPLOY-5), then recompiles and loads `live` into the running app
  (HOT-3–HOT-6), keeping running state.
- **DEPLOY-7** Restart is a button in the chat UI: it merges (DEPLOY-5) and
  restarts the server, giving a clean process (RESTART-3, RESTART-11).
- **DEPLOY-8** The running app never recompiles or loads code on its own: a
  request does not reload code, and a merge into `live` stays inert until a
  deploy loads it (GUARD-8). Only a deploy loads code.

### Sub-tasks and lifecycle

- **DEPLOY-9** A sub-task shares its parent chat's worktree and branch
  (SUBTASK-23).
- **DEPLOY-10** A chat's worktree is created when the chat starts and removed
  when the chat is deleted; its `chat/<id>` branch is pruned. A branch is kept
  while its chat exists, since chats are resumable; there is no time-based
  pruning.

### Retired: guarded files

- **DEPLOY-11** There is no guarded-file list: `Elia.Guarded` and GUARD-1,
  GUARD-6 and GUARD-9–GUARD-13 are retired. "Never edit `harness.ex`,
  `checkpoint.ex` or `workspace.ex` to weaken them" stays as prose in
  `AGENTS.md` and the self-modification skill. The no-op request behaviour
  (GUARD-8) is kept by DEPLOY-8.

## Specs to amend

HOT (hot reload becomes a deploy mode), GUARD (retired; 8 kept as DEPLOY-8),
PROJ-3/PROJ-12/PROJ-13/PROJ-14 (per-chat worktrees for Elia's own project; the
live tree), RESTART (the restart button), SUBTASK (shared worktree).

## Implementation

(planned) `Elia.Workspace` (`:runtime_root`), `Elia.Projects`,
`Elia.Agent.Loop`, `Elia.Skills.Harness` (`hot_reload`), `EliaWeb.ChatLive`
(restart button), `EliaWeb.Endpoint` (inert request reloader), `bin/serve`.

## Tests

(planned) a new `test/elia/deployment_test.exs`; `test/elia/guarded_test.exs`
removed; `test/elia/serve_script_test.exs` amended.
