defmodule Elia.Agent do
  @moduledoc "Public API for agent sessions."

  alias Elia.Agent.Session

  def topic(id), do: "agent:" <> id

  def subscribe(id), do: Phoenix.PubSub.subscribe(Elia.PubSub, topic(id))

  def unsubscribe(id), do: Phoenix.PubSub.unsubscribe(Elia.PubSub, topic(id))

  def activity_topic, do: "agent:activity"

  def subscribe_activity, do: Phoenix.PubSub.subscribe(Elia.PubSub, activity_topic())

  @doc """
  Ids of the sessions whose turn is running (SESS-28), read from the registry
  without calling the sessions, like `awaiting_approval/0` and `paused/0`.
  """
  @spec running() :: [binary()]
  def running, do: with_status(:running)

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
  Turns the jail for this chat's commands on or off (SESS-30, ISOL-16). Allowed
  mid-turn (ISOL-19).
  """
  @spec set_jail(binary(), boolean()) :: :ok
  def set_jail(id, on?) when is_boolean(on?),
    do: GenServer.call(Session.via(id), {:set_jail, on?})

  @doc """
  Sets this chat's turn limits (SESS-31, LIMIT-2): any of `:max_steps` (a whole
  number of steps, LOOP-16), `:max_minutes` (a number of minutes, LOOP-20) and
  `:pause_on_limit` (whether a limit pauses the turn, LOOP-19). `nil` clears a
  limit, so the loop's own default applies (LIMIT-1). An invalid value returns
  `{:error, message}` and changes nothing (LIMIT-7). Allowed mid-turn: the next
  turn is started with the new limits (LIMIT-3).
  """
  @spec set_limits(binary(), map() | keyword()) :: :ok | {:error, binary()}
  def set_limits(id, changes), do: GenServer.call(Session.via(id), {:set_limits, changes})

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
  Deletes a chat (SESS-29): stops its turn if one is running (SESS-8, which also
  cancels or stops its sub-tasks, SESS-22), terminates its session process so no
  stale session can save it again, then removes the saved chat and its worktree
  (STORE-23). A chat with no session is simply removed. `{:error, :invalid_id}`
  for an invalid id (STORE-4).
  """
  @spec delete(binary()) :: :ok | {:error, :invalid_id}
  def delete(id) do
    if Elia.Store.valid_id?(id) do
      stop_if_started(id)
      terminate_session(id)
      Elia.Store.delete(id)
    else
      {:error, :invalid_id}
    end
  end

  # SESS-29: the session may not be started (or may be gone already), so stopping
  # its turn is best effort — SESS-8 and SESS-22 do the rest.
  defp stop_if_started(id) do
    stop(id)
  catch
    :exit, _ -> :ok
  end

  # SESS-29: terminate the session process, so a stale session can't save the
  # chat again. Same shape as the child cleanup in `Elia.Tasks`.
  defp terminate_session(id) do
    for {pid, _} <- Registry.lookup(Elia.Agent.Registry, id), do: terminate_child(pid)
    :ok
  end

  defp terminate_child(pid) do
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
  catch
    :exit, _ -> :ok
  end

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
