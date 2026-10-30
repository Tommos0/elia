# Harness and guardrails

Read this before editing `lib/`, `config/`, `test/`, `mix.exs` or `skills/`, or before calling `hot_reload`.

Specs: `specs/guarded-files.md`, `specs/hot-reload.md`, `specs/checkpoints.md`, `specs/verification.md`, `specs/workspace-policy.md`, `specs/folder-skills.md`.

## What needs approval

- `skills/**` changes apply without asking, but a folder skill's tools always ask the user before running.
- Elixir changes (`lib/`, `config/`, `test/`) need the user's approval.
- The workspace is checkpointed (`Elia.Checkpoint`) before the first change of each turn.
- When a turn that changed Elixir files ends, the harness runs `mix test`. If it fails, the changes are rolled back and you're told why. Run `run_tests` yourself before finishing.

## Guarded files

- The guarded list is `@patterns` in `lib/elia/guarded.ex` (spec: GUARD-1). It covers the harness, checkpoint, workspace, tool, shell, skills registry, application, agent loop, `lib/elia/skills/*.ex`, the endpoint, `config/**`, `mix.exs`, `mix.lock`, and two self-modification tests. The approval UI flags writes to them.
- **Never** edit `lib/elia/harness.ex`, `lib/elia/checkpoint.ex` or `lib/elia/workspace.ex` to weaken the guardrails.
- Tell the user when a change touches guarded files.

## Recovery

- In the dev server, `/recover` (`EliaWeb.Recovery`, spec: `specs/recovery.md`) rolls the workspace back to a checkpoint. It sits before the code reloader in the endpoint, so it works when the app doesn't compile. Crash pages (HTML 500) get a banner linking to it.
- It's guarded and may only call other guarded modules (RECOVER-8). Don't make it depend on reloadable app code.

## When `hot_reload` is needed

- **Always, for any Elixir change** (`lib/`, `config/`, `mix.exs`), guarded or not. The dev server never reloads code on a request (GUARD-8), so edits stay *pending* (GUARD-10) and the running app keeps the old code until `hot_reload` succeeds. This means a multi-file edit can't break the app halfway: finish all the edits, run `run_tests`, then call `hot_reload`.
- Browser live reload doesn't watch `lib/` either (GUARD-13). Reload the page after `hot_reload` to see UI changes.
- `hot_reload` runs the full test suite first, then recompiles and loads everything. If tests fail, the turn's changes are rolled back. A compile error is returned and the running app is unaffected.
- Not needed for `skills/**` (use `reload_skills`) or for tests and docs.

## Adding a skill

Prefer a folder skill over changing Elixir code.

1. Create `skills/<name>/SKILL.md` with frontmatter (`name`, `description`) followed by instructions.
2. Optionally add `skills/<name>/tools.json` with script-backed tools and the scripts they run. The format is documented in `lib/elia/skills/folder.ex`.
3. Call `reload_skills` and fix any reported errors. New tools are available from the next step.
4. Tool input arrives in `$ELIA_INPUT` (JSON) and `$ELIA_ARG_<FIELD>`. Never splice it into the command.

Folder skills don't need a spec. Built-in skills live in `lib/elia/skills/` and do.
