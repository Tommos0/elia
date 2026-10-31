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

## Layout

| Module | Role |
| --- | --- |
| `Elia.LLM` / `Elia.LLM.Provider` | Provider-neutral model calls; `Elia.LLM.Anthropic` is the default backend |
| `Elia.Agent.Session` / `Elia.Agent.Loop` | One process per chat; the tool-use loop with approvals |
| `Elia.Skills` | Registry of built-in and folder skills, reloadable at runtime |
| `Elia.Skills.{Shell,Files,Harness}` | Built-in skills: shell, file editing, self-management |
| `Elia.Checkpoint` | Workspace snapshots under `refs/elia/checkpoints/` |
| `Elia.Harness` | Test runs, end-of-turn verification, rollback, hot reload |
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
  git ref. Snapshots never touch HEAD, the branch or the index.
- **Verification**: when a turn changed Elixir files outside `skills/`, the
  harness runs `mix test` at the end; on failure the turn's changes are rolled
  back and the agent is told why (at most twice per turn).
- **Hot reload**: `hot_reload` (dev server only) runs the whole suite before
  loading new code into the running app. The dev server never reloads code on
  its own, so edits to `lib/`, `config/` and mix files stay pending until
  `hot_reload` succeeds. A multi-file edit can't break the running app halfway.
- **Guarded files**: the files that enforce these guardrails (listed in
  `Elia.Guarded`: harness, checkpoints, workspace policy, the tool loop,
  built-in skills, endpoint, config, mix files and the guardrail tests) are
  flagged in approval prompts.
- **Recovery**: in the dev server, `/recover` (also through a proxy; POSTs must be same-origin) lists
  checkpoints and rolls the workspace back to one. It's served before the code
  reloader, so it works even when the app shows a compilation error, and
  crash pages get a banner linking to it (`EliaWeb.Recovery`).

The shell tool can do anything you approve, including bypassing these
policies, so read commands before approving them.
