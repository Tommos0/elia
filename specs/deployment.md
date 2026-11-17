# Deployment

Status: Implemented

Elia develops its own code in the tree it runs from, and the running server only
changes through a deliberate *deploy*. Two branches of the live tree's repository
matter: the trunk `master`, which a chat's work is merged into, and `live`, the
branch the server's tree is checked out on. A chat in Elia's own project works in
the project's folder — the live tree itself, which is also the tree its commands
are jailed to (ISOL-13) — and, when it is about to change code, makes itself a
git worktree inside that folder and does the work on its own branch there,
merging that branch into the trunk itself when the work is done (DEPLOY-28,
DEPLOY-13). Deploying is then the user's own step, on the Settings page: Elia
brings the trunk to `live` and loads the result into the running app, by hot
reload or by a restart (DEPLOY-5–DEPLOY-7). A chat's worktree keeps an
in-progress or broken edit out of the tree that runs — the isolation is one the
chat arranges for itself (DEPLOY-28), not a gate — and a deploy refuses to load
a tree whose suite or compile fails (DEPLOY-5, HOT-4).

A deploy is not a black box and not a one-way door: it reports the steps it
takes while it takes them and what it did when it is over (DEPLOY-21–DEPLOY-23,
CONF-21, CONF-22), it refuses to load a tree whose front end it could not make
current (DEPLOY-24), and the app can be sent back to a revision it has run
before (DEPLOY-25, DEPLOY-26) — from the Settings page or, when a deploy has
left that page's own UI unusable, from a plain HTML page that needs none of the
tree's front end (`/recover`, RECOVER-10).

## Terms

- **live tree** — the tree the server runs from, where Elia's data lives
  (`:runtime_root`) and where the code reloader reloads; the target of a
  deploy. It is checked out on the branch `live`.
- **trunk** — the branch `master` of the live tree's repository: the branch a
  chat's work is forked from and merged into (DEPLOY-13). A tree set up before
  this workflow has the same name for the tree's main line, which is why it is
  reused.
- **chat worktree** — the git worktree (branch `chat/<chat id>`) a chat in
  Elia's own project makes for itself, inside the project's folder, when it is
  about to change code (DEPLOY-28). It is not the chat's workspace root and no
  longer the harness's: the chat's workspace is its project's folder (PROJ-12,
  ISOL-13).
- **set up for deployment** — a live tree that is checked out on `live`, has a
  trunk, and has a trunk at or ahead of `live` (DEPLOY-14).

## Requirements

### Where a chat works

- **DEPLOY-1** A chat in Elia's own project works in the folder of its project,
  which is the live tree (DEPLOY-2, DEPLOY-3). That folder is the workspace root
  its file and shell tools resolve against (PROJ-12), the directory a command
  runs in until the chat `cd`s elsewhere (SHELL-2, WD-1) and the tree a command
  is jailed to when the jail is on (ISOL-13, ISOL-16). The harness creates no
  worktree and no branch for a chat: the tree a chat's own work goes in is one
  the chat makes for itself, and the branch it lands on is its own (DEPLOY-28).
- **DEPLOY-2** The live tree is where the server runs, where the code reloader
  reloads, and where Elia's data lives: `.elia` sits directly under it, so a
  chat is the same chat whatever worktree its work is in and across a deploy. It is `config :elia, :runtime_root` (default: the server's working
  directory).
- **DEPLOY-3** Elia's own project's folder is the live tree (PROJ-3), and it is
  the workspace of each of its chats the way any project's folder is (DEPLOY-1,
  PROJ-12). Chats in other projects are unchanged: the project's folder is the
  workspace and nothing is created there.
- **DEPLOY-4** The file explorer shows the live tree for Elia's own project
  (PROJ-22).

### The worktree a chat makes itself

- **DEPLOY-28** A chat in Elia's own project is told — in `AGENTS.md` and the
  `self-modification` skill — that its workspace is its project's folder, that
  the harness makes no worktree for it, and that before it changes code it makes
  one for itself: forked from the trunk `master` — or, for a sub-task, from the
  branch its brief names, its parent's, so it sees what its parent has committed
  (SUBTASK-23) — on branch `chat/<its chat id>` — the id it has in
  `$ELIA_CHAT_ID` (SHELL-14) — at a path inside
  the project's folder that its `.gitignore` covers (`tmp/worktrees/<chat id>`),
  with the copies DEPLOY-29 lists. It edits, compiles, previews and commits
  there, so the tree it was given stays as it was and nothing half-done is in
  the tree that runs. When the work is done it merges its own branch into the
  trunk (DEPLOY-13) and then removes the worktree and its branch (`git worktree
  remove`, `git branch -d` once it is merged), so a finished chat leaves neither
  a tree nor a branch behind.
- **DEPLOY-29** The same instruction says how to give that worktree what its
  first command needs: a fresh worktree of this repository has neither `deps`
  nor `_build` nor `assets/node_modules` — all three are gitignored — so each is
  copied into it from the live tree, in a loop over the two directories and only
  when the live tree has them:

  ```sh
  for d in deps _build; do [ -d "$d" ] && cp -a "$d" "tmp/worktrees/$ELIA_CHAT_ID/"; done
  [ -d assets/node_modules ] && cp -a assets/node_modules "tmp/worktrees/$ELIA_CHAT_ID/assets/"
  ```

  A copy the live tree doesn't have is skipped — a tree that has never compiled
  has no `_build` — and a missing copy only means a colder first compile, never
  a broken worktree. Without them every dependency is fetched and compiled from
  source, the browser's bundle is built again and a preview installs its Node
  packages first, which is the wait this instruction exists to prevent (BUILD,
  retired). The copies are the worktree's own, so nothing a chat compiles or
  builds reaches the live tree's. The same instruction serves a sub-task, whose
  workspace is its parent's (SUBTASK-23), and it is the same whether the jail is
  on or off.
- **DEPLOY-30** The instruction says too what to do when there is no worktree to
  have: it fails to be made — `git worktree add` refuses, the folder is not a
  git repository, a copy fails for want of space or permission — the chat says
  so and asks the user, and does not fall back to editing the tree that runs
  (DEPLOY-5, SHELL-7).

### The trunk and the deploy target

- **DEPLOY-14** A live tree is *set up for deployment* when it is checked out
  on the branch `live`, has a `master` branch, and `live` is an ancestor of
  `master` — the trunk is at or ahead of `live`, since a deploy only ever
  fast-forwards `live` onto the trunk (DEPLOY-5). `Elia.Deploy.deployable/1`
  returns `:ok` or an error naming what is missing and the one-time fix
  (`git checkout -b live`, `git branch master`, `git branch -f master live`).
  A tree that isn't set up for deployment is still the workspace of a chat in
  it (DEPLOY-1), but the worktree route can't finish there: `master` is checked
  out in the live tree, so git refuses to push to it (DEPLOY-30). A deploy is
  refused too, and the Settings page says what is missing.
- **DEPLOY-13** When a chat in Elia's own project has finished a change — made
  in the worktree it made itself, on its own branch (DEPLOY-28) — the agent
  merges that branch into the trunk itself: it commits its work,
  rebases on `master` when the trunk has moved, and fast-forwards `master` to
  its branch (`git push . HEAD:master`, which refuses anything else). The
  harness never merges a chat's branch for it: the merge is the agent's step,
  guided by the instruction in `AGENTS.md` and the `self-modification` skill,
  and a deploy (DEPLOY-5) is the separate step that brings the trunk to the
  running app. A sub-task is the exception: it commits on its branch and stops
  there, and its parent merges that branch (SUBTASK-23).

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
  test in the live tree itself — `mix deps.get`, jailed in the live tree
  (ISOL-13, ISOL-14) — before the suite runs. A dependency a chat added lives in the
  `deps` of the worktree it made itself (DEPLOY-29) and the live tree has never
  seen it, so without this the merged trunk fails to build for a reason the
  deploy invented.
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
  build one at all: a Node package a chat added is in the worktree it made
  itself (DEPLOY-29, PREVIEW-14) and the live tree has never installed it, so its
  asset build fails and no bundle is written. A tree with no `assets/` directory has no
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
  static assets (`priv/static`): the patterns are anchored at the live tree, so
  the copies of those assets a chat's own worktree holds (DEPLOY-28) never match
  them. Reloading on those would reload the browser in the middle of a
  navigation — to a new chat, or to a page the agent's own worktree just built
  — and land it back where it was.

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
  app has run, newest first, each with when it was first loaded and by what — a
  deploy, a rollback or a restart. A revision the app loads again goes on being
  the newest, since it is what the app runs, and keeps the time it was first
  loaded, so a load that brought no new revision (DEPLOY-20) does not make the
  changes already recorded look new. `Elia.Deploy.loaded_revisions/1` reads them
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
- **DEPLOY-27** `Elia.Deploy.changes/1` reports what the revision the app runs
  has that the one it ran before it does not:
  `{:ok, %{commits: commits, at: at, before: before}}`, where `commits` is
  newest first, each `%{sha: full, short: abbreviated, subject: its first line}`,
  with merge commits left out — a merge is not a change of its own — and `at` is
  when the running revision was loaded, `before` the abbreviated sha of the
  revision before it. `commits` is empty and `before` is `nil` when the record
  holds no earlier revision, `at` is `nil` when it holds none at all, and a
  `git log <before>..<now>` in the live tree that fails is `{:error, reason}`.
  It answers from the record (DEPLOY-23, DEPLOY-25) and git the way `status/1`
  does (DEPLOY-17).

### Sub-tasks and lifecycle

- ~~**DEPLOY-9** A sub-task in Elia's own project works in its own worktree,
  branch `chat/<sub-task id>` forked from its parent's branch
  `chat/<parent id>` (SUBTASK-23). The harness leaves its work on that branch
  and lets the parent agent merge it itself (SUBTASK-25).~~ Retired: the harness
  creates no worktree, for a child either (DEPLOY-1). A child is a chat like any
  other in Elia's own project: it works in its parent's workspace and makes its
  own worktree for the work, on branch `chat/<its own id>` (DEPLOY-28,
  SUBTASK-23), which is what its parent merges.
- ~~**DEPLOY-10** A chat's worktree is created when the chat starts and removed
  when the chat is deleted; its `chat/<id>` branch is pruned, and its dependency
  layer goes with it (ISOL-7). A branch is kept while its chat exists, since
  chats are resumable; there is no time-based pruning.~~ Retired: the harness
  creates no worktree to remove, and deleting a chat deletes the chat and
  nothing else. The worktree a chat made itself is one it removes once its work
  is merged (DEPLOY-28); a chat deleted before that leaves a tree and a branch
  under the gitignored `tmp/worktrees/`, which the user clears with ordinary git
  if they want it cleared. A branch is still kept while it exists — chats are
  resumable — and nothing prunes by time.

### Retired: guarded files

- **DEPLOY-11** There is no guarded-file list: `Elia.Guarded` and GUARD-1,
  GUARD-6 and GUARD-9–GUARD-13 are retired. "Never edit `harness.ex`,
  `workspace.ex` to weaken them" stays as prose in
  `AGENTS.md` and the self-modification skill. The no-op request behaviour
  (GUARD-8) is kept by DEPLOY-8.

## Stored data

Backward compatible, and no migration: a saved chat is read as it was, and
nothing is rewritten.

- A chat's saved working directory (`cwd`, STORE-46) may name a directory inside
  a worktree the harness used to make, under the live tree's data dir. That path
  is still inside the chat's workspace, which is now the live tree itself
  (DEPLOY-1), so such a chat resumes there; once that directory is gone it reads
  as the chat's project folder, which is what a saved directory that is no
  longer there already does (WD-2, WD-7).
- The worktrees the harness made are left where they are: nothing removes them,
  so they and their `chat/<id>` branches stay until the user clears them with
  ordinary git (`git worktree prune`, `git worktree remove`, `git branch -d`).
  Nothing else reads them (DEPLOY-10).
- Nothing else outlives the process here: the saved sessions and the settings
  database gain and lose no key.

## Implementation

The specs this one amends: HOT (hot reload is a deploy mode, with no tool),
CONF (the Settings page's deployment section: the steps a deploy reports, the
deploy that outlives its result, and going back to a revision the app has run,
CONF-21–CONF-23), RESTART (the restart control), PROJ (a chat's workspace is its
project's folder, Elia's own project included; the live tree), SKILL and APPR
(the `self-modification` skill's tools and the instruction it carries,
DEPLOY-28 to DEPLOY-30), CKPT, GUARD and BUILD (retired), RECOVER (revived for a
different job, the page that reaches the app when a deploy has broken its UI:
RECOVER-10), SUBTASK (the workspace a child gets, SUBTASK-23), ISOL (the deploy's
own fetch and suite run, DEPLOY-18, ISOL-14; the profile a chat's commands run
under now that it works in the live tree, ISOL-13, and the worktree plumbing that
goes with the harness's own: ISOL-7, ISOL-22, ISOL-27, ISOL-28), SHELL
(`$ELIA_CHAT_ID`, SHELL-14).

`Elia.Deploy` (the trunk and `live`, the deploy, hot reload and restart,
`deployable/1`, `status/1`, the inert request reloader, the steps a
deploy reports (DEPLOY-21), the record it writes (DEPLOY-23) with
`last_deploy/1` and `loaded_revisions/1` on it (DEPLOY-25), the front-end step
a deploy runs before it loads — `npm install` in the live tree's `assets/` and
`mix assets.build`, DEPLOY-19 — with the check that the bundle is there
(DEPLOY-24) and the seam its tests replace the way `load:` and `stop:` are, and
`rollback/3`, DEPLOY-26, and `changes/1`, DEPLOY-27),
`Elia.Deploy.Runner` (the deploy's own process, its step and its result,
DEPLOY-15 to DEPLOY-17, DEPLOY-22, DEPLOY-23),
`Elia.Application` (starts it),
`Elia.Workspace` (`:runtime_root`, the data dir), `Elia.Projects` (`harness/0`
is the live tree, `harness_ctx?/1`), `Elia.Agent.Session` (the chat's
workspace), `Elia.Agent.Loop`, `Elia.Harness` (running the tests in that
workspace), `Elia.Skills.{Files,Shell,Folder,SelfModification}` (the
`ELIA_CHAT_ID` a command gets, SHELL-14, and the instruction a chat carries,
DEPLOY-28 to DEPLOY-30),
`EliaWeb.SettingsLive` (the
deployment section: the steps, the record, going back, and what a tree that
isn't set up for deployment is missing), `EliaWeb.Endpoint`
(inert request reloader, the recovery plug, RECOVER-10), `bin/serve`.

Removed with the harness's own worktree: `Elia.Deploy`'s worktree creation,
removal and child-worktree functions (`workspace/2`, `existing_workspace/2`,
`ensure_worktree/1`, `add_worktree/4`, `link_deps/2`, `ensure_child_worktree/3`,
`remove_worktree/1`, `worktree_path/2`, `worktree_chat/2`, the branch plumbing
and the seeding of `deps` and `_build`), `Elia.Store.delete/1`'s worktree
removal, `Elia.Deps`, `Elia.Shell`'s per-worktree mount lock and its `:worktree`
and `:deps_sync` profiles (ISOL-13), and `Elia.Preview.path/3`'s lookup under a
chat's worktree — a preview is written in the workspace it was taken in and
served from there (PREVIEW-2, PREVIEW-4).

## Tests

`test/elia/deployment_test.exs` (a chat's workspace is its project's folder and
nothing is created for it, the trunk, the deploy, the front
end it builds before it loads and the bundle it checks for, the steps it
reports and the record it writes, going back to a kept revision, hot reload,
restart, the runner, the loaded revision and what a deploy brought, DEPLOY-1 to
DEPLOY-27),
`test/elia/self_modification_test.exs` (the instruction a chat in Elia's own
project carries — its workspace is the project's folder, the worktree it makes
itself, the copies it needs and what it does when making it fails — DEPLOY-28 to
DEPLOY-30),
`test/elia_web/live/settings_live_test.exs` (the deployment section, including
a page that mounts mid-deploy, a page that comes back after a restart and after
one), `test/elia_web/recovery_test.exs` (the recovery page, RECOVER-10 to
RECOVER-15), `test/support/live_tree.ex` (a throwaway live tree).
