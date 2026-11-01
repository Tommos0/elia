defmodule Elia.Skills do
  @moduledoc """
  Registry of the skills available to the agent: built-in modules from config
  plus folder skills under a workspace's `skills/` dir, reloadable at runtime.

      config :elia, Elia.Skills, builtin: [Elia.Skills.Shell, ...]

  A chat's skills depend on its project (PROJ-17 - PROJ-21): `for_project/1`
  combines the built-ins, Elia's own folder skills and the project's, and
  `resolve/2` resolves a session's `skills` option against that.
  """

  use GenServer

  require Logger

  alias Elia.Skills.Folder

  @topic "skills"
  @project_file "AGENTS.md"
  @project_max_bytes 32_000
  @self_modification "self-modification"

  @base_prompt """
  You are Elia, an assistant running inside a local harness. You can use the \
  tools provided by your enabled skills. Be concise, and tell the user what you \
  did and what you found.
  """

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Currently loaded skills."
  @spec current() :: [Elia.Skill.t()]
  def current, do: GenServer.call(__MODULE__, :current)

  @doc "Rescans the skills folder. Returns the loaded skills and per-folder errors."
  @spec reload() :: %{skills: [Elia.Skill.t()], errors: [{binary(), binary()}]}
  def reload, do: GenServer.call(__MODULE__, :reload)

  def errors, do: GenServer.call(__MODULE__, :errors)

  def builtin, do: Application.get_env(:elia, __MODULE__, [])[:builtin] || [Elia.Skills.Shell]

  def tools(skills \\ current()), do: Enum.flat_map(skills, & &1.tools)

  @doc """
  Turns a session's `skills` option into a skill list for its project: a list
  as is, a function of no arguments called, `nil` meaning the project's skills
  (SKILL-14, PROJ-21). `nil` as the project means Elia's own.
  """
  @spec resolve([Elia.Skill.t()] | (-> [Elia.Skill.t()]) | nil, Elia.Projects.t() | nil) ::
          [Elia.Skill.t()]
  def resolve(skills, project \\ nil)

  def resolve(nil, project) do
    {skills, _errors} = for_project(project)
    skills
  end

  def resolve(fun, _project) when is_function(fun, 0), do: fun.()
  def resolve(skills, _project) when is_list(skills), do: skills

  @doc """
  The skills available in `project`, with the load errors (PROJ-17 - PROJ-21):
  the built-in skills, then the folder skills of Elia's `skills/` dir and those
  of the project's own `skills/` dir, in that order. `nil` means Elia's own
  project.

  The `self-modification` skill is left out unless the project is Elia's own
  (PROJ-17), and the project's folder is skipped when it *is* Elia's own root,
  so Elia's skills are not loaded twice (PROJ-18). A project's folder skills
  follow FOLDER-1 - FOLDER-9 like Elia's; a folder that fails to load is logged
  and returned as `{relative_folder, reason}` while the rest still load
  (PROJ-19). Everything is read again on every call, so a skill written into the
  project applies from the next model step without `reload_skills` (PROJ-20).
  """
  @spec for_project(Elia.Projects.t() | nil) :: {[Elia.Skill.t()], [{binary(), binary()}]}
  def for_project(project \\ nil) do
    project = project || Elia.Projects.harness()

    {skills, errors} = load_folder_skills(builtin_skills(project), Elia.Workspace.root())

    if Path.expand(project.folder) == Elia.Workspace.root() do
      {skills, errors}
    else
      {project_skills, project_errors} = load_folder_skills(skills, project.folder)
      {project_skills, errors ++ project_errors}
    end
  end

  @doc """
  The system prompt's pieces, in order, each as `{kind, text}`: the agent
  instructions (`:base`), the project instructions when there are any
  (`:project`), then one `{:skill, skill}` section per skill. The texts carry
  their leading separator and concatenate to `system_prompt/2`, so the context
  indicator can size each one.
  """
  @spec system_sections([Elia.Skill.t()], binary() | nil) :: [{term(), binary()}]
  def system_sections(skills \\ current(), project \\ project_instructions()) do
    project_section =
      if project,
        do: [{:project, "\n\n## Project instructions (#{@project_file})\n" <> project}],
        else: []

    [{:base, String.trim(@base_prompt)}] ++
      project_section ++ Enum.map(skills, &{{:skill, &1}, "\n\n" <> skill_section(&1)})
  end

  def system_prompt(skills \\ current(), project \\ project_instructions()) do
    skills |> system_sections(project) |> Enum.map_join(&elem(&1, 1))
  end

  @doc """
  The contents of `AGENTS.md` in the workspace root, trimmed and capped at
  #{@project_max_bytes} bytes, or `nil` when it is missing, unreadable or blank.
  Read on every call, so edits apply from the next request.
  """
  @spec project_instructions(Path.t()) :: binary() | nil
  def project_instructions(root \\ Elia.Workspace.root()) do
    case File.read(Path.join(root, @project_file)) do
      {:ok, text} ->
        case String.trim(text) do
          "" -> nil
          text -> cap_project(text)
        end

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        Logger.warning("Could not read #{@project_file}: #{:file.format_error(reason)}")
        nil
    end
  end

  defp cap_project(text) when byte_size(text) <= @project_max_bytes, do: text

  defp cap_project(text) do
    Logger.warning(
      "#{@project_file} is #{byte_size(text)} bytes; truncated to #{@project_max_bytes}"
    )

    cut = binary_part(text, 0, @project_max_bytes)

    valid =
      case :unicode.characters_to_binary(cut) do
        bin when is_binary(bin) -> bin
        {_, valid, _} -> valid
      end

    valid <> "\n\n[#{@project_file} truncated: it exceeds #{@project_max_bytes} bytes]"
  end

  defp skill_section(skill) do
    "## Skill: #{skill.name}\n#{skill.description}\n\n#{String.trim(skill.instructions)}"
  end

  @doc "Subscribes to `{:skills_reloaded, skills}` broadcasts."
  def subscribe, do: Phoenix.PubSub.subscribe(Elia.PubSub, @topic)

  ## Server

  @impl true
  def init(nil), do: {:ok, load()}

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.skills, state}
  def handle_call(:errors, _from, state), do: {:reply, state.errors, state}

  def handle_call(:reload, _from, _state) do
    state = load()
    Phoenix.PubSub.broadcast(Elia.PubSub, @topic, {:skills_reloaded, state.skills})
    {:reply, state, state}
  end

  defp load do
    {skills, errors} =
      load_folder_skills(builtin_skills(Elia.Projects.harness()), Elia.Workspace.root())

    %{skills: skills, errors: errors}
  end

  # The built-in skills, without `self-modification` unless `project` is Elia's
  # own (PROJ-17).
  defp builtin_skills(project) do
    skills = Enum.map(builtin(), &Elia.Skill.from_module/1)

    if harness_project?(project),
      do: skills,
      else: Enum.reject(skills, &(&1.name == @self_modification))
  end

  defp harness_project?(project) do
    Map.get(project, :harness?, false) or Map.get(project, :id) == "harness"
  end

  # Appends the folder skills under `root` to `skills`, applying FOLDER-1 -
  # FOLDER-9 as `Elia.Skills.Folder` does. A folder that fails to load, or whose
  # skill or tool name is taken, is left out: the failure is logged and returned
  # as `{folder, reason}`, with the folder relative to `root`, while the other
  # skills still load (SKILL-3, SKILL-4, PROJ-19).
  defp load_folder_skills(skills, root) do
    dir = Elia.Workspace.skills_dir(root)

    folders =
      case File.ls(dir) do
        {:ok, names} ->
          for name <- Enum.sort(names), File.dir?(Path.join(dir, name)), do: Path.join(dir, name)

        {:error, _} ->
          []
      end

    {skills, errors} =
      Enum.reduce(folders, {skills, []}, fn folder, {skills, errors} ->
        with {:ok, skill} <- Folder.load(folder, root),
             :ok <- check_conflicts(skill, skills) do
          {skills ++ [skill], errors}
        else
          {:error, reason} ->
            {skills, errors ++ [{Elia.Workspace.relative(folder, root), reason}]}
        end
      end)

    for {folder, reason} <- errors, do: Logger.warning("Skill #{folder} not loaded: #{reason}")
    {skills, errors}
  end

  defp check_conflicts(skill, skills) do
    taken = MapSet.new(tools(skills), & &1.name)

    cond do
      Enum.any?(skills, &(&1.name == skill.name)) ->
        {:error, "a skill named #{skill.name} already exists"}

      clash = Enum.find(skill.tools, &MapSet.member?(taken, &1.name)) ->
        {:error, "tool #{clash.name} is already defined by another skill"}

      true ->
        :ok
    end
  end
end
