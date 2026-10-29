# Turn verification

Status: Implemented

When the agent changes Elixir code, the test suite has to pass at the end of
the turn. If it doesn't, the turn's changes are rolled back and the agent
gets a chance to fix them.

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
- **VERIFY-3** At the end of a turn, if the turn took a checkpoint and changed
  `.ex`, `.exs` or `.heex` files in the core class, the full test suite runs.
  Otherwise verification is skipped (`:unchanged`).
- **VERIFY-4** If the tests fail, the workspace is rolled back to the turn's
  checkpoint, skills are reloaded and the test output is returned
  (`{:rolled_back, output}`). The loop then continues (LOOP-13).
- **VERIFY-5** If the rollback itself fails, verification returns an error
  that includes both the rollback error and the test output.
- **VERIFY-6** Changes under `skills/` never cause a test run.

## Implementation

`Elia.Harness.run_tests/1`, `Elia.Harness.verify/1`.

## Tests

`test/elia/self_modification_test.exs`, `test/elia/agent_test.exs`.
