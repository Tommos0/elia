defmodule Elia.TestScriptTest do
  use ExUnit.Case, async: true

  # specs/test-suite.md (SUITE): `bin/test` runs the suite in concurrent
  # partitions. The plan is checked as it is printed, and the run itself with a
  # fake command in place of `mix test`, so this file never runs the suite
  # inside the suite.
  @script Path.expand("../../bin/test", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "elia-test-script-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A stand-in for `mix test`: each partition runs it with its own
  # ELIA_TEST_* env, so it can tell the partitions apart.
  defp fake!(dir, body) do
    path = Path.join(dir, "fake-mix-test.sh")
    # The directory is quoted for the shell: tmp names can hold specials.
    File.write!(path, "#!/bin/sh\nd='#{dir}'\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp run(args, env \\ []) do
    # A partitioned run sets these for its partitions, so a test of the script
    # would otherwise inherit them; start from none and test the defaults.
    clean = for var <- ["ELIA_TEST_PARTITIONS", "ELIA_TEST_CMD"], do: {var, nil}
    System.cmd("sh", [@script | args], env: clean ++ env, stderr_to_stdout: true)
  end

  defp blocks(out) do
    out
    |> String.split("partition ")
    |> Enum.drop(1)
    |> Enum.map(fn block ->
      [header | _] = String.split(block, "\n", parts: 2)

      %{
        number: header |> String.split(" ") |> hd(),
        files:
          block
          |> String.split("\n")
          |> Enum.find_value([], fn line ->
            case String.split(line, "  files: ", parts: 2) do
              ["", files] -> String.split(files, " ", trim: true)
              _ -> nil
            end
          end),
        env:
          block
          |> String.split("\n")
          |> Enum.find_value([], fn line ->
            case String.split(line, "  env: ", parts: 2) do
              ["", env] ->
                Map.new(
                  String.split(env, " ", trim: true),
                  &List.to_tuple(String.split(&1, "=", parts: 2))
                )

              _ ->
                nil
            end
          end)
      }
    end)
  end

  defp ran(marker) do
    case File.read(marker) do
      {:ok, lines} -> String.split(lines, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  # SUITE-3, SUITE-4: every test file lands in exactly one partition, the slow
  # ones are spread out, and the plan is the same on every run.
  test "the plan splits every test file across the partitions, deterministically" do
    {out, 0} = run(["--plan"])

    partitions = blocks(out)
    assert length(partitions) == 4
    assert Enum.map(partitions, & &1.number) == ["1", "2", "3", "4"]

    planned = Enum.flat_map(partitions, & &1.files)
    files = Path.wildcard("test/**/*_test.exs")

    assert Enum.sort(planned) == Enum.sort(files)
    assert length(planned) == length(Enum.uniq(planned))

    # The two slowest files lead a partition each, never the same one.
    partition_of = fn file ->
      Enum.find_value(partitions, fn p -> file in p.files && p.number end)
    end

    deploy = partition_of.("test/elia/deployment_test.exs")
    settings = partition_of.("test/elia_web/live/settings_live_test.exs")
    assert deploy
    assert settings
    refute deploy == settings

    {again, 0} = run(["--plan"])
    assert again == out
  end

  # SUITE-3: the count is configurable.
  test "ELIA_TEST_PARTITIONS sets how many partitions the plan has" do
    {out, 0} = run(["--plan"], [{"ELIA_TEST_PARTITIONS", "2"}])

    assert length(blocks(out)) == 2
  end

  # SUITE-1, SUITE-2: each partition gets its own scratch state, so concurrent
  # runs can't collide on a workspace, a settings database, a port or the temp
  # directory their own paths are named in.
  test "each partition has its own workspace, settings database and port" do
    {out, 0} = run(["--plan"])

    envs = Enum.map(blocks(out), & &1.env)

    for key <- ["TMPDIR", "ELIA_TEST_WORKSPACE", "ELIA_TEST_SETTINGS", "ELIA_TEST_PORT"] do
      values = Enum.map(envs, &Map.fetch!(&1, key))
      assert length(Enum.uniq(values)) == length(values)
    end
  end

  # SUITE-2, SUITE-7: the partitions all run, and each one's summary and the
  # total are reported.
  test "the partitions run together and their summaries are reported", %{dir: dir} do
    marker = Path.join(dir, "ran")
    fake = fake!(dir, "echo \"$ELIA_TEST_PORT\" >> '#{marker}'\necho '7 tests, 0 failures'\n")

    {out, 0} =
      run([], [
        {"ELIA_TEST_CMD", fake},
        {"ELIA_TEST_PARTITIONS", "3"},
        {"ELIA_TEST_MARKER", marker}
      ])

    assert length(ran(marker)) == 3
    assert out =~ "partition 1: passed in"
    assert out =~ "7 tests, 0 failures"
    assert out =~ "total: "
  end

  # SUITE-5: a failing partition fails the run and shows its output, and the
  # other partitions still run to the end.
  test "a failing partition fails the run, and the others still run", %{dir: dir} do
    marker = Path.join(dir, "ran")

    fake =
      fake!(dir, """
      echo "$ELIA_TEST_PORT" >> '#{marker}'
      [ "$ELIA_TEST_PORT" = "4003" ] && { echo 'boom: partition 2 broke'; echo '2 tests, 1 failure'; exit 1; }
      echo '2 tests, 0 failures'
      exit 0
      """)

    {out, status} =
      run([], [
        {"ELIA_TEST_CMD", fake},
        {"ELIA_TEST_PARTITIONS", "3"},
        {"ELIA_TEST_MARKER", marker}
      ])

    assert status == 1
    assert length(ran(marker)) == 3
    assert out =~ "partition 2: FAILED"
    assert out =~ "boom: partition 2 broke"
    assert out =~ "partition 1: passed"
    assert out =~ "partition 3: passed"
  end

  # SUITE-4: given arguments it would be a single run, and the plan says so.
  test "arguments mean one plain run" do
    {out, 0} = run(["--plan", "test/elia/shell_test.exs", "--failed"])

    assert out =~ "single run: mix test test/elia/shell_test.exs --failed"
    refute out =~ "partition 1"
  end

  # SUITE-6: arguments reach that one run unchanged.
  test "arguments are passed straight to the single run", %{dir: dir} do
    fake = fake!(dir, "echo \"args: $*\"\n")

    {out, 0} = run(["test/elia/shell_test.exs", "--failed"], [{"ELIA_TEST_CMD", fake}])

    assert out =~ "args: test/elia/shell_test.exs --failed"
    refute out =~ "partition 1"
  end

  # SUITE-8: the gate is partitioned too.
  test "mix precommit runs its test step through bin/test" do
    assert "cmd bin/test" in Mix.Project.config()[:aliases][:precommit]
  end

  # SUITE-1: the config reads a run's scratch state from the environment,
  # falling back to the single-run default.
  test "the test env takes its scratch state from ELIA_TEST_*" do
    tmp = System.tmp_dir!()

    assert Application.fetch_env!(:elia, :workspace) ==
             System.get_env("ELIA_TEST_WORKSPACE") || Path.join(tmp, "elia-test-workspace")

    assert Elia.Settings.path() ==
             System.get_env("ELIA_TEST_SETTINGS") ||
             Path.join([tmp, "elia-test-settings", "settings.dets"])

    port = Application.fetch_env!(:elia, EliaWeb.Endpoint)[:http][:port]
    assert port == String.to_integer(System.get_env("ELIA_TEST_PORT") || "4002")
  end
end
