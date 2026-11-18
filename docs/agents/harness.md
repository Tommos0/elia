# Harness and guardrails

Read this before editing `lib/`, `config/`, `test/`, `mix.exs` or `skills/`.

Specs: `specs/deployment.md`, `specs/hot-reload.md`, `specs/verification.md`, `specs/workspace-policy.md`, `specs/folder-skills.md`.

## What needs approval

- `skills/**` changes apply without asking, but a folder skill's tools always ask the user before running.
- Elixir changes (`lib/`, `config/`, `test/`) need the user's approval.

## The live tree and a chat's own worktree

- The live tree (`Elia.Workspace.runtime_root/0`, `config :elia, :runtime_root`, default: where the server was started) is where the server runs, where the code reloader reloads and where Elia's data (`.elia`) lives (DEPLOY-2). It is also the workspace of every chat in Elia's own project: the file and shell tools resolve against it and `ctx[:workspace]` is it (DEPLOY-1, PROJ-12), and a jailed command is confined to it (ISOL-13).
- A chat in Elia's own project makes **its own** worktree before it changes code (DEPLOY-28): `<live tree>/tmp/worktrees/<chat id>` — gitignored — on branch `chat/<chat id>` forked from the trunk `master`, with `deps`, `_build` and `assets/node_modules` copied into it (DEPLOY-29). Nothing creates it for the chat: the harness makes no worktree and no branch (DEPLOY-1), `Elia.Deploy` no longer has a `workspace/2` for a chat, and a chat's workspace is the live tree whether the tree is set up for deployment or not, so a change made outside a worktree would land in the tree that runs. `spawn_task` returns as soon as the child has started and the parent goes on working; several children run at once (SUBTASK-2, SUBTASK-27, SUBTASK-33), and since they all work in the live tree they must keep their work in their own worktrees and branches — the `chat/<sub-task id>` branch is what a parent merges (SUBTASK-23).
- A sub-task forks the branch its brief names (its parent's, `chat/<parent id>`), so it sees what its parent has committed; its work stops at its own branch, for the parent agent to merge itself (SUBTASK-23, SUBTASK-25).
- The instruction a chat carries is in `AGENTS.md`'s worktree bullet (DEPLOY-28 to DEPLOY-30); the `self-modification` skill that carried a second copy of it is retired (SKILL-9, PROJ-17). A tree whose trunk `master` is checked out can't be pushed to (`git push . HEAD:master` is refused for a checked-out branch), so the worktree route can't finish there and the chat says so and asks the user rather than editing the live tree (DEPLOY-30). A deploy needs the tree set up for deployment (checked out on `live`, `master` at or ahead of it, DEPLOY-14, `Elia.Deploy.deployable/1`), which is what makes the worktree route work. Set it up once with `git checkout -b live` and `git branch master`; a tree whose trunk is behind `live` needs `git branch -f master live` once. Removing the finished chat's branch afterwards takes `git branch -D`, not `-d`: the live tree's HEAD is `live`, not `master`, so `-d` refuses with "not fully merged" even after `git push . HEAD:master` has landed the work. Check the work is in the trunk first (`git merge-base --is-ancestor "chat/$ELIA_CHAT_ID" master`), then `-D`.
- **Never** edit `lib/elia/harness.ex` or `lib/elia/workspace.ex` to weaken the guardrails.

## Tests

- A turn is not verified: nothing runs `mix test` for you at the end of a turn, and nothing is rolled back. Run the tests — `mix test`, or plain `mix precommit` (a command never inherits the server's `MIX_ENV`, ISOL-24) — before finishing a change; a deploy runs the full suite in the live tree again (DEPLOY-5). A change you judge safe without a run — a docs, spec or comment edit — may skip it, with a line in your last message saying why the skip was safe (`AGENTS.md`).

## Recovery

- There is no checkpoint to roll back to (`specs/checkpoints.md`, retired): a chat's work is on its own branch, and a deploy refuses to load a tree whose suite or compile fails (DEPLOY-5, HOT-4). `/recover` is back for the failure that gate does not catch — a deploy that passes its suite and still leaves the UI unusable: plain HTML, no bundle and no JavaScript, putting the app back on a revision it has already run (RECOVER-10..RECOVER-15, DEPLOY-25, DEPLOY-26, `specs/recovery.md`).

## Deploying

- A deploy is the only thing that loads code into the running app (DEPLOY-8): a request recompiles and loads nothing, so edits stay invisible to the running app until a deploy. Browser live reload doesn't watch `lib/` either. Reload the page after a deploy to see UI changes.
- **Merging your work into the trunk is your step; deploying is the user's.** When a change is done: commit it, rebase on `master` if the trunk has moved, then `git push . HEAD:master` — fast-forward only, so the trunk must be an ancestor (DEPLOY-13). `AGENTS.md` says it, and there is no skill that says it a second time (SKILL-9, PROJ-17). The harness never merges your branch.
- The user then deploys from the Settings page (`Elia.Deploy.deploy/1`, DEPLOY-5..DEPLOY-7): Elia runs the full test suite in the live tree, fast-forwards `live` to `master` (rolling it back if the tests fail, HOT-4) and loads the result — by "Hot reload", which recompiles and loads the live tree keeping running state (DEPLOY-6), or by "Restart", which stops the runtime system with a non-zero status so `bin/serve` starts it again on the deployed code in a clean process (DEPLOY-7, RESTART-1).
- Make all the edits for a change first, run the tests, then commit and merge — a multi-file edit is on the chat's branch, so the running app can't be broken halfway. Don't expect the change to be live until the user has deployed it.
- Not needed for `skills/**` (use `reload_skills`) or for tests and docs.
- A UI change — a template, `assets/css/`, a hook — can be seen *before* it is deployed: `bin/preview` in the chat's workspace screenshots its own code in a real headless browser, in the test env, and prints a Markdown image link per page (PREVIEW, `specs/ui-preview.md`). Nothing is deployed, no API key is involved and no live data is read; the pictures land in the gitignored `tmp/preview/`, and the running app serves a chat's own ones at `/preview/<chat id>/<file>` (PREVIEW-7). Paste the links into a reply to show the user. Preview in dark mode at a mobile width by default: `ELIA_PREVIEW_THEME=dark ELIA_PREVIEW_WIDTH=390 bin/preview …` (PREVIEW-3, PREVIEW-13).

## Adding a skill

Prefer a folder skill over changing Elixir code.

1. Create `skills/<name>/SKILL.md` with frontmatter (`name`, `description`) followed by instructions.
2. Optionally add `skills/<name>/tools.json` with script-backed tools and the scripts they run. The format is documented in `lib/elia/skills/folder.ex`.
3. Call `reload_skills` and fix any reported errors. New tools are available from the next step.
4. Tool input arrives in `$ELIA_INPUT` (JSON) and `$ELIA_ARG_<FIELD>`. Never splice it into the command.

Folder skills don't need a spec. Built-in skills live in `lib/elia/skills/` and do.
