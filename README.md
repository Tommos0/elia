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
| `Elia.Harness` | Running the test suite (`run_tests`) |
| `Elia.Deploy` | Chat worktrees, the trunk `master` and `live`, deploying (hot reload or restart) |
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

- **Approval**: shell commands, script tools and writes outside `skills/` need
  the user's approval. Writes under `skills/` don't. `.git`,
  `_build`, `deps` and `.elia` can't be written by the file tools, and paths
  outside the workspace are refused. With the jail on — the default — the file
  tools reach the workspace and nothing else: reading outside it is refused too,
  and so is a path that resolves through a symlink out of it, so they reach no
  further than a jailed command does (FILE-12, FILE-13).
- **Tests**: nothing runs the test suite for you at the end of a turn. The agent
  runs `run_tests` (or plain `mix precommit`: no command inherits the server's
  `MIX_ENV`, so the alias's `preferred_envs` picks `test`, ISOL-24) itself before
  finishing a change, and a deploy runs the full suite in the live tree before
  loading anything.
- **Deploying**: the server runs from the *live tree*; a chat in Elia's own
  project works in its own git worktree (branch `chat/<chat id>`, forked from
  the trunk `master`), so an in-progress edit can't reach the running app. When a
  change is done the agent merges its branch into `master` itself (fast-forward
  only); the user then deploys from the Settings page, which brings `master` to
  `live` and loads it — by "Hot reload" (the test suite first, then a recompile
  and reload, keeping running state) or by "Restart", which restarts the server
  in a clean process. A request never reloads code (`Elia.Deploy`).
- **Recovery**: there is no recovery page or checkpoint to roll back to; a chat's
  work is on its own branch, and a deploy refuses to load a tree whose suite or
  compile fails (DEPLOY-5, HOT-4).

The shell tool can do anything you approve, including bypassing these
policies, so read commands before approving them.
