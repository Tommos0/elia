defmodule Elia.Agent do
  @moduledoc "Public API for agent sessions."

  alias Elia.Agent.Session

  def topic(id), do: "agent:" <> id

  def subscribe(id), do: Phoenix.PubSub.subscribe(Elia.PubSub, topic(id))

  def unsubscribe(id), do: Phoenix.PubSub.unsubscribe(Elia.PubSub, topic(id))

  def activity_topic, do: "agent:activity"

  def subscribe_activity, do: Phoenix.PubSub.subscribe(Elia.PubSub, activity_topic())

  @doc """
  Ids of the sessions with a tool call awaiting approval (SESS-19), read from
  the registry without calling the sessions.
  """
  @spec awaiting_approval() :: [binary()]
  def awaiting_approval do
    Registry.select(Elia.Agent.Registry, [
      {{:"$1", :_, :"$2"}, [{:==, :"$2", :awaiting_approval}], [:"$1"]}
    ])
  end

  def new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  @doc "Returns the session's pid, starting it if needed."
  def ensure_started(id, opts \\ []) do
    spec = {Session, Keyword.put(opts, :id, id)}

    case DynamicSupervisor.start_child(Elia.Agent.Supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def snapshot(id), do: GenServer.call(Session.via(id), :snapshot)

  def send_message(id, text), do: GenServer.call(Session.via(id), {:send_message, text})

  def approve(id, call_id), do: GenServer.call(Session.via(id), {:decide, call_id, :approve})

  def deny(id, call_id), do: GenServer.call(Session.via(id), {:decide, call_id, :deny})

  @doc """
  Turns auto-approval of `tool_name` on or off for the chat (APPR-8). Turning
  it on also approves that tool's pending calls (APPR-11). Turning it on for a
  tool that never needs approval returns `{:error, :not_approvable}` (APPR-13).
  """
  @spec set_auto_approve(binary(), binary(), boolean()) :: :ok | {:error, :not_approvable}
  def set_auto_approve(id, tool_name, on?) when is_binary(tool_name) and is_boolean(on?),
    do: GenServer.call(Session.via(id), {:set_auto_approve, tool_name, on?})

  @doc """
  Sets the chat's model (MODEL-1). Also remembers it as the default for new
  chats (MODEL-15).
  """
  def select_model(id, provider_key, model, name \\ nil) do
    with {:ok, selection} <- Elia.LLM.select(provider_key, model, name),
         :ok <- GenServer.call(Session.via(id), {:select_model, selection}) do
      {:ok, selection}
    end
  end

  def stop(id), do: GenServer.call(Session.via(id), :stop)

  @doc """
  Merges `changes` into the task metadata of a sub-task chat and saves it
  (SESS-18). `{:error, :not_a_task}` for a chat without task metadata.
  """
  @spec update_task(binary(), map()) :: :ok | {:error, :not_a_task}
  def update_task(id, changes) when is_map(changes),
    do: GenServer.call(Session.via(id), {:update_task, changes})
end
