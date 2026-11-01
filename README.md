# Elia

A local AI harness with a chat UI (Phoenix LiveView). The agent works through
skills, can extend itself with new ones, and can change its own code behind
guardrails.

```sh
export ANTHROPIC_API_KEY=...
mix setup
mix phx.server          # http://localhost:7000
```

To have the server restart itself after a crash, run `bin/serve` instead of
`mix phx.server` (see `specs/auto-restart.md`). Ctrl-C stops it for good; attach
a shell with `iex --sname dbg --remsh elia`.

To run it as a systemd user service (starts at login, restarts on failure), stop
any running server and run `bin/install-service --now`. Put API keys in
`~/.config/elia/env` (`ANTHROPIC_API_KEY=...`), follow the logs with
`journalctl --user -u elia -f`, and run `loginctl enable-linger $USER` to start
it at boot without a login.

## Layout

| Module | Role |
| --- | --- |
| `Elia.LLM` / `Elia.LLM.Provider` | Provider-neutral model calls; `Elia.LLM.Anthropic` is the default backend |
| `Elia.Agent.Session` / `Elia.Agent.Loop` | One process per chat; the tool-use loop with approvals |
| `Elia.Skills` | Registry of built-in and folder skills, reloadable at runtime |
| `Elia.Skills.{Shell,Files,Harness,Tasks}` | Built-in skills: shell, file editing, self-management, sub-tasks |
| `Elia.Tasks` | Lock and spawn/await for sub-task chats (`spawn_task`, `finish_task`) |
| `Elia.Checkpoint` | Workspace snapshots under `refs/elia/checkpoints/` |
| `Elia.Harness` | Test runs, end-of-turn verification, rollback, hot reload |
| `Elia.Deploy` | Chat worktrees, merging a chat's branch into `live`, restarting |
| `Elia.Projects` | Project folders; every chat belongs to one and works in it (its worktree for Elia's own project) |
| `Elia.Store` | Saved conversations in `.elia/sessions/` |

## Folder skills

Drop a folder in `skills/` (the agent can do this itself) and call
`reload_skills`:

```
skills/git-summary/
  SKILL.md       # ---\nname: git-summary\ndescription: ...\n---\nInstructions
  tools.json     # optional script-backed tools
  summary.sh
```

See `Elia.Skills.Folder` for the `tools.json` format. Tool input arrives in
`$ELIA_INPUT` (JSON) and `$ELIA_ARG_<FIELD>`, never spliced into the command.

## Guardrails

- **Approval**: shell commands, script tools, writes outside `skills/`,
  `hot_reload` and `rollback` need the user's approval. Writes under `skills/`
  don't. `.git`, `_build`, `deps` and `.elia` can't be written by the file
  tools, and paths outside the workspace are refused.
- **Checkpoints**: the first change in each turn snapshots the workspace to a
  git ref. Only a chat in Elia's own project is snapshotted, in its own worktree;
  a project folder that is its own git repo is left alone. Snapshots never touch
  HEAD, the branch or the index.
- **Verification**: when a turn changed Elixir files outside `skills/`, the
  harness runs `mix test` at the end; on failure the turn's changes are rolled
  back and the agent is told why (at most twice per turn).
- **Deploying**: the server runs from the *live tree*; a chat in Elia's own
  project works in its own git worktree (branch `chat/<chat id>`), so an
  in-progress edit can't reach the running app. A deploy merges the branch into
  `live` (fast-forward only) and loads it: `hot_reload` (dev server only) — the
  test suite first, then a recompile and reload, keeping running state — or the
  chat UI's restart button, which restarts the server in a clean process. A
  request never reloads code (`Elia.Deploy`).
- **Recovery**: in the dev server, `/recover` (also through a proxy; POSTs must be same-origin) lists
  checkpoints and rolls the workspace back to one. It's served before the code
  reloader, so it works even when the app shows a compilation error, and
  crash pages get a banner linking to it (`EliaWeb.Recovery`).

The shell tool can do anything you approve, including bypassing these
policies, so read commands before approving them.
