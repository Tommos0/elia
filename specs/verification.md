# Test runs

Status: Implemented (VERIFY-1, VERIFY-2); the end-of-turn verification is
retired; VERIFY-8 to VERIFY-10 are Draft

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

A test run has two clocks. The per-test one comes from `mix test --timeout`
(VERIFY-8), so a test that hangs fails the run instead of holding it; the run's
own was a hard-coded 10 minutes and is now a setting a call can raise within
its ceiling (VERIFY-9). A run stopped by its own timeout says so, and says
which way to give it more (VERIFY-10): a chat's first run in a fresh worktree
compiles deps and app before its first test, and such a run has to be given the
time rather than killed halfway through the compile and started again.

## Requirements

- **VERIFY-1** `run_tests` runs `mix test` with `MIX_ENV=test` in the
  workspace, with `--timeout` for the per-test timeout (VERIFY-8) and the
  configured whole-run timeout (VERIFY-9, 600s by default). Output is formatted
  like the shell tool's (SHELL-4).
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

- **VERIFY-8** The run has a **per-test timeout**, `mix test`'s own:
  `run_tests` passes `--timeout <ms>` from `config :elia, Elia.Harness,
  test_timeout: 60_000` — ExUnit's own default, so a suite that sets nothing
  behaves exactly as it does today — or from a call's `test_timeout_ms`, which
  is an integer of 1 or more and never above the configured `max_test_timeout`
  (600_000). It bounds a test that sets no timeout of its own, so one test that
  hangs fails the run instead of holding it for the run's whole budget.
  ExUnit's own rules stand above it and nothing here can override them: a
  test's `@tag timeout:` — an `:infinity` one included — wins over the
  configured default, and `--trace` (VERIFY-2) makes ExUnit set the timeout to
  `:infinity` and ignore both. The whole-run timeout (VERIFY-9) is what bounds
  a run those leave unbounded.
- **VERIFY-9** The **whole-run timeout** is configurable and bounded:
  `config :elia, Elia.Harness, timeout: 600` (seconds — today's 10 minutes, now
  a setting) with `max_timeout: 1_800`. The `run_tests` tool takes
  `timeout_seconds` for one call — a positive integer, clamped to the maximum
  like the shell tool's (SHELL-10) — so a run can be given longer than the
  default on purpose: a chat's first run in a fresh worktree compiles deps and
  app before it tests anything, and a run killed halfway through that wastes
  the compile. A value below 1 is an error result and nothing runs. The tool's
  description names the default and the maximum, so a long run is asked for
  rather than run into. The deploy's own suite run (DEPLOY-5, ISOL-14) uses the
  same configured default: no chat's setting is involved.
- **VERIFY-10** A run that reaches its timeout says so and names the lever: the
  result is SHELL-4's error with the output collected so far,
  `[exit: timeout after 600s]`, followed by a line saying the run was stopped
  by its timeout and that a call may ask for another (`timeout_seconds`, up to
  `max_timeout`) — so a run killed for being long is never read as a suite that
  failed, and the model knows what to change instead of running it again
  unchanged.

## Configuration

```elixir
config :elia, Elia.Harness,
  timeout: 600,              # seconds, the whole run (VERIFY-9)
  max_timeout: 1_800,        # seconds, the most a call may ask for (VERIFY-9)
  test_timeout: 60_000,      # ms, `mix test --timeout`, per test (VERIFY-8)
  max_test_timeout: 600_000  # ms, the most a call may ask for (VERIFY-8)
```

## Out of scope

- A per-test timeout that holds over a test's own `@tag timeout:`: ExUnit has
  only the default `:timeout` and no maximum, and `--trace` sets it to
  `:infinity` (VERIFY-8), so a tagged or traced test is bounded by the run's
  timeout alone.
- The suite's partitions (`bin/test`, SUITE) and `mix precommit`: their tests
  get ExUnit's own default and the whole partition is bounded by the shell
  call's timeout (SHELL-3, SHELL-10), which is why a suite run wants a longer
  `timeout_seconds` than the shell's default.

## Implementation

`Elia.Harness.run_tests/3` (the command's `--timeout`, the run's timeout, the
timeout message — VERIFY-8, VERIFY-9, VERIFY-10; the tool's `run` is in
`Elia.Skills.Harness`, PROJ-16). `Elia.Harness` no longer has `verify/2` or
`core_elixir_changed?/1`; `Elia.Agent.Loop` no longer has a verification step.

## Tests

`test/elia/self_modification_test.exs` (`run_tests`: the command it builds and
the flags it adds, VERIFY-8; the configured timeout and its clamp, VERIFY-9;
what a timed-out run says, VERIFY-10).
