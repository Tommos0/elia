# Deployment

Status: Implemented

Elia develops its own code in isolated git worktrees, one per chat, and the
running server only changes through a deliberate *deploy*. Two branches of the
live tree's repository matter: the trunk `master`, which the chats fork from
and merge their work into, and `live`, the branch the server's tree is checked
out on. A chat in Elia's own project works in its own worktree, on its own
branch forked from the trunk, and merges that branch into the trunk itself when
its work is done (DEPLOY-13). Deploying is then the user's own step, on the
Settings page: Elia brings the trunk to `live` and loads the result into the
running app, by hot reload or by a restart (DEPLOY-5–DEPLOY-7). Because the
tree a chat edits is never the tree that runs, an in-progress or broken edit
cannot reach the running app at all — the isolation is the filesystem, not a
gate.

## Terms

- **live tree** — the tree the server runs from, where Elia's data lives
  (`:runtime_root`) and where the code reloader reloads; the target of a
  deploy. It is checked out on the branch `live`.
- **trunk** — the branch `master` of the live tree's repository: the chats'
  fork point, and the branch their agents merge into. A tree set up before this
  workflow has the same name for the tree's main line, which is why it is
  reused.
- **chat worktree** — the isolated git worktree (branch `chat/<chat id>`) a
  chat in Elia's own project works in; its workspace root (PROJ-12).
- **set up for deployment** — a live tree that is checked out on `live`, has a
  trunk, and has a trunk at or ahead of `live` (DEPLOY-14).

## Requirements

### Worktrees

- **DEPLOY-1** A chat in Elia's own project works in its own git worktree, on
  branch `chat/<chat id>`, forked from the trunk `master` when the chat starts.
  That worktree is the chat's workspace root: the file and shell tools,
  checkpoints and end-of-turn verification operate there (PROJ-12).
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

### The trunk and the deploy target

- **DEPLOY-14** A live tree is *set up for deployment* when it is checked out
  on the branch `live`, has a `master` branch, and `live` is an ancestor of
  `master` — the trunk is at or ahead of `live`, since a deploy only ever
  fast-forwards `live` onto the trunk (DEPLOY-5). `Elia.Deploy.deployable/1`
  returns `:ok` or an error naming what is missing and the one-time fix
  (`git checkout -b live`, `git branch master`, `git branch -f master live`).
  A chat in Elia's own project gets no worktree while its tree isn't set up for
  deployment: it works in the live tree itself, as before (DEPLOY-1).
- **DEPLOY-13** When a chat in Elia's own project has finished a change, the
  agent merges its own branch into the trunk itself: it commits its work,
  rebases on `master` when the trunk has moved, and fast-forwards `master` to
  its branch (`git push . HEAD:master`, which refuses anything else). The
  harness never merges a chat's branch for it: the merge is the agent's step,
  guided by the instruction in `AGENTS.md` and the `self-modification` skill,
  and a deploy (DEPLOY-5) is the separate step that brings the trunk to the
  running app.

### Deploy

- **DEPLOY-5** A deploy brings the trunk to `live` and loads it into the
  running app. It is refused, before anything runs, when the live tree isn't
  set up for deployment (DEPLOY-14) or has uncommitted changes. Otherwise it
  runs the full test suite in the live tree, then fast-forwards `live` to
  `master` when the tests pass; when they fail it rolls `live` back to where it
  was, so nothing is deployed and the running app is unaffected, and it returns
  the test output. When `live` is already at `master` there is nothing to
  deploy: no tests run and only the load (DEPLOY-6, DEPLOY-7) happens.
- **DEPLOY-6** Hot reload is the soft deploy mode (HOT-1–HOT-6): after
  DEPLOY-5 the live tree is recompiled and the changed modules are loaded into
  the running app, keeping running state. Its control is on the Settings page
  (CONF-19); it needs the dev server (HOT-2).
- **DEPLOY-7** Restart is the hard deploy mode: after DEPLOY-5 the server is
  restarted, so it comes up on the deployed code in a clean process
  (RESTART-3, RESTART-11). Its control is on the Settings page (CONF-19), and
  it only works when `bin/serve` (or another service manager) runs the server
  (RESTART-1, RESTART-2).
- **DEPLOY-8** The running app never recompiles or loads code on its own: a
  request does not reload code, and a merge into `live` stays inert until a
  deploy loads it (GUARD-8). Only a deploy loads code.
- **DEPLOY-12** In development the browser's live reload watches only the live
  tree's own static assets (`priv/static`), not the chats' worktrees. Creating
  a chat checks out a worktree with its own `priv/static` copies (DEPLOY-1);
  reloading on those would reload the browser in the middle of the navigation
  to the new chat and land it back on the old one.

### Sub-tasks and lifecycle

- **DEPLOY-9** A sub-task in Elia's own project works in its own worktree,
  branch `chat/<sub-task id>` forked from its parent's branch
  `chat/<parent id>` (SUBTASK-23). The harness leaves its work on that branch
  and lets the parent agent merge it itself (SUBTASK-25).
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

HOT (hot reload is a deploy mode, with no tool), CONF (the Settings page's
deployment section), RESTART (the restart control), PROJ (per-chat worktrees
for Elia's own project; the live tree), SKILL and APPR (the
`self-modification` skill's tools), CKPT (the `rollback` message), SUBTASK
(the sub-task's own worktree).

## Implementation

`Elia.Deploy` (worktrees, the trunk and `live`, the deploy, hot reload and
restart, `deployable/1`, `status/1`, the inert request reloader),
`Elia.Workspace` (`:runtime_root`, the data dir), `Elia.Projects` (`harness/0`
is the live tree, `harness_ctx?/1`), `Elia.Agent.Session` (the chat's
workspace), `Elia.Agent.Loop` (verification in that workspace),
`Elia.Checkpoint` and `Elia.Harness` (snapshots, tests and reloading per
workspace), `Elia.Skills.{Files,Shell,Folder,SelfModification}`,
`Elia.Tasks` (the sub-task's worktree, the repository it runs git in),
`Elia.Store.delete/1` (removes the worktree), `EliaWeb.SettingsLive` (the
deployment section), `EliaWeb.Endpoint` (inert request reloader), `bin/serve`.

## Tests

`test/elia/deployment_test.exs` (worktrees, the trunk, the deploy, hot reload,
restart, DEPLOY-1 to DEPLOY-14), `test/elia_web/live/settings_live_test.exs`
(the deployment section), `test/support/live_tree.ex` (a throwaway live tree).
