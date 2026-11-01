defmodule Elia.Harness do
  @moduledoc """
  Guardrails for self-modification: running the test suite, verifying a
  turn's changes, rolling back, and hot-reloading code in development.
  """

  alias Elia.{Checkpoint, Workspace}

  @elixir_exts ~w(.ex .exs .heex)
  @test_flags ~w(--failed --stale --trace)
  @test_options ~w(--seed --max-failures --only --exclude)

  @doc """
  Runs `mix test` in `root` (Elia's own root by default). `args` may be test
  paths under `test/` (optionally `path:line`) and a few safe flags; anything
  else is rejected so the tool cannot run arbitrary code.
  """
  @spec run_tests([binary()], Path.t()) :: {:ok, binary()} | {:error, binary()}
  def run_tests(args \\ [], root \\ Workspace.root()) do
    with :ok <- check_test_args(args) do
      command = Enum.map_join(["mix", "test" | args], " ", &shell_quote/1)
      timeout = :timer.minutes(10)

      Elia.Skills.Shell.result(
        Elia.Shell.run(command, cd: root, env: [{"MIX_ENV", "test"}], timeout: timeout),
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

  @doc """
  Checks the changes made since `turn_id`'s checkpoint. If any Elixir file
  outside `skills/` changed, runs the test suite; on failure rolls the
  workspace back to the checkpoint.

  `root` is the turn's workspace: a chat in Elia's own project works in its own
  worktree, so its checkpoints and tests are taken there (DEPLOY-1).
  """
  @spec verify(term(), binary()) ::
          :ok | :unchanged | {:rolled_back, binary()} | {:error, binary()}
  def verify(turn_id, root \\ Workspace.root()) do
    with sha when is_binary(sha) <- Checkpoint.for_turn(turn_id),
         {:ok, files} <- Checkpoint.changed_files(sha, root),
         [_ | _] <- Enum.filter(files, &core_elixir?(&1, root)) do
      case run_tests([], root) do
        {:ok, _output} ->
          :ok

        {:error, output} ->
          case Checkpoint.rollback(sha, root) do
            {:ok, _undo} ->
              Elia.Skills.reload()
              {:rolled_back, output}

            {:error, reason} ->
              {:error, "Tests failed and the rollback also failed: #{reason}\n\n#{output}"}
          end
      end
    else
      nil -> :unchanged
      [] -> :unchanged
      {:error, reason} -> {:error, "Could not check changes: #{reason}"}
    end
  end

  @doc """
  Whether `turn_id` took a checkpoint and has changed core Elixir files since,
  the condition under which `verify/2` runs the tests (VERIFY-7). Changes
  nothing.
  """
  @spec core_elixir_changed?(term(), binary()) :: boolean() | {:error, binary()}
  def core_elixir_changed?(turn_id, root \\ Workspace.root()) do
    with sha when is_binary(sha) <- Checkpoint.for_turn(turn_id),
         {:ok, files} <- Checkpoint.changed_files(sha, root) do
      Enum.any?(files, &core_elixir?(&1, root))
    else
      nil -> false
      {:error, reason} -> {:error, "Could not check changes: #{reason}"}
    end
  end

  defp core_elixir?(path, root) do
    Path.extname(path) in @elixir_exts and Workspace.classify(path, root) == :core
  end

  @doc "Whether in-VM code reloading is available (dev server with code reloader)."
  def hot_reload_available? do
    Code.ensure_loaded?(Mix) and
      Application.get_env(:elia, EliaWeb.Endpoint)[:code_reloader] == true
  end

  @doc """
  The soft deploy mode (DEPLOY-6): runs the full test suite in the chat's
  workspace — its own worktree (DEPLOY-1) — merges its branch into `live`
  (DEPLOY-5), then recompiles and loads the live tree into the running app,
  keeping running state. `workspace` is the chat's workspace root.
  """
  @spec hot_reload(term(), binary()) :: {:ok, binary()} | {:error, binary()}
  def hot_reload(turn_id, workspace \\ Workspace.root()) do
    cond do
      not hot_reload_available?() ->
        {:error, "Hot reload is only available when running the dev server (mix phx.server)."}

      true ->
        case Elia.Deploy.deploy(workspace) do
          {:ok, merged} ->
            load(merged)

          {:tests_failed, output} ->
            {:error, tests_failed(turn_id, workspace, output)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # HOT-5: recompile the live tree and load the changed modules.
  defp load(merged) do
    case Phoenix.CodeReloader.reload(EliaWeb.Endpoint) do
      :ok ->
        Elia.Skills.reload()
        {:ok, "Tests passed; #{merged} Recompiled and reloaded the running app."}

      {:error, output} ->
        {:error, "Compilation failed:\n" <> Elia.Shell.truncate(output, 20_000)}
    end
  end

  # HOT-4: nothing was merged or loaded; roll the turn's workspace back.
  defp tests_failed(turn_id, workspace, output) do
    rolled_back =
      with sha when is_binary(sha) <- Checkpoint.for_turn(turn_id),
           {:ok, _} <- Checkpoint.rollback(sha, workspace) do
        Elia.Skills.reload()
        " The workspace was rolled back to the checkpoint taken at the start of this turn."
      else
        _ -> ""
      end

    "Tests failed; nothing was merged or loaded.#{rolled_back}\n\n#{output}"
  end
end
