defmodule Elia.Shell do
  @moduledoc "Runs OS commands with a timeout, empty stdin and combined output."

  @type result :: {:ok, binary(), non_neg_integer()} | {:timeout, binary()}

  @doc """
  Runs `command` with `sh -c`.

  Options: `:cd` (default `Elia.Workspace.root/0`), `:env` (list of string
  pairs), `:timeout` in milliseconds (default 60s).
  """
  @spec run(binary(), keyword()) :: result()
  def run(command, opts \\ []) do
    # Commands must not wait on stdin.
    script = "exec </dev/null\n" <> command

    {exe, args} =
      case System.find_executable("setsid") do
        # Own process group, so a timeout can kill the whole pipeline.
        nil -> {System.find_executable("sh"), ["-c", script]}
        setsid -> {setsid, ["--wait", "sh", "-c", script]}
      end

    env = for {k, v} <- Keyword.get(opts, :env, []), do: {to_charlist(k), to_charlist(v)}

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        cd: Keyword.get_lazy(opts, :cd, &Elia.Workspace.root/0),
        env: env
      ])

    timeout = Keyword.get(opts, :timeout, :timer.seconds(60))
    collect(port, [], System.monotonic_time(:millisecond) + timeout)
  end

  defp collect(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, [acc | data], deadline)
      {^port, {:exit_status, status}} -> {:ok, IO.iodata_to_binary(acc), status}
    after
      remaining ->
        kill(port)
        {:timeout, IO.iodata_to_binary(acc)}
    end
  end

  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid) do
      System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    end
  end

  @doc "Shortens `output` to `max` characters by cutting out the middle."
  def truncate(output, max) do
    length = String.length(output)

    if length > max do
      half = div(max, 2)

      String.slice(output, 0, half) <>
        "\n... [#{length - max} characters truncated] ...\n" <>
        String.slice(output, -half, half)
    else
      output
    end
  end
end
