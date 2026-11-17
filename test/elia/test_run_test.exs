defmodule Elia.TestRunTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # specs/test-suite.md (SUITE-1, SUITE-12, SUITE-13): every run's state lives under
  # a run directory that belongs to that run alone, and the directories a killed
  # run left behind are cleared away by a later one.

  # SUITE-1, SUITE-12: this run's workspace, settings database and temp directory
  # are all under the one directory it names for itself, as the environment says.
  test "this run's paths are under the run directory it names" do
    run = Elia.TestRun.dir()

    assert System.get_env("ELIA_TEST_RUN") == run
    assert Application.fetch_env!(:elia, :test_run) == run
    assert Application.fetch_env!(:elia, :workspace) == Path.join(run, "workspace")
    assert Elia.Settings.path() == Path.join([run, "settings", "settings.dets"])
    assert System.get_env("TMPDIR") == Elia.TestRun.tmp_dir()
    assert Elia.TestRun.tmp_dir() == Path.join(run, "tmp")
  end

  # SUITE-12: a run that is not `bin/test` derives a directory of its own rather
  # than taking one it was handed, so two runs on one machine never meet — and a
  # run whose name is blank or cleared still gets one.
  test "another run derives a run directory of its own" do
    elsewhere = run_elsewhere([{"ELIA_TEST_RUN", ""}])

    assert elsewhere =~ ~r|/elia-test-run-\d+-\d+$|
    refute elsewhere == Elia.TestRun.dir()
  end

  # SUITE-12: a suite a run starts is a run of its own. The harness clears the
  # caller's run directory for it, because a command gets the environment its
  # caller inherited *on top of* the variables it was given (`Elia.Shell`): a
  # suite run would otherwise resolve the caller's directory and clear its
  # scratch workspace as it boots, under the tests still running in it.
  test "the harness does not hand its own run directory to the suite it starts",
       %{tmp_dir: dir} do
    previous = Application.get_env(:elia, Elia.Shell)
    # A jail the suite doesn't turn off (ISOL-12) and a bubblewrap that only says
    # what it was told to run, so the environment can be read without a jail.
    Application.put_env(:elia, Elia.Shell, jail: true, bwrap: fake_bwrap(dir))
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    assert {:ok, output} =
             Elia.Harness.run_tests([], File.cwd!(), jail: true, timeout_seconds: 30)

    # The suite is told it is in a run — in the test env — and told nothing about
    # which run directory that is, so it derives one of its own.
    assert output =~ "MIX_ENV=test\n"
    assert output =~ "ELIA_TEST_RUN=\n"
    refute output =~ "ELIA_TEST_RUN=#{Elia.TestRun.dir()}"
  end

  # SUITE-13: a run directory a killed run left behind is removed by a later run,
  # while one that is fresh is left alone — as is anything that is not a run
  # directory.
  test "a run clears away the directories killed runs left behind", %{tmp_dir: dir} do
    base = Path.join(dir, "base")
    old = Path.join(base, "elia-test-run-1-1")
    fresh = Path.join(base, "elia-test-run-2-2")
    other = Path.join(base, "elia-test-workspace")
    for path <- [old, fresh, other], do: File.mkdir_p!(path)
    File.touch!(old, {{2020, 1, 1}, {0, 0, 0}})

    Elia.TestRun.prune(base, 60)

    refute File.exists?(old), "a run directory no run can still be using is not left behind"
    assert File.exists?(fresh), "a run that is going on keeps its own directory"
    assert File.exists?(other), "only a run directory is a later run's to remove"
  end

  # A second run on this machine, asked what run directory it resolved. `mix run`
  # is a node of its own: it reads the test env's config (SUITE-1, SUITE-12).
  defp run_elsewhere(env) do
    {out, 0} =
      System.cmd(
        "mix",
        ["run", "--no-start", "-e", ~s|IO.puts(System.get_env("ELIA_TEST_RUN"))|],
        env: [{"MIX_ENV", "test"} | env],
        stderr_to_stdout: true
      )

    out |> String.split("\n", trim: true) |> List.last()
  end

  # Stands in for bubblewrap, so the environment a run gives its command — one
  # `VAR=value` per line (ISOL-8) — can be read without a jail.
  defp fake_bwrap(dir) do
    path = Path.join(dir, "fake-bwrap")

    File.write!(path, """
    #!/bin/sh
    while [ $# -gt 0 ]; do
      case "$1" in
        --setenv) printf '%s=%s\\n' "$2" "$3"; shift 3 ;;
        *) shift ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
    path
  end
end
