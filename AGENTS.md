# Elia

A local AI harness with a Phoenix LiveView chat UI. The agent works through skills and can change its own code behind guardrails. Module layout is in `README.md`. Features are specified in `specs/` (index and workflow in `specs/README.md`).

## Always

- This project is spec-driven. Before changing behaviour, update or add the spec in `specs/`. Then implement it and test each requirement you touched, citing its ID (e.g. `# SHELL-3`). Never renumber or reuse a requirement ID. When you add a spec, add it to the index table in `specs/README.md`
- Use the `mix precommit` alias when you are done with all changes and fix any pending issues
- Commit to git whenever you finish a feature (after tests/`mix precommit` pass). Use a `feat: <summary>` message (or `fix:`/`docs:` etc. as appropriate), and commit only that feature's changes. Never commit a half-finished feature
- When the user states a standing preference, rule or workflow ("whenever you…", "always…", "never…", "from now on…"), record it in this file (`AGENTS.md`) in the same turn, as a bullet under "Always" (or in the matching `docs/agents/` file if it is topic-specific, then say so here). Don't just acknowledge it verbally, since you won't remember it next session. Then tell the user which file and line you updated
- Read, create and edit files with the file tools (`read_file`, `write_file`, `edit_file`), never with `shell` (`cat`, `sed`, `echo >`, heredocs, Python/other scripts). Use `shell` only to run programs such as `mix`, `git` and `grep`. Shell edits skip the workspace policy and the user's file-change review
- Never send several `edit_file`/`write_file` calls for the same file in one parallel batch. Each call reads, changes and rewrites the whole file, so parallel calls race and lose or duplicate edits. Edit a file one call at a time (calls on different files may be batched), and check the result with `mix compile --warnings-as-errors` or `git diff` when a file needed several edits
- The dev server never reloads code on its own: edits to `lib/`, `config/` and `mix.exs` stay pending until the `hot_reload` tool succeeds. So make all the edits for a change first, then run tests and call `hot_reload`. Intermediate states can't break the running app. A change isn't live until `hot_reload` has run
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
