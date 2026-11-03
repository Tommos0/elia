defmodule Elia.Projects do
  @moduledoc """
  The registry of project folders Elia works in (PROJ-1 - PROJ-8).

  A project is a named folder on disk; every chat belongs to one. Elia's own
  project (id `harness`, folder `Elia.Workspace.root/0`) is never stored: it is
  synthesised on every read and always listed first. The others live as one
  Erlang term in `.elia/projects.term`, written atomically like a session
  (STORE-2) and read so a missing, unreadable or corrupt file reads as "no
  projects" rather than an error.
  """

  alias Elia.{Agent, Settings, Workspace}

  @version 1
  @harness_id "harness"
  @default_key :default_project

  @type t :: %{
          id: binary(),
          name: binary(),
          folder: binary(),
          harness?: boolean()
        }

  @doc "The registry file, in Elia's data dir (PROJ-2, PROJ-13)."
  def path, do: Path.join(Workspace.data_dir(), "projects.term")

  @doc "Every project, Elia's own first, then the others by name (PROJ-3, PROJ-4)."
  @spec list() :: [t()]
  def list do
    others =
      read()
      |> Enum.sort_by(fn project -> {String.downcase(project.name), project.id} end)

    [harness() | others]
  end

  @doc """
  Elia's own project: id `harness`, folder `Elia.Workspace.runtime_root/0` — the
  live tree, where the server runs and where Elia's data lives (PROJ-3,
  DEPLOY-3). Each of its chats works in its own worktree (DEPLOY-1).
  """
  @spec harness() :: t()
  def harness do
    %{id: @harness_id, name: "Elia", folder: Workspace.runtime_root(), harness?: true}
  end

  @doc "The project with `id`, or `nil` (PROJ-5)."
  @spec get(binary()) :: t() | nil
  def get(@harness_id), do: harness()
  def get(id), do: Enum.find(read(), &(&1.id == id))

  @doc """
  Creates a project from a name and folder (PROJ-6). A blank name is
  `{:error, :blank_name}` and a folder that isn't an existing directory is
  `{:error, :not_a_directory}`; otherwise the project is saved and returned.
  """
  @spec create(binary(), binary()) :: {:ok, t()} | {:error, :blank_name | :not_a_directory}
  def create(name, folder) do
    cond do
      blank?(name) ->
        {:error, :blank_name}

      not File.dir?(folder) ->
        {:error, :not_a_directory}

      true ->
        project = %{
          id: Agent.new_id(),
          name: String.trim(name),
          folder: Path.expand(folder),
          harness?: false
        }

        save([project | read()])
        {:ok, project}
    end
  end

  @doc """
  Removes a project and returns `:ok` (PROJ-7). Elia's own project can't be
  deleted (`{:error, :harness_project}`); an unknown id is `:ok`. A project's
  chats are never deleted with it.
  """
  @spec delete(binary()) :: :ok | {:error, :harness_project}
  def delete(@harness_id), do: {:error, :harness_project}

  def delete(id) do
    save(Enum.reject(read(), &(&1.id == id)))
    :ok
  end

  @doc """
  The project a new chat starts in (PROJ-8): the one `set_default/1` last
  stored, else Elia's own project.
  """
  @spec default() :: t()
  def default do
    case get(Settings.get(@default_key)) do
      nil -> harness()
      project -> project
    end
  end

  @doc "Stores the default project; an unknown id leaves it alone (PROJ-8)."
  @spec set_default(binary()) :: :ok
  def set_default(id) do
    case get(id) do
      nil -> :ok
      %{id: id} -> Settings.put(@default_key, id)
    end
  end

  @doc """
  Whether a tool context belongs to Elia's own project. Its workspaces are the
  only ones a chat works in as its own worktree, and the only ones the deploy
  workflow applies to (PROJ-14, DEPLOY-1).
  """
  @spec harness_ctx?(map()) :: boolean()
  def harness_ctx?(ctx) do
    case ctx[:project] do
      %{harness?: harness?} -> harness?
      # A context with no project: skills called directly (a test) work in
      # Elia's own root, as before.
      _ -> ctx[:workspace] == nil or Path.expand(ctx[:workspace]) == Workspace.root()
    end
  end

  defp blank?(name), do: not is_binary(name) or String.trim(name) == ""

  # Only projects other than Elia's own are stored (PROJ-2): the ones read here.
  defp read do
    with {:ok, data} <- File.read(path()),
         %{projects: projects} <- decode(data),
         true <- is_list(projects) do
      projects
      |> Enum.filter(&valid?/1)
      |> Enum.map(&Map.put(&1, :harness?, false))
    else
      _ -> []
    end
  end

  defp valid?(%{id: id, name: name, folder: folder} = project)
       when is_binary(id) and is_binary(name) and is_binary(folder) do
    id != @harness_id and Map.get(project, :harness?, false) == false
  end

  defp valid?(_project), do: false

  defp save(projects) do
    File.mkdir_p!(Workspace.data_dir())
    path = path()
    tmp = path <> ".tmp"
    data = :erlang.term_to_binary(%{version: @version, projects: projects})
    with :ok <- File.write(tmp, data), do: File.rename(tmp, path)
  end

  # Like a session (STORE-3): `:safe` refuses atoms that don't exist yet, and a
  # corrupt file must never raise (PROJ-2).
  defp decode(data) do
    :erlang.binary_to_term(data, [:safe])
  rescue
    ArgumentError -> nil
  end
end
