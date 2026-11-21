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
  Ids of the sessions waiting for an answer to a question (SESS-34), read from
  the registry without calling the sessions, like `awaiting_approval/0`.
  """
  @spec awaiting_input() :: [binary()]
  def awaiting_input, do: with_status(:awaiting_input)

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

  @doc """
  Whether a session for this chat is running in this app instance (SESS-32),
  read from the registry without calling it, like `running/0` and
  `awaiting_approval/0` (SESS-19). It is `false` for a chat with no session, for
  an invalid id and when the registry isn't running. A chat list uses it to tell
  the record a restart left behind (INTR-2, STORE-31) from a turn that is
  running right now.
  """
  @spec live?(binary()) :: boolean()
  def live?(id) do
    is_binary(id) and Process.whereis(Elia.Agent.Registry) != nil and
      Registry.lookup(Elia.Agent.Registry, id) != []
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

  @doc """
  Sends `text` with the files it carries (UPLOAD-10, UPLOAD-11), each of them a
  path relative to the chat's own workspace (UPLOAD-6), in the order they were
  attached.
  """
  def send_message(id, text, attachments),
    do: GenServer.call(Session.via(id), {:send_message, text, attachments})

  def approve(id, call_id), do: GenServer.call(Session.via(id), {:decide, call_id, :approve})

  def deny(id, call_id), do: GenServer.call(Session.via(id), {:decide, call_id, :deny})

  @doc """
  Answers a question the turn is waiting on (ASK-4, ASK-6, SESS-34): `answer` is
  what the user gave, an option's text or words of their own. Returns
  `{:error, :blank}` for an answer that is blank once trimmed, and
  `{:error, :not_pending}` for a call that isn't awaiting an answer, changing
  nothing either way.
  """
  @spec answer(binary(), binary(), binary()) ::
          :ok | {:error, :blank} | {:error, :not_pending}
  def answer(id, call_id, answer) when is_binary(answer),
    do: GenServer.call(Session.via(id), {:answer, call_id, answer})

  @doc """
  Turns auto-approval of `tool_name` on or off for the chat (APPR-8). Turning
  it on also approves that tool's pending calls (APPR-11). Turning it on for a
  tool that never needs approval returns `{:error, :not_approvable}` (APPR-13).
  """
  @spec set_auto_approve(binary(), binary(), boolean()) :: :ok | {:error, :not_approvable}
  def set_auto_approve(id, tool_name, on?) when is_binary(tool_name) and is_boolean(on?) do
    # SESS-41: one of the typed entry points of the one write path. SESS-42: the
    # only refusal this change can get is APPR-13's, reported as this setter
    # promises rather than in the path's own words.
    case set_settings(id, %{auto_approve: %{tool_name => on?}}) do
      :ok -> :ok
      {:error, _message} -> {:error, :not_approvable}
    end
  end

  @doc """
  Sets any of the chat's per-chat settings at once (SESS-41): `:model` (a
  selection, MODEL-1, or `nil` for none of its own), `:auto_approve` (a map of
  tool names to whether the chat auto-approves them, APPR-8), `:jail` (a
  boolean, ISOL-16), `:network` (a setting of NET-1: a mode and, in allowlist
  mode, its hosts), `:limits` (a map of turn limits to change, LIMIT-1) and
  `:effort` (`nil` or one of `"low"`, `"medium"` and `"high"`, LLM-39). It is
  the one write path: the change is saved with the chat once it has messages and
  broadcast as one `{:settings, settings}` event (SESS-6), so every view of the
  chat agrees. A key of a change that isn't one of the settings, or a value that
  isn't one for its key, returns `{:error, message}` naming the setting at fault
  and changes nothing (SESS-42).
  """
  @spec set_settings(binary(), map()) :: :ok | {:error, binary()}
  def set_settings(id, changes) when is_map(changes),
    do: GenServer.call(Session.via(id), {:set_settings, changes})

  @doc """
  Turns the jail for this chat's commands on or off (SESS-30, ISOL-16). Allowed
  mid-turn (ISOL-19).
  """
  @spec set_jail(binary(), boolean()) :: :ok
  def set_jail(id, on?) when is_boolean(on?), do: set_settings(id, %{jail: on?})

  @doc """
  Sets this chat's own reasoning effort (SESS-40, LLM-39): `"low"`, `"medium"`
  or `"high"`, or `nil` for no effort of its own, so the configured one applies
  (LLM-38). It reaches the provider as the request's `:effort` (LLM-39) from the
  next turn on. Any other value returns `{:error, message}` and changes nothing.
  """
  @spec set_effort(binary(), binary() | nil) :: :ok | {:error, binary()}
  def set_effort(id, effort), do: set_settings(id, %{effort: effort})

  @doc """
  Sets this chat's network setting (SESS-41, NET-1): `%{mode: mode}` with the
  mode `:unrestricted`, `:allowlist` or `:none`, and `%{hosts: [entry]}` for
  the hosts an allowlist names (NET-7). A mode that is not one of the three, or
  a host that is not one of NET-7's forms, returns `{:error, message}` and
  changes nothing (NET-11). Allowed mid-turn (ISOL-19): a change reaches the
  commands and terminals that start after it (NET-5), and, in allowlist mode, a
  running command's next request (NET-6).
  """
  @spec set_network(binary(), map()) :: :ok | {:error, binary()}
  def set_network(id, setting), do: set_settings(id, %{network: setting})

  @doc """
  This chat's network setting as it stands (NET-1), or `nil` when the chat has
  no running session — a proxy that decides a running command's requests falls
  back to the list it started with (NET-6).
  """
  @spec network(binary()) :: map() | nil
  def network(id) do
    if live?(id), do: GenServer.call(Session.via(id), :network), else: nil
  end

  @doc """
  Sets this chat's turn limits (SESS-31, LIMIT-2): any of `:max_steps` (a whole
  number of steps, LOOP-16), `:max_minutes` (a number of minutes, LOOP-20),
  `:max_tokens` (a whole number of tokens, LOOP-22, LIMIT-12) and
  `:pause_on_limit` (whether a limit pauses the turn, LOOP-19). `nil` clears a
  limit, so the loop's own default applies (LIMIT-1) — for the token budget that
  is no budget at all, so the turn's token spend is unlimited. An invalid value
  returns `{:error, message}` and changes nothing (LIMIT-7). Allowed mid-turn:
  the next turn is started with the new limits (LIMIT-3).
  """
  @spec set_limits(binary(), map() | keyword()) :: :ok | {:error, binary()}
  def set_limits(id, changes), do: set_settings(id, %{limits: Map.new(changes)})

  @doc """
  Gives the chat its own title (SESS-33, TITLE-4), the name its chat list row,
  its page title and the chat settings header show in place of the first user
  message (TITLE-1). The text is trimmed, its whitespace collapsed and cut to 60
  characters (TITLE-2), and the accepted title is returned. A blank title returns
  `{:error, message}`, as the `set_title` tool reports to the model (TITLE-6); a
  sub-task chat may name itself like any chat (TITLE-3).
  """
  @spec set_title(binary(), term()) :: {:ok, binary()} | {:error, binary()}
  def set_title(id, text), do: GenServer.call(Session.via(id), {:set_title, text})

  @doc """
  The chat's working directory (WD-1): an absolute path inside the chat's
  workspace (PROJ-12) that a command run by its `shell` call (SHELL-2) resolves
  a relative path against. It is the workspace root until the `cd` tool changes
  it (WD-3).
  """
  @spec cwd(binary()) :: binary()
  def cwd(id), do: GenServer.call(Session.via(id), :cwd)

  @doc """
  Changes the chat's working directory to the directory `path` names, absolute
  or relative to the current one, and returns it named relative to the workspace
  root — `.` for the root itself (WD-3). `nil` changes nothing and returns where
  the chat is (WD-4). A path that is missing, is not a directory, has no real
  location (WS-6) or leads outside the workspace (WD-5) returns `{:error,
  message}` and changes nothing. The change is saved with the chat (WD-2).
  """
  @spec set_cwd(binary(), binary() | nil) :: {:ok, binary()} | {:error, binary()}
  def set_cwd(id, path), do: GenServer.call(Session.via(id), {:set_cwd, path})

  @doc """
  Marks the chat done (`true`) or reopens it (`false`) (SESS-35, DONE-1). A done
  chat is shown as done wherever its status is (DONE-2) and can still be
  continued: a message reopens it (DONE-9).

  On a task chat, marking it done is what ends the task (SUBTASK-33): the
  harness builds the result from the chat's own state (SUBTASK-9) and it is
  saved with the chat's metadata (SUBTASK-13), and a parent's `await_task`
  returns the result (SUBTASK-27). The end is recorded once: a chat marked done
  again, or reopened and marked done again (DONE-9), keeps the result it has.
  """
  @spec set_done(binary(), boolean()) :: {:ok, boolean()}
  def set_done(id, on?) when is_boolean(on?),
    do: GenServer.call(Session.via(id), {:set_done, on?})

  @doc """
  Sets the chat's model (MODEL-1) through the one write path (SESS-41). Also
  remembers it as the default for new chats (MODEL-15).
  """
  def select_model(id, provider_key, model, name \\ nil) do
    with {:ok, selection} <- Elia.LLM.select(provider_key, model, name),
         :ok <- set_settings(id, %{model: selection}) do
      {:ok, selection}
    end
  end

  def stop(id), do: GenServer.call(Session.via(id), :stop)

  @doc """
  Deletes a chat (SESS-29): stops its turn if one is running (SESS-8, which also
  stops its sub-tasks' turns, SESS-22), terminates its session process so no
  stale session can save it again, then removes the saved chat (STORE-23). A
  chat with no session is simply removed. `{:error, :invalid_id}` for an
  invalid id (STORE-4). A running sub-task's chat deleted is that task
  over, so a parent waiting on it answers with an error (SUBTASK-35).
  """
  @spec delete(binary()) :: :ok | {:error, :invalid_id}
  def delete(id) do
    if Elia.Store.valid_id?(id) do
      stop_if_started(id)
      terminate_session(id)
      stop_terminal(id)
      Elia.Store.delete(id)
      # SESS-48: announced once the file is gone, so a page that reads the chats
      # again does not find it still there.
      announce_deleted(id)
      :ok
    else
      {:error, :invalid_id}
    end
  end

  # SESS-48: a deleted chat is announced on the activity topic (SESS-19), which
  # is how a page that lists chats drops it without a reload (ACTIVE-7). The
  # session it was running in is terminated first and announces no status of its
  # own, so this event is the only word of the deletion.
  defp announce_deleted(id) do
    Phoenix.PubSub.broadcast(Elia.PubSub, activity_topic(), {:chat_deleted, id})
  end

  # TERM-3: a chat's terminal stops with the chat, so deleting one leaves
  # nothing running on the machine. The session process is terminated rather
  # than left holding the last screen of a chat that no longer exists.
  defp stop_terminal(id) do
    case Elia.Terminal.fetch(id) do
      {:ok, pid} ->
        try do
          Elia.Terminal.stop(id)
        catch
          :exit, _ -> :ok
        end

        terminate_child(Elia.Terminal.Supervisor, pid)

      :error ->
        :ok
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
  # chat again.
  defp terminate_session(id) do
    for {pid, _} <- Registry.lookup(Elia.Agent.Registry, id),
        do: terminate_child(Elia.Agent.Supervisor, pid)

    :ok
  end

  defp terminate_child(supervisor, pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
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
  Fails a turn paused at a limit (SESS-27), ending that turn with the limit's
  error (LIMIT-4). The sub-task goes on: a task ends only when its chat is
  marked done (SUBTASK-24, SUBTASK-33). `{:error, :not_paused}` when the chat
  isn't paused.
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
  `:user_cap`, `:elide_floor` and `:auto`.
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
end
