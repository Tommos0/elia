defmodule Elia.ServeScriptTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @serve Path.expand("../../bin/serve", __DIR__)

  # Writes an executable fake server and returns its path.
  # The script sees the (quoted) test directory as "$d": tmp_dir names contain
  # characters that are special to the shell.
  defp fake!(dir, body) do
    dir = Path.expand(dir)
    path = Path.join(dir, "fake.sh")
    File.write!(path, "#!/bin/sh\nd='#{dir}'\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp serve(cmd, env \\ []) do
    env = [{"ELIA_SERVE_CMD", cmd}, {"ELIA_SERVE_MAX_DELAY", "0"} | env]
    # `timeout` stops a loop that never ends (it sends SIGTERM, RESTART-3).
    System.cmd("timeout", ["20", "sh", @serve], env: env, stderr_to_stdout: true)
  end

  defp runs(dir), do: dir |> Path.join("runs") |> File.read!() |> String.split("\n", trim: true)

  # Fails `failures` times, then exits 0.
  defp flaky!(dir, failures) do
    fake!(dir, """
    echo run >> "$d/runs"
    [ "$(wc -l < "$d/runs")" -gt #{failures} ] && exit 0
    exit 1
    """)
  end

  test "restarts after non-zero exits and stops on exit 0 (RESTART-1, RESTART-2, RESTART-5)",
       %{tmp_dir: dir} do
    {out, 0} = serve(flaky!(dir, 2))

    assert length(runs(dir)) == 3
    assert out =~ "[serve] starting:"
    assert out =~ "exited with status 1"
    assert out =~ "exited cleanly, not restarting"
  end

  test "restarts after the server is killed by a signal (RESTART-1)", %{tmp_dir: dir} do
    cmd =
      fake!(dir, """
      echo run >> "$d/runs"
      [ "$(wc -l < "$d/runs")" -gt 1 ] && exit 0
      kill -9 $$
      """)

    {out, 0} = serve(cmd)

    assert length(runs(dir)) == 2
    assert out =~ "exited with status 137"
  end

  test "stops without restarting on SIGTERM (RESTART-3)", %{tmp_dir: dir} do
    cmd = fake!(dir, "echo run >> \"$d/runs\"\nexec sleep 30\n")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :exit_status,
        :stderr_to_stdout,
        :binary,
        args: [@serve],
        env: [{~c"ELIA_SERVE_CMD", String.to_charlist(cmd)}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    # Wait until the server has really started.
    wait_for_runs(dir, 1)
    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])

    assert_receive {^port, {:exit_status, 0}}, 5_000
    assert length(runs(dir)) == 1
  end

  test "quick failures back off, doubling up to the maximum (RESTART-4)", %{tmp_dir: dir} do
    {out, 0} =
      serve(flaky!(dir, 3), [{"ELIA_SERVE_MIN_UPTIME", "60"}, {"ELIA_SERVE_MAX_DELAY", "2"}])

    delays = Regex.scan(~r/restarting in (\d+)s/, out) |> Enum.map(&List.last/1)
    assert delays == ["1", "2", "2"]
  end

  test "a run longer than the minimum uptime restarts immediately (RESTART-4)", %{tmp_dir: dir} do
    {out, 0} =
      serve(flaky!(dir, 2), [{"ELIA_SERVE_MIN_UPTIME", "0"}, {"ELIA_SERVE_MAX_DELAY", "30"}])

    delays = Regex.scan(~r/restarting in (\d+)s/, out) |> Enum.map(&List.last/1)
    assert delays == ["0", "0"]
  end

  test "turns off the crash dump (RESTART-6)", %{tmp_dir: dir} do
    cmd = fake!(dir, "echo \"$ERL_CRASH_DUMP_SECONDS\" > \"$d/dump\"\n")

    {_, 0} = serve(cmd)

    assert File.read!(Path.join(dir, "dump")) == "0\n"
  end

  test "the application is permanent outside of tests (RESTART-7)" do
    # `mix test` runs in the :test environment, where it isn't.
    assert Mix.Project.config()[:start_permanent] == false

    mix = File.read!(Path.expand("../../mix.exs", __DIR__))
    assert mix =~ "start_permanent: Mix.env() != :test"
  end

  defp wait_for_runs(dir, n, tries \\ 100) do
    cond do
      File.exists?(Path.join(dir, "runs")) and length(runs(dir)) >= n -> :ok
      tries == 0 -> flunk("server never started")
      true -> Process.sleep(50) && wait_for_runs(dir, n, tries - 1)
    end
  end
end
