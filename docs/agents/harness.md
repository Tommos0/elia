# Harness and guardrails

Read this before editing `lib/`, `config/`, `test/`, `mix.exs` or `skills/`.

Specs: `specs/deployment.md`, `specs/hot-reload.md`, `specs/verification.md`, `specs/workspace-policy.md`, `specs/folder-skills.md`.

## What needs approval

- `skills/**` changes apply without asking, but a folder skill's tools always ask the user before running.
- Elixir changes (`lib/`, `config/`, `test/`) need the user's approval.

## The live tree and chat worktrees

- The live tree (`Elia.Workspace.runtime_root/0`, `config :elia, :runtime_root`, default: where the server was started) is where the server runs, where the code reloader reloads and where Elia's data (`.elia`) lives (DEPLOY-2). It is never edited by an agent.
- A chat in Elia's own project works in its own git worktree, `<live tree>/.elia/worktrees/<chat id>`, on branch `chat/<chat id>` forked from the trunk `master` (DEPLOY-1, DEPLOY-13). That worktree is the chat's workspace root: the file and shell tools run there, as does `mix test`, through `ctx[:workspace]`. A sub-task in Elia's own project works in its own worktree, branch `chat/<sub-task id>` forked from its parent's branch; its work stays there, for the parent agent to merge itself (DEPLOY-9, SUBTASK-23, SUBTASK-25). `spawn_task` returns as soon as the child has started and the parent goes on working; several children run at once, each in its own worktree, and the parent collects results with `list_tasks` and `await_task` (SUBTASK-2, SUBTASK-26, SUBTASK-27, SUBTASK-28).
- Chats in other projects work in the project's folder, with no worktree (PROJ-12).
- A chat gets a worktree only when the live tree is *set up for deployment*: checked out on the branch `live`, with a `master` trunk at or ahead of it (DEPLOY-14, `Elia.Deploy.deployable/1`). Otherwise it works in the live tree itself. Set it up once with `git checkout -b live` and `git branch master`; a tree whose trunk is behind `live` needs `git branch -f master live` once.
- **Never** edit `lib/elia/harness.ex` or `lib/elia/workspace.ex` to weaken the guardrails.

## Tests

- A turn is not verified: nothing runs `mix test` for you at the end of a turn, and nothing is rolled back. Run `run_tests` (or plain `mix precommit` — a command never inherits the server's `MIX_ENV`, ISOL-24) before finishing a change; a deploy runs the full suite in the live tree again (DEPLOY-5).

## Recovery

- There is no checkpoint to roll back to and no `/recover` page (`specs/checkpoints.md`, `specs/recovery.md`): a chat's work is on its own branch, and a deploy refuses to load a tree whose suite or compile fails (DEPLOY-5, HOT-4).

## Deploying

- A deploy is the only thing that loads code into the running app (DEPLOY-8): a request recompiles and loads nothing, so edits stay invisible to the running app until a deploy. Browser live reload doesn't watch `lib/` either. Reload the page after a deploy to see UI changes.
- **Merging your work into the trunk is your step; deploying is the user's.** When a change is done: commit it, rebase on `master` if the trunk has moved, then `git push . HEAD:master` — fast-forward only, so the trunk must be an ancestor (DEPLOY-13). `AGENTS.md` and the `self-modification` skill say the same. The harness never merges your branch.
- The user then deploys from the Settings page (`Elia.Deploy.deploy/1`, DEPLOY-5..DEPLOY-7): Elia runs the full test suite in the live tree, fast-forwards `live` to `master` (rolling it back if the tests fail, HOT-4) and loads the result — by "Hot reload", which recompiles and loads the live tree keeping running state (DEPLOY-6), or by "Restart", which stops the runtime system with a non-zero status so `bin/serve` starts it again on the deployed code in a clean process (DEPLOY-7, RESTART-1).
- Make all the edits for a change first, run `run_tests`, then commit and merge — a multi-file edit is on the chat's branch, so the running app can't be broken halfway. Don't expect the change to be live until the user has deployed it.
- Not needed for `skills/**` (use `reload_skills`) or for tests and docs.
- A UI change — a template, `assets/css/`, a hook — can be seen *before* it is deployed: `bin/preview` in the chat's workspace screenshots its own code in a real headless browser, in the test env, and prints a Markdown image link per page (PREVIEW, `specs/ui-preview.md`). Nothing is deployed, no API key is involved and no live data is read; the pictures land in the gitignored `tmp/preview/`, and the running app serves a chat's own ones at `/preview/<chat id>/<file>` (PREVIEW-7). Paste the links into a reply to show the user.

## Adding a skill

Prefer a folder skill over changing Elixir code.

1. Create `skills/<name>/SKILL.md` with frontmatter (`name`, `description`) followed by instructions.
2. Optionally add `skills/<name>/tools.json` with script-backed tools and the scripts they run. The format is documented in `lib/elia/skills/folder.ex`.
3. Call `reload_skills` and fix any reported errors. New tools are available from the next step.
4. Tool input arrives in `$ELIA_INPUT` (JSON) and `$ELIA_ARG_<FIELD>`. Never splice it into the command.

Folder skills don't need a spec. Built-in skills live in `lib/elia/skills/` and do.
