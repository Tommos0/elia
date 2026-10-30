defmodule Elia.Guarded do
  @moduledoc """
  Files that enforce the harness's guardrails, and a gate that keeps changes to
  them out of the running app until they go through `Elia.Harness.hot_reload/1`.

  In development Phoenix recompiles the whole project on each request. It can't
  skip individual files, so `reload/2` (used as the endpoint's code reloader)
  skips automatic reloading entirely while any guarded file differs from what
  was last loaded: at boot, or by a successful `hot_reload`. Once the guarded
  files match again (after `hot_reload` or a rollback), automatic reloading
  resumes.
  """

  require Logger

  alias Elia.Workspace

  @patterns ~w(
    lib/elia/harness.ex
    lib/elia/checkpoint.ex
    lib/elia/workspace.ex
    lib/elia/guarded.ex
    lib/elia/tool.ex
    lib/elia/shell.ex
    lib/elia/skills.ex
    lib/elia/application.ex
    lib/elia/agent/loop.ex
    lib/elia/skills/*.ex
    lib/elia_web/endpoint.ex
    lib/elia_web/recovery.ex
    config/**
    mix.exs
    mix.lock
    test/elia/self_modification_test.exs
    test/elia/guarded_test.exs
  )

  @loaded {__MODULE__, :loaded}
  @warned {__MODULE__, :warned}

  @doc "The guarded path patterns, relative to the workspace root."
  def patterns, do: @patterns

  @doc "Whether `path` (absolute or relative to the workspace root) is guarded."
  @spec guarded?(binary()) :: boolean()
  def guarded?(path) do
    {abs, class} = Workspace.resolve(path)
    rel = Workspace.relative(abs)
    class == :core and Enum.any?(@patterns, &Regex.match?(glob_regex(&1), rel))
  end

  defp glob_regex(pattern) do
    source =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.compile!("^" <> source <> "$")
  end

  @doc "Guarded files that currently exist, relative to the workspace root."
  @spec files() :: [binary()]
  def files do
    root = Workspace.root()

    @patterns
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1), match_dot: true))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Workspace.relative/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp fingerprint do
    root = Workspace.root()

    Map.new(files(), fn rel ->
      hash =
        case File.read(Path.join(root, rel)) do
          {:ok, data} -> :crypto.hash(:sha256, data)
          {:error, _} -> nil
        end

      {rel, hash}
    end)
  end

  @doc "Records the guarded files' current contents as loaded into the running app."
  @spec mark_loaded() :: :ok
  def mark_loaded do
    :persistent_term.put(@loaded, fingerprint())
    :persistent_term.put(@warned, [])
    :ok
  end

  @doc "Guarded files added, removed or changed since they were last loaded."
  @spec changed() :: [binary()]
  def changed do
    loaded = :persistent_term.get(@loaded, nil) || %{}
    current = fingerprint()

    (Map.keys(loaded) ++ Map.keys(current))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(loaded, &1) != Map.get(current, &1)))
    |> Enum.sort()
  end

  @doc """
  Code reloader for the endpoint (`plug Phoenix.CodeReloader, reloader: ...`).
  Delegates to `Phoenix.CodeReloader.reload/2` (or `opts[:delegate]`) unless
  guarded files have pending changes, in which case nothing is reloaded.
  """
  def reload(endpoint, opts \\ []) do
    case changed() do
      [] ->
        delegate = Keyword.get(opts, :delegate, &Phoenix.CodeReloader.reload/2)
        delegate.(endpoint, Keyword.delete(opts, :delegate))

      pending ->
        warn_once(pending)
        :ok
    end
  end

  defp warn_once(pending) do
    if :persistent_term.get(@warned, []) != pending do
      :persistent_term.put(@warned, pending)

      Logger.warning(
        "Automatic code reloading is paused: guarded files changed " <>
          "(#{Enum.join(pending, ", ")}). Use hot_reload or roll back to resume."
      )
    end
  end
end
