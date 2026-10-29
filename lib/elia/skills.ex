defmodule Elia.Skills do
  @moduledoc """
  Registry of the skills available to the agent: built-in modules from config
  plus folder skills under `Elia.Workspace.skills_dir/0`, reloadable at runtime.

      config :elia, Elia.Skills, builtin: [Elia.Skills.Shell, ...]
  """

  use GenServer

  require Logger

  alias Elia.Skills.Folder

  @topic "skills"

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
  The system prompt's pieces, in order: the agent instructions, then one
  section per skill (with its leading separator). They concatenate to
  `system_prompt/1`, so the context indicator can size each one.
  """
  def system_sections(skills \\ current()) do
    [String.trim(@base_prompt) | Enum.map(skills, &("\n\n" <> skill_section(&1)))]
  end

  def system_prompt(skills \\ current()), do: skills |> system_sections() |> Enum.join()

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
    builtin = Enum.map(builtin(), &Elia.Skill.from_module/1)
    dir = Elia.Workspace.skills_dir()

    folders =
      case File.ls(dir) do
        {:ok, names} ->
          for name <- Enum.sort(names), File.dir?(Path.join(dir, name)), do: Path.join(dir, name)

        {:error, _} ->
          []
      end

    {skills, errors} =
      Enum.reduce(folders, {builtin, []}, fn folder, {skills, errors} ->
        with {:ok, skill} <- Folder.load(folder),
             :ok <- check_conflicts(skill, skills) do
          {skills ++ [skill], errors}
        else
          {:error, reason} -> {skills, errors ++ [{Elia.Workspace.relative(folder), reason}]}
        end
      end)

    for {folder, reason} <- errors, do: Logger.warning("Skill #{folder} not loaded: #{reason}")
    %{skills: skills, errors: errors}
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
