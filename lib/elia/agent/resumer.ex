defmodule Elia.Agent.Resumer do
  @moduledoc """
  Resumes the turns a restart cut short (RESUME-1 to RESUME-3, `specs/auto-resume.md`).

  A chat's saved record still holds the turn that was in flight when the app
  stopped (STORE-30) and no session of it runs, which is what makes the chat
  interrupted (INTR-2). Starting its session is all it takes — the session
  itself decides to carry the turn on (RESUME-2, RESUME-3) — so this process
  starts one session per interrupted chat at boot, in its own time, so the
  application's own start is never held up, and only while automatic resume is
  on (RESUME-6).
  """

  use GenServer

  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Whether automatic resume is on (RESUME-6): `true` unless it is configured off
  with `config :elia, Elia.Agent.Resumer, enabled: false`.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:elia, __MODULE__, [])[:enabled] != false

  @doc """
  Starts a session for every chat a restart cut a turn short in (RESUME-1): the
  scan the application's own start does, and nothing at all while automatic
  resume is switched off (RESUME-6). Sub-task chats are started before the chats
  that started them, so a parent that is resumed finds its children's entries
  held again (SUBTASK-11, RESUME-7). A chat whose session already runs is left
  to it, and one whose session fails to start is logged and left out of the rest
  of the scan.
  """
  @spec resume_interrupted() :: :ok
  def resume_interrupted do
    # RESUME-6: switched off, no session is started for an interrupted chat, and
    # such a chat is exactly what INTR-2 and INTR-3 describe.
    if enabled?() do
      Elia.Store.interrupted()
      |> Enum.sort_by(&(Map.get(&1, :task_status) == nil))
      |> Enum.each(&resume/1)
    end

    :ok
  end

  @impl true
  def init(_opts), do: {:ok, nil, {:continue, :resume}}

  @impl true
  def handle_continue(:resume, state) do
    resume_interrupted()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp resume(entry) do
    case Elia.Agent.ensure_started(entry.id) do
      {:ok, _pid} ->
        :ok

      error ->
        Logger.error("Could not resume chat #{entry.id}: #{inspect(error)}")
    end
  end
end
