defmodule Elia.Harness do
  @moduledoc """
  Running the test suite in a chat's workspace. Loading code into the running
  app is a deploy, and lives in `Elia.Deploy`; a turn is not verified and
  nothing is rolled back (see `specs/verification.md`).

  A run has two clocks (VERIFY-8, VERIFY-9): the per-test timeout handed to
  `mix test` as `--timeout`, and the run's own, which stops a suite that would
  otherwise hold the turn. Both are settings, and both are bounded, so a call
  asks for one rather than running into it:

      config :elia, Elia.Harness,
        timeout: 600,              # seconds, the whole run
        max_timeout: 1_800,        # seconds, the most a call may ask for
        test_timeout: 60_000,      # ms, `mix test --timeout`, per test
        max_test_timeout: 600_000  # ms, the most a call may ask for
  """

  alias Elia.Workspace

  @test_flags ~w(--failed --stale --trace)
  @test_options ~w(--seed --max-failures --only --exclude)

  @timeout_defaults [
    timeout: 600,
    max_timeout: 1_800,
    test_timeout: 60_000,
    max_test_timeout: 600_000
  ]

  @doc """
  One of the timeouts a test run uses (VERIFY-8, VERIFY-9), from the settings
  with the defaults above.
  """
  @spec timeout_config(atom()) :: pos_integer()
  def timeout_config(key) do
    Keyword.merge(@timeout_defaults, Application.get_env(:elia, __MODULE__, []))[key]
  end

  @doc """
  Runs `mix test` in `root` (Elia's own root by default). `args` may be test
  paths under `test/` (optionally `path:line`) and a few safe flags; anything
  else is rejected so the tool cannot run arbitrary code. `opts[:jail]` is the
  chat's jail setting (ISOL-15): `false` runs the suite unjailed, and without a
  chat the default is on (ISOL-14).

  `opts[:timeout_seconds]` is the run's own timeout and `opts[:test_timeout_ms]`
  the per-test one (VERIFY-8, VERIFY-9); nil or absent takes the configured
  default, and a value above the configured maximum is clamped to it.
  """
  @spec run_tests([binary()], Path.t(), keyword()) :: {:ok, binary()} | {:error, binary()}
  def run_tests(args \\ [], root \\ Workspace.root(), opts \\ []) do
    with :ok <- check_test_args(args),
         {:ok, seconds, asked} <- check_run_timeout(opts[:timeout_seconds]),
         {:ok, per_test_ms} <- check_test_timeout(opts[:test_timeout_ms]) do
      # VERIFY-8: `mix test`'s own per-test timeout, so a test that sets none of
      # its own cannot hold the run.
      command =
        Enum.map_join(
          ["mix", "test", "--timeout", to_string(per_test_ms) | args],
          " ",
          &shell_quote/1
        )

      timeout = :timer.seconds(seconds)

      run =
        Elia.Shell.run(command,
          cd: root,
          env: [{"MIX_ENV", "test"}],
          timeout: timeout,
          jail: opts[:jail]
        )

      result = Elia.Skills.Shell.result(run, timeout, asked: asked)

      # VERIFY-10: a run stopped by its own timeout says so and names the lever,
      # so a suite killed for being long is not read as a suite that failed.
      case {run, result} do
        {{:timeout, _output}, {:error, output}} ->
          {:error, output <> "\n" <> timeout_note(seconds)}

        _ ->
          result
      end
    end
  end

  defp check_run_timeout(given) do
    case Elia.Shell.resolve_timeout(
           given,
           timeout_config(:timeout),
           timeout_config(:max_timeout)
         ) do
      {:ok, seconds, asked} ->
        {:ok, seconds, asked}

      {:error, :invalid} ->
        {:error, timeout_error("timeout_seconds", given, :timeout, :max_timeout)}
    end
  end

  defp check_test_timeout(given) do
    case Elia.Shell.resolve_timeout(
           given,
           timeout_config(:test_timeout),
           timeout_config(:max_test_timeout)
         ) do
      {:ok, ms, _asked} ->
        {:ok, ms}

      {:error, :invalid} ->
        {:error, timeout_error("test_timeout_ms", given, :test_timeout, :max_test_timeout)}
    end
  end

  defp timeout_error(name, given, default_key, max_key) do
    "#{name} must be a whole number of at least 1 (got #{inspect(given)}); " <>
      "the default is #{timeout_config(default_key)} and the most is #{timeout_config(max_key)}."
  end

  defp timeout_note(seconds) do
    "The run was stopped by its timeout (#{seconds}s): ask for longer with " <>
      "`timeout_seconds`, up to #{timeout_config(:max_timeout)}s, or give one test less " <>
      "time with `test_timeout_ms`."
  end

  defp check_test_args([]), do: :ok
  defp check_test_args([flag | rest]) when flag in @test_flags, do: check_test_args(rest)

  defp check_test_args([option, value | rest]) when option in @test_options do
    if Regex.match?(~r/^[\w:.-]+$/, value),
      do: check_test_args(rest),
      else: {:error, "Invalid value for #{option}: #{value}"}
  end

  defp check_test_args([path | rest]) do
    file = path |> String.split(":") |> hd()

    if String.starts_with?(file, "test/") and not String.contains?(file, "..") and
         Regex.match?(~r/^[\w\/.-]+(:\d+)?$/, path),
       do: check_test_args(rest),
       else: {:error, "Unsupported test argument: #{path}"}
  end

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"
end
