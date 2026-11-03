# Test runs

Status: Implemented (VERIFY-1, VERIFY-2); the end-of-turn verification is
retired

`run_tests` runs the test suite in the workspace. There used to be an
end-of-turn verification as well: when a turn had changed Elixir files the
harness ran the full suite and rolled the turn back when it failed (VERIFY-3 to
VERIFY-7, LOOP-13 to LOOP-15). It is retired. A chat in Elia's own project edits
its own worktree, so a turn that breaks the suite cannot reach the running tree
(DEPLOY-1), and the deploy gate already runs the full suite, then a compile,
before loading anything (DEPLOY-5, HOT-4, HOT-6). Running the tests is the
agent's own step — `AGENTS.md` and the `self-modification` skill tell it to run
plain `mix precommit` before finishing a change (a command never inherits the
server's `MIX_ENV`, ISOL-24, so the alias's `preferred_envs` picks `test`) — and
the user runs them again through a deploy.

## Requirements

- **VERIFY-1** `run_tests` runs `mix test` with `MIX_ENV=test` in the
  workspace, with a 10-minute timeout. Output is formatted like the shell
  tool's (SHELL-4).
- **VERIFY-2** `run_tests` only accepts arguments that can't run arbitrary
  code:
  - test paths under `test/` with no `..`, optionally `path:line`;
  - the flags `--failed`, `--stale` and `--trace`;
  - `--seed`, `--max-failures`, `--only` and `--exclude`, each followed by a
    value matching `[\w:.-]+`.

  Anything else is rejected with an error before any command runs.

- ~~**VERIFY-3** At the end of a turn, if the turn took a checkpoint and changed
  `.ex`, `.exs` or `.heex` files in the core class, the full test suite runs.
  Otherwise verification is skipped (`:unchanged`).~~ Retired: a turn is not
  verified.
- ~~**VERIFY-4** If the tests fail, the workspace is rolled back to the turn's
  checkpoint, skills are reloaded and the test output is returned
  (`{:rolled_back, output}`). The loop then continues (LOOP-13).~~ Retired:
  nothing is rolled back (CKPT).
- ~~**VERIFY-5** If the rollback itself fails, verification returns an error
  that includes both the rollback error and the test output.~~ Retired: there is
  no rollback.
- ~~**VERIFY-6** Changes under `skills/` never cause a test run.~~ Retired:
  nothing causes a test run on its own any more.
- ~~**VERIFY-7** `Elia.Harness.core_elixir_changed?/1` says whether the turn took
  a checkpoint and changed core `.ex`, `.exs` or `.heex` files since (the
  condition of VERIFY-3), without running or rolling back anything. It returns
  `{:error, reason}` when the changes can't be checked.~~ Retired: its last
  caller was the spawn path, which stopped using it when SUBTASK-14 was retired.

## Implementation

`Elia.Harness.run_tests/2` (the tool's `run` is in `Elia.Skills.Harness`,
PROJ-16). `Elia.Harness` no longer has `verify/2` or `core_elixir_changed?/1`;
`Elia.Agent.Loop` no longer has a verification step.

## Tests

`test/elia/self_modification_test.exs` (`run_tests`).
