defmodule Elia.Harness do
  @moduledoc """
  Running the test suite in a chat's workspace. Loading code into the running
  app is a deploy, and lives in `Elia.Deploy`; a turn is not verified and
  nothing is rolled back (see `specs/verification.md`).
  """

  alias Elia.Workspace

  @test_flags ~w(--failed --stale --trace)
  @test_options ~w(--seed --max-failures --only --exclude)

  @doc """
  Runs `mix test` in `root` (Elia's own root by default). `args` may be test
  paths under `test/` (optionally `path:line`) and a few safe flags; anything
  else is rejected so the tool cannot run arbitrary code. `opts[:jail]` is the
  chat's jail setting (ISOL-15): `false` runs the suite unjailed, and without a
  chat the default is on (ISOL-14).
  """
  @spec run_tests([binary()], Path.t(), keyword()) :: {:ok, binary()} | {:error, binary()}
  def run_tests(args \\ [], root \\ Workspace.root(), opts \\ []) do
    with :ok <- check_test_args(args) do
      command = Enum.map_join(["mix", "test" | args], " ", &shell_quote/1)
      timeout = :timer.minutes(10)

      Elia.Skills.Shell.result(
        Elia.Shell.run(command,
          cd: root,
          env: [{"MIX_ENV", "test"}],
          timeout: timeout,
          jail: opts[:jail]
        ),
        timeout
      )
    end
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
