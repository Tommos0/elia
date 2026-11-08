# Parallel test suite

Status: Implemented

The suite is mostly serial: 44 files are `async: false`, so a full `mix test`
spends about 45 s in one file after another, and the wall time is the sum. Yet
the two slowest files — the deploy tests — are almost idle while they run (25 s
of wall clock, 5 s of CPU): they wait on a real `mix test` and on `git` in each
throwaway live tree. The same is true of the restart tests, which sleep through
their backoff. A partitioned run turns that sum into the slowest partition, on
machines that have spare cores, without weakening a single test.

## Requirements

- **SUITE-1** A test run's shared state is per run: the scratch workspace, the
  settings database, the endpoint port and the temp directory tests name their
  own paths in come from `ELIA_TEST_WORKSPACE`, `ELIA_TEST_SETTINGS`,
  `ELIA_TEST_PORT` and `TMPDIR`, each falling back to the current single-run
  default when unset, so two runs on one machine don't collide. `TMPDIR` is part
  of it because a test's temp path is named with `System.unique_integer/1`,
  which is unique inside one BEAM node only: two partitions sharing a temp
  directory can pick the same live tree.

- **SUITE-2** `bin/test` runs the suite as concurrent partitions: one OS process
  per partition, started together, each with its own shared state (SUITE-1), so
  the wall time is the slowest partition rather than the sum. Compilation
  happens once, before the fan-out, and each partition runs with compilation
  skipped, so concurrent runs never compile the same build at the same time.

- **SUITE-3** The partitions are a split of the test files: every
  `test/**/*_test.exs` file belongs to exactly one partition, files known to be
  slow are spread across the partitions (by a weight that says how slow), and
  the plan is deterministic — the same files give the same split on every run.
  A file nobody weighted, such as a new one, is still assigned. The number of
  partitions is 4, and `ELIA_TEST_PARTITIONS` overrides it.

- **SUITE-4** `bin/test --plan` prints the split — the partitions, the files in
  each and the command it would run — and starts nothing.

- **SUITE-5** `bin/test` exits 0 only when every partition passed. A partition
  that fails makes the exit status non-zero and its output is shown (SUITE-7),
  and the other partitions still run to the end.

- **SUITE-6** Arguments make it a single run: `bin/test <files or flags>` runs
  one plain `mix test` with those arguments and no partitions, so a file, a
  `--failed` or a `--only` run behaves exactly as it does today.

- **SUITE-7** A partitioned run prints, for each partition, whether it passed
  and its ExUnit summary line, then the total wall time. A passing partition's
  full output is not printed.

- **SUITE-8** `mix precommit` runs its test step through `bin/test`, so the gate
  is partitioned too. `mix test` on its own is unchanged: single process, one
  compile, which is what `run_tests` and a path or tag argument use.

## Configuration

| Env var | Meaning | Default |
| --- | --- | --- |
| `ELIA_TEST_PARTITIONS` | How many partitions `bin/test` starts | `4` |
| `ELIA_TEST_WORKSPACE` | Scratch workspace root of one run | `<tmp>/elia-test-workspace` |
| `ELIA_TEST_SETTINGS` | Settings database file of one run | `<tmp>/elia-test-settings/settings.dets` |
| `ELIA_TEST_PORT` | Endpoint port of one run | `4002` |
| `TMPDIR` | Where a run derives its own temp paths | the system temp dir |
| `ELIA_TEST_CMD` | Command a partition runs, for the script's own tests | `mix test` |

A partition's state lives under `<tmp>/elia-test-p<n>/`, which each partition's
`test_helper.exs` clears as it starts (it already does for the single run).

## Tests

- `test/elia/test_script_test.exs` covers SUITE-3, SUITE-4 and SUITE-5 with
  `--plan` and with `ELIA_TEST_CMD` standing in for `mix test`.
- SUITE-1 is covered where the paths are read: a test asserts the env var
  overrides win and the defaults apply when it is unset.
- SUITE-6, SUITE-7 and SUITE-8 are covered by running `bin/test` on a one-file
  argument and reading what it prints (SUITE-6, SUITE-7), and by asserting the
  `precommit` alias (SUITE-8).

## Implementation

- `bin/test` — the runner (POSIX `sh`, like `bin/serve`).
- `config/test.exs` — the env-overridable paths and port (SUITE-1).
- `mix.exs` — the `precommit` alias's test step (SUITE-8).
- `docs/agents/testing.md` — how to run the suite, and why.
