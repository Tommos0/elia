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
  def awaiting_approval, do: with_status(:awaiting_approval)

  @doc """
  Ids of the sessions whose turn is paused at a limit (SESS-19, SESS-27), read
  from the registry without calling the sessions.
  """
  @spec paused() :: [binary()]
  def paused, do: with_status(:paused)

  defp with_status(status) do
    Registry.select(Elia.Agent.Registry, [
      {{:"$1", :_, :"$2"}, [{:==, :"$2", status}], [:"$1"]}
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
  Resumes a turn paused at a limit (SESS-27): the step count and the wall-clock
  budget start over (LOOP-19). `{:error, :not_paused}` when the chat isn't
  paused.
  """
  @spec resume(binary()) :: :ok | {:error, :not_paused}
  def resume(id), do: GenServer.call(Session.via(id), :resume)

  @doc """
  Fails a turn paused at a limit (SESS-27), ending the sub-task with the limit's
  error (SUBTASK-24). `{:error, :not_paused}` when the chat isn't paused.
  """
  @spec fail_task(binary()) :: :ok | {:error, :not_paused}
  def fail_task(id), do: GenServer.call(Session.via(id), :fail_task)

  @doc """
  Compacts the chat now, on demand (COMPACT-10): it ignores the threshold and
  the target, and needs no known window. `{:error, :busy}` while a turn runs.
  """
  @spec compact(binary()) :: :ok | {:error, :busy}
  def compact(id), do: GenServer.call(Session.via(id), :compact)

  @doc """
  Sets this chat's compaction options (COMPACT-9): any of `:budget`,
  `:fraction`, `:target_fraction`, `:working_set`, `:working_set_tokens`,
  `:user_cap` and `:auto`.
  """
  @spec set_compaction(binary(), map() | keyword()) :: :ok
  def set_compaction(id, options), do: GenServer.call(Session.via(id), {:set_compaction, options})

  @doc """
  Pins or unpins a message (`block` nil) or one of its blocks (COMPACT-21), so
  no compaction rule may elide it.
  """
  @spec set_pin(binary(), non_neg_integer(), non_neg_integer() | nil, boolean()) ::
          :ok | {:error, :no_such_message}
  def set_pin(id, index, block \\ nil, on? \\ true),
    do: GenServer.call(Session.via(id), {:set_pin, index, block, on?})

  @doc """
  Appends `entries` (a list of exact facts) to the chat's compaction ledger
  (COMPACT-22) and returns it. The ledger is sent with every request and is
  never elided or summarized.
  """
  @spec add_ledger(binary(), [binary()]) :: {:ok, [binary()]}
  def add_ledger(id, entries) when is_list(entries),
    do: GenServer.call(Session.via(id), {:add_ledger, entries})

  @doc """
  Merges `changes` into the task metadata of a sub-task chat and saves it
  (SESS-18). `{:error, :not_a_task}` for a chat without task metadata.
  """
  @spec update_task(binary(), map()) :: :ok | {:error, :not_a_task}
  def update_task(id, changes) when is_map(changes),
    do: GenServer.call(Session.via(id), {:update_task, changes})
end
