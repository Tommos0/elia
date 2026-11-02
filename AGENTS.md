# Elia

A local AI harness with a Phoenix LiveView chat UI. The agent works through skills and can change its own code behind guardrails. Module layout is in `README.md`. Features are specified in `specs/` (index and workflow in `specs/README.md`).

## Always

- This project is spec-driven. Before changing behaviour, update or add the spec in `specs/`. Then implement it and test each requirement you touched, citing its ID (e.g. `# SHELL-3`). Never renumber or reuse a requirement ID. When you add a spec, add it to the index table in `specs/README.md`
- Use the `mix precommit` alias when you are done with all changes and fix any pending issues. Run it as `MIX_ENV=test mix precommit` (the inherited `MIX_ENV=dev` defeats the alias's `preferred_envs`; see `docs/agents/elixir.md`)
- Commit to git whenever you finish a feature (after tests/`mix precommit` pass). Use a `feat: <summary>` message (or `fix:`/`docs:` etc. as appropriate), and commit only that feature's changes. Never commit a half-finished feature
- When the user states a standing preference, rule or workflow ("whenever you…", "always…", "never…", "from now on…"), record it in this file (`AGENTS.md`) in the same turn, as a bullet under "Always" (or in the matching `docs/agents/` file if it is topic-specific, then say so here). Don't just acknowledge it verbally, since you won't remember it next session. Then tell the user which file and line you updated
- Read, create and edit files with the file tools (`read_file`, `write_file`, `edit_file`), never with `shell` (`cat`, `sed`, `echo >`, heredocs, Python/other scripts). Use `shell` only to run programs such as `mix`, `git` and `grep`. Shell edits skip the workspace policy and the user's file-change review
- Shell commands run with `bash -c` where bash is installed, otherwise POSIX `sh -c` (SHELL-2, `Elia.Shell.shell/1`), so write commands that also work under `sh`: bash-only syntax such as `${PIPESTATUS[0]}`, `[[ ... ]]`, arrays and `set -o pipefail` fails where the shell is `sh`, and after a pipeline `$?` is the last command's status (a failing `mix test | tail` looks like a success). Prefer one command that reports the status you mean, and `bash -c '...'` explicitly only when you really need bash
- The dev server never reloads code on its own: a request recompiles and loads nothing, and a change to `lib/`, `config/` or `mix.exs` reaches the running app only through a *deploy*. `hot_reload` runs the full test suite, merges the chat's branch into `live` and reloads the running app; the chat UI's restart button does the same and then restarts the server. So make all the edits for a change first, run the tests, then deploy. A change isn't live until a deploy has run
- A chat in Elia's own project works in its own git worktree, on branch `chat/<chat id>` forked from `live`, not in the live tree the server runs from (DEPLOY-1). That worktree is the chat's workspace root, and Elia's data (`.elia`, including the worktrees) sits under the live tree, `Elia.Workspace.runtime_root/0`. A deploy needs the live tree on the branch `live` (`git checkout -b live` once); until then a chat in Elia's own project works in the live tree itself
- Use the already included `Req` library for HTTP requests. **Avoid** `:httpoison`, `:tesla` and `:httpc`
- There is no database or Ecto. Saved conversations are files in `.elia/sessions/` (`Elia.Store`)

## Read before you…

This file (`AGENTS.md`) is injected into the system prompt. The files below are not, so open them before starting the task.

| Task | Read |
| --- | --- |
| Edit `lib/`, `config/`, `test/`, `mix.exs` or `skills/`; add a skill; use `hot_reload` | `docs/agents/harness.md` |
| Write or change Elixir | `docs/agents/elixir.md` |
| Touch LiveViews, HEEx templates, the router or forms | `docs/agents/phoenix-liveview.md` |
| Touch CSS, JS, assets, components or layouts | `docs/agents/frontend.md` |
| Write or change tests | `docs/agents/testing.md` |
| Add or change a feature | `specs/README.md`, then the relevant spec |
