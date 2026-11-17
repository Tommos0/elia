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
  settings database and the temp directory tests name their own paths in live
  under a run directory that belongs to that run alone, so two runs on one
  machine cannot collide on them — in one worktree or in several, jailed or not.
  `ELIA_TEST_WORKSPACE` and `ELIA_TEST_SETTINGS` still override the workspace and
  the settings database, and `ELIA_TEST_PORT` still moves the endpoint port
  (default `4002`), where each of the first two falls back to the run's own path
  when unset. `TMPDIR` is part of the state because a test's temp path is named
  with `System.unique_integer/1`, which is unique inside one BEAM node only: two
  runs sharing a temp directory can pick the same path — and a run's boot removes
  its own scratch workspace (`test/test_helper.exs`), so a shared one is not
  merely dirty but deleted under a test that is still running.

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
  compile, which is what a path or tag argument to `mix test` gets, and what the
  deploy's own suite run is (VERIFY-1).

- **SUITE-9** A test's scripted provider (`Elia.FakeLLM`) serves only the chats
  of the test that started it: a model call from a chat whose session was
  already running when that provider started is refused with an error that ends
  that turn (not a transient one, RETRY-1) and takes no scripted turn out of the
  queue. A session that outlived the test that scripted its provider therefore
  cannot take a turn another test scripted, which is how a test saw a tool call
  it scripted come back as the reply after it instead of an approval request.

- **SUITE-10** A test that runs the boot scan (RESUME-6) runs it against a
  scratch store of its own, so it resumes only the chats that test saved: a chat
  another test left behind in the shared scratch store gets no session and stays
  interrupted. Without that, the scan is the one place in the suite that starts
  sessions for chats it did not save — and a session it starts for another
  test's chat outlives that test and posts into the fake provider.

- **SUITE-11** `bin/test` makes one run directory for the run it starts — one
  nothing can predict, `mktemp -d` — and puts each partition's workspace, settings
  database and temp directory under it (SUITE-1). It removes that whole directory
  when the run ends: after the partitions, on a partition that failed and on a
  signal, so a partitioned run leaves nothing behind.

- **SUITE-12** A run that is not `bin/test` — a plain `mix test`, the deploy's own
  suite run, a preview — gets a run directory of its own by derivation rather than
  from a fixed path, named for the node and the moment it started, so two of them
  on one machine differ even where both see the same pid (a command runs in its
  own pid namespace, ISOL-9). The run names its directory in the environment
  (`ELIA_TEST_RUN`), so a node handed that environment resolves the same one; a
  name that is blank or absent is a run that derives one of its own. A run that
  starts a suite of its own clears that name for it — the harness's suite run
  does (VERIFY-1) — so a nested run is never the run it was started from.
  `bin/test` names each partition's directory this way (SUITE-11).

- **SUITE-13** A run directory a run left behind — one that was killed rather than
  exited, and so could not clean up after itself — is removed by a later run on
  that machine once it is older than a day, and never while it is fresh. A run
  prunes as it starts, so leftovers cannot accumulate.

## Configuration

| Env var | Meaning | Default |
| --- | --- | --- |
| `ELIA_TEST_PARTITIONS` | How many partitions `bin/test` starts | `4` |
| `ELIA_TEST_RUN` | The run directory this run's nodes share | derived per run: `<tmp>/elia-test-<run>` |
| `ELIA_TEST_WORKSPACE` | Scratch workspace root of one run | `<run>/workspace` |
| `ELIA_TEST_SETTINGS` | Settings database file of one run | `<run>/settings/settings.dets` |
| `ELIA_TEST_PORT` | Endpoint port of one run | `4002` |
| `TMPDIR` | Where a test's own temp paths go | `<run>/tmp` |
| `ELIA_TEST_CMD` | Command a partition runs, for the script's own tests | `mix test` |

A partitioned run's state lives under the directory `bin/test` makes for it, each
partition's under its own subdirectory of that, and a single run's under the one it
derives for itself, which each run's `test_helper.exs` clears as it starts (as the
single run already does). `bin/test --plan` prints the run's directory once and a
partition's paths under it, so the plan reads the same for the same files on
another run (SUITE-3, SUITE-4). A run the harness starts itself — the deploy's
suite run — is a `mix test` of its own whatever the jail does: it is a run
directory of its own either way (VERIFY-1, ISOL-14).

## Tests

- `test/elia/test_script_test.exs` (SUITE-2, SUITE-3, SUITE-4, SUITE-5,
  SUITE-11) covers the plan with `--plan` and a fake `ELIA_TEST_CMD` standing in
  for `mix test`, and the run directory the script makes and removes with the
  partitions' state under it — after a partition failed too. SUITE-3's
  determinism is asserted by comparing two `--plan` runs byte for byte, so a path
  that differs between runs is the run's own line and not part of a partition's
  state.
- `test/elia/test_script_test.exs` (SUITE-1, SUITE-12, SUITE-13) is where the
  run's own paths are read: the overrides win and the derived defaults apply when
  unset, two runs derive different directories, `ELIA_TEST_RUN` names the
  directory a node the run starts inherits, and an old run directory is pruned as
  a run starts while a fresh one is left alone.
- SUITE-6, SUITE-7 and SUITE-8 are covered by running `bin/test` on a one-file
  argument and reading what it prints (SUITE-6, SUITE-7), and by asserting the
  `precommit` alias (SUITE-8).
- `test/elia/fake_llm_test.exs` covers SUITE-9: a session started before the
  test's provider is refused, and the turn the test scripted is still there for
  the chat the test started.
- `test/elia/auto_resume_test.exs` covers SUITE-10: a chat saved in the shared
  scratch store is not resumed by the test that runs the scan.

## Implementation

- `bin/test` — the runner (POSIX `sh`, like `bin/serve`): the run directory it
  makes, its partitions' state under it, and its removal (SUITE-11).
- `config/test.exs` — the derived paths and the env overrides (SUITE-1, SUITE-12).
- `test/test_helper.exs`, and a helper beside it under `test/support/` so the
  pruning is testable — the run directory a single run reads, the scratch
  workspace it clears and the old directories a run prunes as it starts
  (SUITE-12, SUITE-13).
- `mix.exs` — the `precommit` alias's test step (SUITE-8).
- `test/support/fake_llm.ex` — which chats the scripted provider serves
  (SUITE-9).
- `test/elia/auto_resume_test.exs` — the store the scan runs against (SUITE-10).
- `docs/agents/testing.md` and `AGENTS.md` — how to run the suite, and why: the
  "never run two test runs at once" rule went with the shared paths it guarded,
  and what is left is the port a browser run binds (SUITE-1).
