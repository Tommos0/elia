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

A deploy is not a black box and not a one-way door: it reports the steps it
takes while it takes them and what it did when it is over (DEPLOY-21–DEPLOY-23,
CONF-21, CONF-22), it refuses to load a tree whose front end it could not make
current (DEPLOY-24), and the app can be sent back to a revision it has run
before (DEPLOY-25, DEPLOY-26) — from the Settings page or, when a deploy has
left that page's own UI unusable, from a plain HTML page that needs none of the
tree's front end (`/recover`, RECOVER-10).

## Requirements

### Worktrees

- **DEPLOY-1** A chat in Elia's own project works in its own git worktree, on
  branch `chat/<chat id>`, forked from the trunk `master` when the chat starts.
  That worktree is the chat's workspace root: the file and shell tools operate
  there (PROJ-12), and it holds no dependency tree of its own — it shares the
  live tree's `deps` (ISOL-7). Creating it also seeds it with a private copy of
  the live tree's build output, so its first compile reuses the dependencies'
  artifacts (BUILD-1).
- **DEPLOY-2** The live tree is where the server runs, where the code reloader
  reloads, and where Elia's data lives: `.elia` sits directly under it, so
  chats are the same across a chat's worktrees and across a deploy. It is `config :elia, :runtime_root` (default: the server's working
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
  runs the full test suite in the live tree — after fetching the trunk's
  dependencies there (DEPLOY-18) — then fast-forwards `live` to
  `master` when the tests pass; when they fail it rolls `live` back to where it
  was, so nothing is deployed and the running app is unaffected, and it returns
  the test output. When `live` is already at `master` there is nothing to
  *merge*: no tests run, the live tree's front end is still made current before
  the load (DEPLOY-19), and then the load (DEPLOY-6, DEPLOY-7) happens.
- **DEPLOY-18** A deploy fetches the dependencies of the trunk it is about to
  test in the live tree itself — `mix deps.get`, jailed with `:live_tree`
  (ISOL-14) — before the suite runs. A dependency a chat added lives in that
  chat's own dependency layer (ISOL-7) and the live tree has never seen it, so
  without this the merged trunk fails to build for a reason the deploy invented.
  A lock that already matches fetches nothing, and a fetch that fails is a
  deploy failure like a failing suite: `live` is rolled back to where it was and
  nothing is deployed (DEPLOY-5).
- **DEPLOY-19** A deploy makes the live tree's front end current before it loads
  it: after the suite passes and `live` is fast-forwarded onto the trunk it
  installs the trunk's Node packages in the live tree's `assets/` (`npm
  install`) and builds its assets (`mix assets.build`), in the live tree and
  jailed the way DEPLOY-18's fetch is (ISOL-14), and says in its message when it
  rebuilt them. What the browser loads is therefore what the tree it just
  deployed says — the hook a new page's markup asks for, the class its markup
  uses — rather than a bundle from before the change, or a tree that cannot
  build one at all: a Node package a chat added is in that chat's own dependency
  layer (ISOL-7) and the live tree has never installed it, so its asset build
  fails and no bundle is written. A tree with no `assets/` directory has no
  front end and is left alone. A failure is a deploy failure like a failing
  suite: `live` is rolled back to where it was, nothing is loaded, and the error
  carries the command's output. Building writes under `priv/static`, so the
  browser's live reload fires (DEPLOY-12) and a page that is already open comes
  back on the new bundle instead of keeping the one it loaded (HOT-8).
- **DEPLOY-20** The front-end step of a deploy (DEPLOY-19) runs on every deploy,
  including one whose `live` is already at the trunk and so has nothing to merge
  (DEPLOY-5): what a deploy loads is then always what the tree it loads builds.
  A bundle that is missing or stale for any other reason — an earlier build of a
  different tree, a Node package the live tree never installed — is therefore
  repaired by deploying, rather than only by a deploy that happens to have
  something to merge. A front end that can't be built fails the deploy the way
  it does after a merge: nothing is loaded, and the error carries the command's
  output.
- **DEPLOY-6** Hot reload is the soft deploy mode (HOT-1–HOT-6): after
  DEPLOY-5 the live tree is recompiled and the changed modules are loaded into
  the running app, keeping running state. Its control is on the Settings page
  (CONF-19); it needs the code reloader on (HOT-2, HOT-7).
- **DEPLOY-7** Restart is the hard deploy mode: after DEPLOY-5 the server is
  restarted, so it comes up on the deployed code in a clean process
  (RESTART-3, RESTART-11). Its control is on the Settings page (CONF-19), and
  it only works when `bin/serve` (or another service manager) runs the server
  (RESTART-1, RESTART-2).
- **DEPLOY-8** The running app never recompiles or loads code on its own: a
  request does not reload code, and a merge into `live` stays inert until a
  deploy loads it (GUARD-8). Only a deploy loads code.
- **DEPLOY-12** The browser's live reload watches only the live tree's own
  static assets (`priv/static`), not the chats' worktrees. Creating a chat
  checks out a worktree with its own `priv/static` copies (DEPLOY-1);
  reloading on those would reload the browser in the middle of the navigation
  to the new chat and land it back on the old one.

- **DEPLOY-15** A deploy runs in a process Elia's application owns, not in the
  Settings LiveView: the page that started it may navigate away, be closed or
  reload itself (DEPLOY-12) without aborting it, and it runs to the end — the
  tests, the merge, and then the load (DEPLOY-6) or the restart (DEPLOY-7). A
  deploy that the runtime system dies under (RESTART-1) loses whatever it had
  not done yet; DEPLOY-17 makes that visible rather than silent.
- **DEPLOY-16** One deploy runs at a time, and its state belongs to the runner
  rather than to a page: `Elia.Deploy.Runner` holds the deploy in flight — its
  mode and when it started — and the result of the last one, refuses to start
  a second while one is running, and hands both to a Settings page that mounts
  while a deploy runs or after one finished (CONF-20).
- **DEPLOY-17** What the running app has actually loaded is recorded: when a
  hot reload (DEPLOY-6) has loaded the live tree, or a restart (DEPLOY-7) has
  brought the server up on it, the `live` revision that was loaded is written
  to the live tree's data dir (`.elia`, DEPLOY-2) — in the restart case before
  the server stops. `Elia.Deploy.status/1` compares `live` with it, so the
  state a deploy leaves when it merges (DEPLOY-5) and never reaches the load is
  reported rather than looking up to date (CONF-19).

### What a deploy is doing

- **DEPLOY-21** A deploy takes a known sequence of steps and reports each one
  as it takes it, in the order it takes them: merging the trunk into `live`
  (DEPLOY-5) and fetching its dependencies there (DEPLOY-18), running the suite
  in the live tree, installing the trunk's Node packages and building the front
  end (DEPLOY-19), and the load (DEPLOY-6) or the restart (DEPLOY-7). Each step
  reports when it starts and
  when it ends, how long it took and whether it succeeded; a step that is never
  reached is never reported, so where a deploy stopped is what its report
  shows. A deploy that dies, or that merges and never reaches the load
  (DEPLOY-15), therefore leaves a record that says so rather than one that
  looks finished. A rollback (DEPLOY-26) reports its steps the same way.
- **DEPLOY-22** A deploy's steps belong to the runner (DEPLOY-16), not to the
  page that asked for it: `Elia.Deploy.Runner` holds the step in flight and the
  steps that have finished, so a page that mounts while a deploy runs — or is
  reloaded by the deploy's own asset change (DEPLOY-12, HOT-9) — shows where
  the deploy is rather than only that something runs.
- **DEPLOY-23** What a deploy is doing is written down as it goes: the runner
  records the operation in flight — its mode, when it started and the step it
  has reached — and the last one's steps and outcome in the live tree's data
  dir (DEPLOY-2), so the record outlives the process that made it. A deploy
  that restarts the server (DEPLOY-7) therefore still reports what it did to
  the page that comes up afterwards: the record is written before the server
  stops, the way the loaded revision is (DEPLOY-17). `Elia.Deploy.last_deploy/1`
  reads it back, and it is what the Settings section (CONF-22) and the recovery
  page (RECOVER-11) show; `Elia.Deploy.status/1` goes on answering from git and
  the loaded revision as before (CONF-19).

### Losing nothing to a bad deploy

- **DEPLOY-24** A deploy never loads a tree whose front end it could not make
  current: after the build (DEPLOY-19) it checks that the bundle the browser
  loads is there — `priv/static/assets/js/app.js` and
  `priv/static/assets/css/app.css`, the two entry points the endpoint serves —
  and a bundle that is missing or empty fails the deploy the way a failing
  suite does (DEPLOY-5): `live` is rolled back to where it was, nothing is
  loaded, and the error names the file. A build that exits 0 having written
  nothing — a wiped `priv/static`, a misconfigured `esbuild` or `tailwind` — is
  therefore a failed deploy rather than a running app with no stylesheet or no
  hook. A tree with no front end (DEPLOY-19) has nothing to check.
- **DEPLOY-25** The revisions the running app has loaded are kept, not only the
  newest (DEPLOY-17): the record (DEPLOY-23) keeps the last few revisions the
  app has run, newest first, each with when it was loaded and by what — a
  deploy, a rollback or a restart. `Elia.Deploy.loaded_revisions/1` reads them
  back and `Elia.Deploy.status/1` goes on naming the newest as the revision the
  app is running. Keeping a few rather than one means a revision the app has
  run and no longer is can still be named and gone back to.
- **DEPLOY-26** Going back is a load, not a merge:
  `Elia.Deploy.rollback(sha, mode, root)` moves `live` to a kept revision — a
  `git reset --hard`, since a deploy only ever fast-forwards forward
  (DEPLOY-5) — makes that revision's front end current (DEPLOY-19, checked as
  DEPLOY-24 checks it) and loads it the way a deploy does (hot reload, DEPLOY-6,
  or restart, DEPLOY-7), recording it as loaded (DEPLOY-17, DEPLOY-25). It runs
  in the runner, one operation at a time (DEPLOY-15, DEPLOY-16), reports its
  steps (DEPLOY-21) and records what it did (DEPLOY-23). It is refused, changing
  nothing, for a revision that is not one the app has run (DEPLOY-25), for the
  revision the app is running now — there is nothing to go back to — or for a
  live tree with uncommitted changes (DEPLOY-5); a rollback that fails after it
  has moved `live` (a front end it cannot build, DEPLOY-24) puts `live` back
  where it was and loads nothing, so the tree it leaves is the one the app is
  running. Afterwards `live` is behind the
  trunk, so the section offers a deploy again (CONF-19), and what the app runs
  is what the rollback loaded (DEPLOY-17). A hot reload back to an older
  revision loads the modules that revision has and cannot unload one it does not
  (HOT-10): the message says so, and a restart is the clean way back.

### Sub-tasks and lifecycle

- **DEPLOY-9** A sub-task in Elia's own project works in its own worktree,
  branch `chat/<sub-task id>` forked from its parent's branch
  `chat/<parent id>` (SUBTASK-23). The harness leaves its work on that branch
  and lets the parent agent merge it itself (SUBTASK-25).
- **DEPLOY-10** A chat's worktree is created when the chat starts and removed
  when the chat is deleted; its `chat/<id>` branch is pruned, and its dependency
  layer goes with it (ISOL-7). A branch is kept while its chat exists, since
  chats are resumable; there is no time-based pruning.

### Retired: guarded files

- **DEPLOY-11** There is no guarded-file list: `Elia.Guarded` and GUARD-1,
  GUARD-6 and GUARD-9–GUARD-13 are retired. "Never edit `harness.ex`,
  `workspace.ex` to weaken them" stays as prose in
  `AGENTS.md` and the self-modification skill. The no-op request behaviour
  (GUARD-8) is kept by DEPLOY-8.

## Implementation

The specs this one amends: HOT (hot reload is a deploy mode, with no tool),
CONF (the Settings page's deployment section: the steps a deploy reports, the
deploy that outlives its result, and going back to a revision the app has run,
CONF-21–CONF-23), RESTART (the restart control), PROJ (per-chat worktrees for
Elia's own project; the live tree), SKILL and APPR (the `self-modification`
skill's tools), CKPT and RECOVER (both retired — RECOVER is revived for a
different job, the page that reaches the app when a deploy has broken its UI:
RECOVER-10), SUBTASK (the sub-task's own worktree), ISOL (the deploy's own
fetch and suite run, DEPLOY-18, ISOL-14).

`Elia.Deploy` (worktrees, the trunk and `live`, the deploy, hot reload and
restart, `deployable/1`, `status/1`, the inert request reloader, the steps a
deploy reports (DEPLOY-21), the record it writes (DEPLOY-23) with
`last_deploy/1` and `loaded_revisions/1` on it (DEPLOY-25), the front-end step
a deploy runs before it loads — `npm install` in the live tree's `assets/` and
`mix assets.build`, DEPLOY-19 — with the check that the bundle is there
(DEPLOY-24) and the seam its tests replace the way `load:` and `stop:` are, and
`rollback/3`, DEPLOY-26),
`Elia.Deploy.Runner` (the deploy's own process, its step and its result,
DEPLOY-15 to DEPLOY-17, DEPLOY-22, DEPLOY-23),
`Elia.Application` (starts it),
`Elia.Workspace` (`:runtime_root`, the data dir), `Elia.Projects` (`harness/0`
is the live tree, `harness_ctx?/1`), `Elia.Agent.Session` (the chat's
workspace), `Elia.Agent.Loop`, `Elia.Harness` (running the tests in that
workspace), `Elia.Skills.{Files,Shell,Folder,SelfModification}`,
`Elia.Tasks` (the sub-task's worktree, the repository it runs git in),
`Elia.Store.delete/1` (removes the worktree), `EliaWeb.SettingsLive` (the
deployment section: the steps, the record, going back), `EliaWeb.Endpoint`
(inert request reloader, the recovery plug, RECOVER-10), `bin/serve`.

## Tests

`test/elia/deployment_test.exs` (worktrees, the trunk, the deploy, the front
end it builds before it loads and the bundle it checks for, the steps it
reports and the record it writes, going back to a kept revision, hot reload,
restart, the runner and the loaded revision, DEPLOY-1 to DEPLOY-26),
`test/elia_web/live/settings_live_test.exs` (the deployment section, including
a page that mounts mid-deploy, a page that comes back after a restart and after
one), `test/elia_web/recovery_test.exs` (the recovery page, RECOVER-10 to
RECOVER-15), `test/support/live_tree.ex` (a throwaway live tree).
