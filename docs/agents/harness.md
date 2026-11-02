# Harness and guardrails

Read this before editing `lib/`, `config/`, `test/`, `mix.exs` or `skills/`, or before calling `hot_reload`.

Specs: `specs/deployment.md`, `specs/hot-reload.md`, `specs/checkpoints.md`, `specs/verification.md`, `specs/workspace-policy.md`, `specs/folder-skills.md`.

## What needs approval

- `skills/**` changes apply without asking, but a folder skill's tools always ask the user before running.
- Elixir changes (`lib/`, `config/`, `test/`) need the user's approval.
- The workspace is checkpointed (`Elia.Checkpoint`) before the first change of each turn.
- When a turn that changed Elixir files ends, the harness runs `mix test`. If it fails, the changes are rolled back and you're told why. Run `run_tests` yourself before finishing.

## The live tree and chat worktrees

- The live tree (`Elia.Workspace.runtime_root/0`, `config :elia, :runtime_root`, default: where the server was started) is where the server runs, where the code reloader reloads and where Elia's data (`.elia`) lives (DEPLOY-2). It is never edited by an agent.
- A chat in Elia's own project works in its own git worktree, `<live tree>/.elia/worktrees/<chat id>`, on branch `chat/<chat id>` forked from `live` (DEPLOY-1). That worktree is the chat's workspace root: the file and shell tools, checkpoints, `mix test` and the end-of-turn verification all run there, through `ctx[:workspace]`. A sub-task in Elia's own project works in its own worktree, branch `chat/<sub-task id>` forked from its parent's branch; finished as `done`, its branch is merged into the parent's (DEPLOY-9, SUBTASK-23, SUBTASK-25).
- Chats in other projects work in the project's folder, with no worktree (PROJ-12).
- A chat gets a worktree only when the live tree is on the branch `live`, the fork point and deploy target. Otherwise (a tree that was never set up for deployment) it works in the live tree itself, and a deploy only reloads. Set it up once with `git checkout -b live`.
- **Never** edit `lib/elia/harness.ex`, `lib/elia/checkpoint.ex` or `lib/elia/workspace.ex` to weaken the guardrails.

## Recovery

- In the dev server, `/recover` (`EliaWeb.Recovery`, spec: `specs/recovery.md`) rolls the workspace back to a checkpoint. It sits before the code reloader in the endpoint, so it works when the app doesn't compile. Crash pages (HTML 500) get a banner linking to it.
- Don't make it depend on reloadable app code.

## Deploying: `hot_reload` and the restart button

- A deploy is the only thing that loads code into the running app (DEPLOY-8): a request recompiles and loads nothing, so edits stay invisible to the running app until a deploy. Browser live reload doesn't watch `lib/` either. Reload the page after a deploy to see UI changes.
- `hot_reload` (`Elia.Harness.hot_reload/2`) runs the full test suite **in the chat's worktree**, merges `chat/<chat id>` into `live` (fast-forward only, so rebase on `live` first) and then recompiles and loads the live tree, keeping running state (DEPLOY-5, DEPLOY-6). If the tests fail, nothing is merged or loaded and the turn's changes are rolled back (HOT-4).
- The chat UI's restart button does the same and then restarts the server, so it comes up on the deployed code in a clean process (DEPLOY-7, RESTART-11). It stops the runtime system with a non-zero status, which `bin/serve` turns into a restart (RESTART-1).
- Make all the edits for a change first, run `run_tests`, then deploy — a multi-file edit is on the chat's branch, so the running app can't be broken halfway.
- Not needed for `skills/**` (use `reload_skills`) or for tests and docs.

## Adding a skill

Prefer a folder skill over changing Elixir code.

1. Create `skills/<name>/SKILL.md` with frontmatter (`name`, `description`) followed by instructions.
2. Optionally add `skills/<name>/tools.json` with script-backed tools and the scripts they run. The format is documented in `lib/elia/skills/folder.ex`.
3. Call `reload_skills` and fix any reported errors. New tools are available from the next step.
4. Tool input arrives in `$ELIA_INPUT` (JSON) and `$ELIA_ARG_<FIELD>`. Never splice it into the command.

Folder skills don't need a spec. Built-in skills live in `lib/elia/skills/` and do.
