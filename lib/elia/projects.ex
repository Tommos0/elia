defmodule Elia.Projects do
  @moduledoc """
  The registry of project folders Elia works in (PROJ-1 - PROJ-8).

  A project can also be made from its name alone: that creates a folder of its
  own under the projects root and leaves it a git repository with one commit
  (PROJ-32 - PROJ-38).

  A project is a named folder on disk; every chat belongs to one. Elia's own
  project (id `harness`, folder `Elia.Workspace.root/0`) is never stored: it is
  synthesised on every read and always listed first. The others live as one
  Erlang term in `.elia/projects.term`, written atomically like a session
  (STORE-2) and read so a missing, unreadable or corrupt file reads as "no
  projects" rather than an error.
  """

  alias Elia.Net.Allowlist
  alias Elia.{Agent, Settings, Workspace}

  @version 1
  @harness_id "harness"
  @default_key :default_project
  @projects_root_key :projects_root
  @default_root "~/elia-projects"
  @color_key :harness_project_color
  @allowlist_key :harness_project_allowlist

  # PROJ-42: the colours a project can be. A project stores a name; the hex is
  # what the interface paints, and each one is dark enough to take white text.
  @palette [
    %{name: "indigo", hex: "#4f46e5"},
    %{name: "sky", hex: "#0369a1"},
    %{name: "teal", hex: "#0f766e"},
    %{name: "emerald", hex: "#047857"},
    %{name: "amber", hex: "#b45309"},
    %{name: "orange", hex: "#c2410c"},
    %{name: "rose", hex: "#e11d48"},
    %{name: "violet", hex: "#7c3aed"}
  ]

  @type t :: %{
          id: binary(),
          name: binary(),
          folder: binary(),
          color: binary() | nil,
          allowlist: [binary()],
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
  DEPLOY-3). Its chats work in that folder, and one that changes code makes
  itself a worktree inside it (DEPLOY-1, DEPLOY-28).
  """
  @spec harness() :: t()
  def harness do
    %{
      id: @harness_id,
      name: "Elia",
      folder: Workspace.runtime_root(),
      color: stored_color_name(Settings.get(@color_key)),
      allowlist: harness_allowlist(),
      harness?: true
    }
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
        project = new_project(name, folder)
        save([project | read()])
        {:ok, project}
    end
  end

  @doc "The colours a project can be: a name, and the hex it is painted in (PROJ-42)."
  @spec palette() :: [%{name: binary(), hex: binary()}]
  def palette, do: @palette

  @doc """
  A project's colour (PROJ-43): the palette entry its `color` names, else the one
  its name derives (PROJ-42, `auto_color/1`). Every project has one, Elia's own
  included.
  """
  @spec color(map()) :: %{name: binary(), hex: binary()}
  def color(project), do: find_color(Map.get(project, :color)) || auto_color(project)

  @doc """
  The palette entry a project's name derives (PROJ-43): the same name always
  gives the same one, so a project keeps its colour across a restart and one whose
  stored colour the palette no longer holds still has one.
  """
  @spec auto_color(map()) :: %{name: binary(), hex: binary()}
  def auto_color(project) do
    name = String.downcase(Map.get(project, :name) || "")
    Enum.at(@palette, :erlang.phash2(name, length(@palette)))
  end

  @doc """
  Stores a palette colour on a project and returns it as `{:ok, project}`
  (PROJ-44); `nil` clears it, so the project goes back to the colour its name
  derives (PROJ-43). A name the palette does not hold is
  `{:error, :unknown_color}` and stores nothing.
  """
  @spec set_color(map(), binary() | nil) :: {:ok, map()} | {:error, :unknown_color}
  def set_color(%{id: @harness_id}, color) do
    with {:ok, name} <- palette_name(color) do
      store_harness_color(name)
      {:ok, harness()}
    end
  end

  def set_color(project, color) do
    with {:ok, name} <- palette_name(color) do
      save(Enum.map(read(), &put_color(&1, project.id, name)))
      {:ok, Map.put(project, :color, name)}
    end
  end

  @doc """
  A project's allowlist of hosts (PROJ-49, NET-28): the entries its chats in
  allowlist mode may reach, cleaned (NET-7). A project that names none has an
  empty list, which reaches nothing (NET-10).
  """
  @spec allowlist(t() | binary()) :: [binary()]
  def allowlist(%{id: id}), do: allowlist(id)

  def allowlist(id) when is_binary(id) do
    case get(id) do
      %{allowlist: entries} -> Allowlist.clean(entries)
      _none -> []
    end
  end

  def allowlist(_other), do: []

  @doc """
  Stores a project's allowlist (PROJ-49, NET-28) and returns it as
  `{:ok, project}`; a list holding an entry that is not one of NET-7's forms is
  `{:error, entry}` and stores nothing (NET-11). Elia's own project takes one
  like any other.
  """
  @spec set_allowlist(t(), term()) :: {:ok, t()} | {:error, binary()}
  def set_allowlist(%{id: @harness_id}, entries) do
    with {:ok, hosts} <- Allowlist.parse(entries) do
      store_harness_allowlist(hosts)
      {:ok, Map.put(harness(), :allowlist, hosts)}
    end
  end

  def set_allowlist(%{id: id} = project, entries) do
    with {:ok, hosts} <- Allowlist.parse(entries) do
      save(Enum.map(read(), &put_allowlist(&1, id, hosts)))
      {:ok, Map.put(project, :allowlist, hosts)}
    end
  end

  @doc """
  Adds entries to a project's allowlist (NET-33, PROJ-49): each one the list
  does not hold yet goes to its end, so an entry it already holds leaves it as
  it is. A list holding an entry that is not one of NET-7's forms is
  `{:error, entry}` and stores nothing.
  """
  @spec add_allowlist(t() | binary(), term()) :: {:ok, t()} | {:error, binary()}
  def add_allowlist(project, entries) do
    with {:ok, hosts} <- Allowlist.parse(entries) do
      set_allowlist(project, Enum.uniq(allowlist(project) ++ hosts))
    end
  end

  @doc """
  PROJ-32, PROJ-33: the projects root — the folder `create/1` makes a project's
  own folder in. It is `Elia.Settings`' `:projects_root`, so it survives a
  restart and is never committed, and `~/elia-projects` when none is stored.
  """
  @spec root() :: binary()
  def root do
    case Settings.get(@projects_root_key) do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _none -> Path.expand(@default_root)
    end
  end

  @doc """
  PROJ-33: stores the projects root, trimmed and expanded, so `~` and a relative
  path resolve to a folder. A blank value is `{:error, :blank_root}` and leaves
  the stored root alone.
  """
  @spec set_root(binary()) :: :ok | {:error, :blank_root}
  def set_root(folder) do
    case trimmed(folder) do
      "" ->
        {:error, :blank_root}

      value ->
        Settings.put(@projects_root_key, Path.expand(value))
        :ok
    end
  end

  @doc """
  PROJ-34: the folder `create/1` makes for a project's name — the name
  lowercased, every run of characters that are neither letters nor digits
  replaced by `-`, and leading and trailing `-` removed — under the projects
  root. A name that leaves no folder is `nil`.
  """
  @spec folder_for(binary()) :: binary() | nil
  def folder_for(name) when is_binary(name) do
    case slug(name) do
      nil -> nil
      slug -> Path.join(root(), slug)
    end
  end

  def folder_for(_name), do: nil

  @doc """
  SERVE-7: the slug a project's name gives, which is the folder PROJ-34 derives
  for it — the name lowercased, every run of characters that are neither letters
  nor digits replaced by `-`, and leading and trailing `-` removed — without the
  projects root. `nil` for a name that leaves none.
  """
  @spec slug(binary()) :: binary() | nil
  def slug(name) when is_binary(name) do
    slug =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
      |> String.trim("-")

    if slug == "", do: nil, else: slug
  end

  def slug(_name), do: nil

  @doc """
  PROJ-34 - PROJ-38: makes a project from its name alone, in a folder of its own
  under the projects root (`folder_for/1`). The folder is created with its
  parents, and is left a git repository with one commit: a `README.md` naming the
  project and an `AGENTS.md` for the chats that will work there, each written
  when the folder has no such file, committed together as the initial commit.

  A folder that is already there and holds anything is
  `{:error, :folder_exists}` — creation never writes into a folder that is not
  the one it makes — a folder that couldn't be made is `{:error, :folder_failed}`,
  and neither saves a project (PROJ-6). Whatever stops the folder becoming that
  repository — no git, git refusing to initialize or to commit, a file that can't
  be written — does not fail the creation: the folder, what it holds and the
  project are still made, and it is returned as `{:ok, project, :no_repository}`.
  """
  @spec create(binary()) ::
          {:ok, t()}
          | {:ok, t(), :no_repository}
          | {:error, :blank_name | :folder_exists | :folder_failed}
  def create(name) do
    case folder_for(name) do
      nil ->
        {:error, :blank_name}

      folder ->
        with :ok <- make_folder(folder) do
          project = new_project(name, folder)
          save([project | read()])

          case setup_repository(folder, project.name) do
            :ok -> {:ok, project}
            {:error, _reason} -> {:ok, project, :no_repository}
          end
        end
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
      %{id: id} -> store_default(id)
    end
  end

  @doc """
  PROJ-31, STORE-52: the `where:` a listing takes to hold one project's chats —
  the listed chats whose `project_id` is that project's, with a chat that has
  none and one whose id names no project counted with Elia's own (PROJ-9).
  """
  @spec chats_of(t()) :: (map() -> boolean())
  def chats_of(project) do
    ids = Enum.map(list(), & &1.id)

    fn chat -> chat_project_id(chat, ids) == project.id end
  end

  @doc """
  PROJ-9, PROJ-31: the id of the project a listed chat belongs to — its own
  `project_id` while the registry still holds it, else Elia's own, which is
  where a chat with none and one whose project has been deleted (PROJ-7) both
  belong. `ids` is the ids of `list/0`, so a caller that holds the projects
  resolves a page of chats without reading the registry again.
  """
  @spec chat_project_id(map(), [binary()]) :: binary()
  def chat_project_id(chat, ids) do
    case Map.get(chat, :project_id) do
      id when is_binary(id) -> if id in ids, do: id, else: @harness_id
      _none -> @harness_id
    end
  end

  # PROJ-28: the open project is written through whenever a chat page opens, so
  # a value the settings already hold is left as it is rather than written again.
  defp store_default(id) do
    if Settings.get(@default_key) == id, do: :ok, else: Settings.put(@default_key, id)
  end

  @doc """
  Whether a tool context belongs to Elia's own project: the only project the
  deploy workflow applies to, and the one whose folder is the live tree the
  server runs from (PROJ-14, DEPLOY-1).
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

  defp trimmed(folder) when is_binary(folder), do: String.trim(folder)
  defp trimmed(_folder), do: ""

  defp new_project(name, folder) do
    %{
      id: Agent.new_id(),
      name: String.trim(name),
      folder: Path.expand(folder),
      # PROJ-1, PROJ-42: a new project stores no colour, so it wears the one its
      # name derives.
      color: nil,
      # PROJ-1, PROJ-49: and no hosts, so its chats reach nothing until one is
      # allowed (NET-10).
      allowlist: [],
      harness?: false
    }
  end

  # PROJ-35: the folder, with its parents, so a projects root that is not there
  # yet is made as well. A folder that is there and holds anything is not one to
  # write into; one that is there and holds nothing is used, so a creation whose
  # folder was left behind by a failed attempt can be repeated.
  defp make_folder(folder) do
    case File.ls(folder) do
      {:ok, []} ->
        :ok

      {:ok, _entries} ->
        {:error, :folder_exists}

      {:error, _reason} ->
        if File.mkdir_p(folder) == :ok, do: :ok, else: {:error, :folder_failed}
    end
  end

  # PROJ-36, PROJ-38: the repository with its one commit, or whatever stopped it.
  defp setup_repository(folder, name) do
    with :ok <- ensure_file(Path.join(folder, "README.md"), readme(name)),
         :ok <- ensure_file(Path.join(folder, "AGENTS.md"), agents(name)),
         :ok <- ensure_repository(folder) do
      commit(folder)
    end
  end

  defp ensure_repository(folder) do
    if File.dir?(Path.join(folder, ".git")), do: :ok, else: git(folder, ["init", "-q"])
  end

  defp commit(folder) do
    with :ok <- git(folder, ["add", "-A"]) do
      git(folder, ["commit", "-m", "Initial commit"], identity(folder))
    end
  end

  # PROJ-37: git's own identity where the machine has one, and one derived from
  # the machine's user where it has none, so the initial commit is never refused
  # for want of an identity.
  defp identity(folder) do
    case git_output(folder, ["config", "user.email"]) do
      "" ->
        user = System.get_env("USER") || System.get_env("LOGNAME") || "user"
        name = String.capitalize(user)

        [
          {"GIT_AUTHOR_NAME", name},
          {"GIT_AUTHOR_EMAIL", "#{user}@#{hostname()}"},
          {"GIT_COMMITTER_NAME", name},
          {"GIT_COMMITTER_EMAIL", "#{user}@#{hostname()}"}
        ]

      _email ->
        []
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, host} -> List.to_string(host)
      _error -> "localhost"
    end
  end

  # PROJ-36: written only when the folder has no such file.
  defp ensure_file(path, contents) do
    case File.write(path, contents, [:exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp readme(name), do: "# #{name}\n\nA project Elia works in.\n"

  defp agents(name) do
    """
    # #{name}

    Instructions for the chats that work in this project: what it is, how to
    build, test and run it, and anything a chat here should always or never do.
    Every chat in this project is given this file, on top of Elia's own
    instructions (PROJ-15).
    """
  end

  # git, run in the new folder. No git at all, and a git that fails, are both an
  # error the creation turns into `:no_repository` (PROJ-38).
  defp git(folder, args, env \\ []) do
    case System.find_executable("git") do
      nil ->
        {:error, :no_git}

      executable ->
        case System.cmd(executable, args, cd: folder, env: env, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, _status} -> {:error, output}
        end
    end
  end

  defp git_output(folder, args) do
    case System.find_executable("git") do
      nil ->
        ""

      executable ->
        case System.cmd(executable, args, cd: folder, stderr_to_stdout: true) do
          {output, 0} -> String.trim(output)
          _other -> ""
        end
    end
  end

  # Only projects other than Elia's own are stored (PROJ-2): the ones read here.
  defp read do
    with {:ok, data} <- File.read(path()),
         %{projects: projects} <- decode(data),
         true <- is_list(projects) do
      projects
      |> Enum.filter(&valid?/1)
      |> Enum.map(&normalise/1)
    else
      _ -> []
    end
  end

  defp valid?(%{id: id, name: name, folder: folder} = project)
       when is_binary(id) and is_binary(name) and is_binary(folder) do
    id != @harness_id and Map.get(project, :harness?, false) == false
  end

  defp valid?(_project), do: false

  # A project read from the file takes its colour as the palette holds it: one
  # written before the field existed, and one naming a colour the palette no
  # longer holds, both read as `nil` — the colour the name derives (PROJ-2,
  # PROJ-43).
  defp normalise(project) do
    project
    |> Map.put(:harness?, false)
    |> Map.update(:color, nil, &stored_color_name/1)
    |> Map.update(:allowlist, [], &Allowlist.clean/1)
  end

  defp put_allowlist(stored, id, hosts) do
    if stored.id == id, do: Map.put(stored, :allowlist, hosts), else: stored
  end

  defp put_color(stored, id, name) do
    if stored.id == id, do: Map.put(stored, :color, name), else: stored
  end

  # A palette name, or `nil` for anything the palette does not hold.
  defp stored_color_name(name) do
    case find_color(name) do
      %{name: name} -> name
      _unknown -> nil
    end
  end

  defp palette_name(nil), do: {:ok, nil}

  defp palette_name(name) when is_binary(name) do
    case find_color(name) do
      %{name: name} -> {:ok, name}
      _unknown -> {:error, :unknown_color}
    end
  end

  defp palette_name(_other), do: {:error, :unknown_color}

  defp find_color(name) when is_binary(name), do: Enum.find(@palette, &(&1.name == name))
  defp find_color(_none), do: nil

  # Elia's own project is never stored in the registry (PROJ-3), so its colour
  # lives in the settings database, where the default project is kept too
  # (PROJ-8).
  defp store_harness_color(nil), do: Settings.delete(@color_key)
  defp store_harness_color(name), do: Settings.put(@color_key, name)

  # PROJ-49: like the colour above, Elia's own allowlist lives in the settings
  # database, where the registry file cannot hold it (PROJ-3).
  defp harness_allowlist, do: Allowlist.clean(Settings.get(@allowlist_key))
  defp store_harness_allowlist(hosts), do: Settings.put(@allowlist_key, hosts)

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
