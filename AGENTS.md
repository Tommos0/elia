# Elia

A local AI harness with a Phoenix LiveView chat UI. The agent works through skills and can change its own code behind guardrails. Module layout is in `README.md`. Features are specified in `specs/` (index and workflow in `specs/README.md`).

## Always

- This project is spec-driven. Before changing behaviour, update or add the spec in `specs/`. Then implement it and test each requirement you touched, citing its ID (e.g. `# SHELL-3`). Never renumber or reuse a requirement ID. When you add a spec, add it to the index table in `specs/README.md`
- After drafting or updating a spec, stop and ask the user to approve it before implementing, unless the user explicitly asked to skip the spec approval for this change. Wait for that approval before touching code or tests
- Use the `mix precommit` alias when you are done with all changes and fix any pending issues. Plain `mix precommit`: no command inherits `MIX_ENV`, so the alias's `preferred_envs` applies and it runs the tests in `test` (ISOL-24; see `docs/agents/elixir.md`)
- Commit to git whenever you finish a feature (after tests/`mix precommit` pass). Use a `feat: <summary>` message (or `fix:`/`docs:` etc. as appropriate), and commit only that feature's changes. Never commit a half-finished feature
- When the user states a standing preference, rule or workflow ("whenever you…", "always…", "never…", "from now on…"), record it in this file (`AGENTS.md`) in the same turn, as a bullet under "Always" (or in the matching `docs/agents/` file if it is topic-specific, then say so here). Don't just acknowledge it verbally, since you won't remember it next session. Then tell the user which file and line you updated
- Read, create and edit files with the file tools (`read_file`, `write_file`, `edit_file`), never with `shell` (`cat`, `sed`, `echo >`, heredocs, Python/other scripts). Use `shell` only to run programs such as `mix`, `git` and `grep`. Shell edits skip the workspace policy and the user's file-change review
- Shell commands run with `bash -c` where bash is installed, otherwise POSIX `sh -c` (SHELL-2, `Elia.Shell.shell/1`), so write commands that also work under `sh`: bash-only syntax such as `${PIPESTATUS[0]}`, `[[ ... ]]`, arrays and `set -o pipefail` fails where the shell is `sh`, and after a pipeline `$?` is the last command's status (a failing `mix test | tail` looks like a success). Prefer one command that reports the status you mean, and `bash -c '...'` explicitly only when you really need bash
- The dev server never reloads code on its own: a request recompiles and loads nothing, and a change to `lib/`, `config/` or `mix.exs` reaches the running app only through a *deploy*. **When a change is done, commit it and merge your own branch into the trunk yourself**: rebase on `master` if it has moved, then `git push . HEAD:master` (fast-forward only, so `master` must be an ancestor of your branch — DEPLOY-13). The harness never merges your branch. Deploying is the user's step, in the chat UI's Settings page: a deploy brings `master` to `live` (fast-forward, after the full test suite) and loads it — "Hot reload", which recompiles and loads the live tree keeping running state, or "Restart", which restarts the server. So make all the edits for a change first, run the tests, then commit and merge; don't expect the change to be live until the user has deployed it
- When a change touches the UI (a template, `assets/css/`, `assets/js/` or a colocated hook), show the user what it looks like before it is deployed: run `bin/preview` in the chat's workspace and put the Markdown image links it prints into your reply. It screenshots the workspace's own code in a real headless browser, in the test env — no deploy, no API key — and its first run in a workspace builds assets and starts a browser, so give the `shell` call a longer `timeout_seconds` (PREVIEW-9, `specs/ui-preview.md`). Preview in dark mode at a mobile width by default — `ELIA_PREVIEW_THEME=dark ELIA_PREVIEW_WIDTH=390 bin/preview …` (PREVIEW-3, PREVIEW-13) — and take a light or desktop picture as well only when the change is about that
- A chat in Elia's own project works in its own git worktree, on branch `chat/<chat id>` forked from the trunk `master` (not from `live`), not in the live tree the server runs from (DEPLOY-1). That worktree is the chat's workspace root, and Elia's data (`.elia`, including the worktrees) sits under the live tree, `Elia.Workspace.runtime_root/0`. A deploy needs the live tree *set up for deployment*: on the branch `live`, with a `master` at or ahead of it (`git checkout -b live` and `git branch master` once; `git branch -f master live` once if the trunk is behind); until then a chat in Elia's own project works in the live tree itself, and the Settings page says what is missing (DEPLOY-14)
- Use the already included `Req` library for HTTP requests. **Avoid** `:httpoison`, `:tesla` and `:httpc`
- There is no database or Ecto. Saved conversations are files in `.elia/sessions/` (`Elia.Store`)

## Read before you…

This file (`AGENTS.md`) is injected into the system prompt. The files below are not, so open them before starting the task.

| Task | Read |
| --- | --- |
| Edit `lib/`, `config/`, `test/`, `mix.exs` or `skills/`; add a skill; merge to `master`; deploy | `docs/agents/harness.md` |
| Write or change Elixir | `docs/agents/elixir.md` |
| Touch LiveViews, HEEx templates, the router or forms | `docs/agents/phoenix-liveview.md` |
| Touch CSS, JS, assets, components or layouts | `docs/agents/frontend.md` |
| Write or change tests | `docs/agents/testing.md` |
| Add or change a feature | `specs/README.md`, then the relevant spec |
