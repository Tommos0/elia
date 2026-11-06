defmodule Elia.Priority do
  @moduledoc """
  The scheduling priority Elia gives the processes it spawns (PRIO).

  A compile or a test suite contends with the server for the same CPU and the
  same disk, and the server is what draws the UI, runs the agent loops and
  streams the model's answer. Every process `Elia.Shell.run/2` starts is
  therefore started *below* the server's own priority: through `nice` for the
  CPU (PRIO-1) and `ionice` for the disk (PRIO-4). Each sets the value on
  itself and then `exec`s the command, so the process Elia started stays the
  one the port reports and the whole tree it starts inherits the priority
  (PRIO-3).

      config :elia, Elia.Priority, nice: 10, ionice: 6

  Only the children are lowered: a positive `nice` and I/O class 2 or 3 are
  what an unprivileged process may set for itself, so nothing here needs
  privileges and the server's own priority is never touched (PRIO-6).
  `nice: 0` or `nil` and `ionice: nil` turn either half off, and a host without
  one of the two programs gets the other half only.

  `nice` takes an *adjustment*, and adds it to the priority the process would
  otherwise inherit (PRIO-1). That is deliberate: lowering a priority always
  succeeds, where asking for an absolute one could be asking to raise it, which
  needs privileges. So a command that a command starts is lower still, down to
  19; `nice: 0` adds nothing and leaves a command at the priority of whoever
  asked for it.
  """

  # PRIO-5: the defaults live here as well as in `config/config.exs`, so a
  # configuration that names only one of the two still gets the other.
  @defaults [nice: 10, ionice: 6]

  # `nice` takes 1..19, where 19 is the most, and 0 is what a process has
  # anyway (PRIO-6).
  @max_nice 19

  @doc """
  The effective settings for one call (PRIO-5): `:nice` is the number `nice`
  takes, or `nil` when the command runs at the server's own CPU priority, and
  `:ionice` is a best-effort level (0..7), `:idle`, or `nil`.
  """
  @spec settings(keyword()) :: keyword()
  def settings(opts \\ []) do
    # `List.wrap/1` so a caller that passes `priority: nil` (a value it may
    # have taken from elsewhere) gets the configuration rather than a crash.
    merged = @defaults |> Keyword.merge(config()) |> Keyword.merge(List.wrap(opts))

    [nice: nice_value(merged[:nice]), ionice: ionice_value(merged[:ionice])]
  end

  @doc """
  The argv Elia puts in front of a command (PRIO-2, PRIO-7): `nice` and then
  `ionice`, where they are installed. Empty when both halves are off or
  neither program is installed.
  """
  @spec prefix(keyword()) :: [binary()]
  def prefix(opts \\ []) do
    settings = settings(opts)

    nice_args(settings[:nice]) ++ ionice_args(settings[:ionice])
  end

  @doc """
  What to hand `Port.open/2` for `program` and `args`: the priority as a prefix
  on the executable (PRIO-7), or the program itself when there is no prefix.
  """
  @spec spawn_argv(binary(), [binary()], keyword()) :: {binary(), [binary()]}
  def spawn_argv(program, args, opts \\ []) do
    case prefix(opts) do
      [] -> {program, args}
      [exe | prefix_args] -> {exe, prefix_args ++ [program | args]}
    end
  end

  ## The two halves

  # PRIO-1, PRIO-6: only a positive value is ever set — raising a process above
  # the server would need CAP_SYS_NICE — and 0 is the priority a process has
  # unless something lowers it, so neither goes into the argv.
  defp nice_value(value) when is_integer(value) and value > 0, do: min(value, @max_nice)
  defp nice_value(_value), do: nil

  defp nice_args(nil), do: []

  # PRIO-1: `-n` is an *adjustment*, which `nice` adds to the priority the
  # command would otherwise inherit — so this only ever lowers one, and cannot
  # fail the way asking for an absolute value could.
  defp nice_args(value),
    do: with_program("nice", fn exe -> [exe, "-n", Integer.to_string(value)] end)

  # PRIO-4: `ionice -t` ignores a priority the host refuses — an I/O scheduler
  # without priorities, a namespace that forbids one — and runs the command
  # anyway, where plain `ionice` would exit without it. Class 1 is realtime and
  # needs privileges, so only best-effort and idle are used (PRIO-6).
  defp ionice_value(:idle), do: :idle
  defp ionice_value(value) when is_integer(value) and value in 0..7, do: value
  defp ionice_value(_value), do: nil

  defp ionice_args(nil), do: []
  defp ionice_args(:idle), do: with_program("ionice", &[&1, "-t", "-c3"])

  defp ionice_args(level),
    do: with_program("ionice", &[&1, "-t", "-c2", "-n", Integer.to_string(level)])

  # PRIO-6: a host without the program runs the command as it did before,
  # rather than failing it.
  defp with_program(name, build) do
    case System.find_executable(name) do
      nil -> []
      exe -> build.(exe)
    end
  end

  defp config, do: Application.get_env(:elia, __MODULE__, [])
end
