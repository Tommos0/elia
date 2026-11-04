defmodule Elia.Store do
  @moduledoc """
  Saves conversations as Erlang term files under `.elia/sessions/`.

  Terms (rather than JSON) keep provider-specific raw blocks exact, which
  matters because they are echoed back to the provider unchanged.
  """

  alias Elia.LLM.Message

  @id_format ~r/^[A-Za-z0-9_-]{1,64}$/

  def dir, do: Path.join(Elia.Workspace.data_dir(), "sessions")

  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_format, id)

  @doc """
  Saves a chat. `opts[:model]` is the chat's model selection (MODEL-1) and
  `opts[:auto_approve]` its auto-approved tool names (STORE-14), `opts[:task]`
  the sub-task metadata of a chat started by `spawn_task` (STORE-16),
  `opts[:project]` the id of the project it belongs to (STORE-19) and
  `opts[:compaction]` its compaction state (COMPACT-24); each is kept alongside
  the messages when given. `opts[:jail]` (a boolean) is the chat's jail setting
  (STORE-25) and is stored only when it is `false`, `opts[:limits]` the
  chat's turn limits (STORE-27), of which only the values that aren't the
  default (LIMIT-1) are stored, and `opts[:title]` the chat's own title
  (STORE-32), which is stored only when it isn't blank (TITLE-2).
  """
  @spec save(binary(), [Message.t()], keyword()) :: :ok | {:error, term()}
  def save(id, messages, opts \\ []) do
    true = valid_id?(id)
    File.mkdir_p!(dir())
    path = path(id)
    tmp = path <> ".tmp"

    now = DateTime.utc_now()
    chat = %{version: 1, messages: messages, created_at: created_at(id) || now, updated_at: now}
    chat = if model = opts[:model], do: Map.put(chat, :model, model), else: chat
    chat = if task = opts[:task], do: Map.put(chat, :task, task), else: chat
    chat = if project = opts[:project], do: Map.put(chat, :project_id, project), else: chat

    # STORE-30: the turn the chat's session is running. A save that doesn't give
    # one writes no entry, so the turn's end takes the key off the file (INTR-1).
    chat = if turn = opts[:turn], do: Map.put(chat, :turn, turn), else: chat

    # STORE-32, TITLE-2: a chat with no title (or a blank one) carries no entry,
    # and the chat list derives its title from the first user message (STORE-7).
    chat =
      case shape_title(opts[:title]) do
        nil -> chat
        title -> Map.put(chat, :title, title)
      end

    chat =
      case opts[:compaction] do
        %{} = compaction -> Map.put(chat, :compaction, compaction)
        _ -> chat
      end

    chat =
      case opts[:auto_approve] do
        [_ | _] = names -> Map.put(chat, :auto_approve, names)
        _ -> chat
      end

    # STORE-25: the jail is on by default (ISOL-16), so only "off" is written.
    chat = if opts[:jail] == false, do: Map.put(chat, :jail, false), else: chat

    # STORE-27: only the limits that aren't the default (LIMIT-1) are written,
    # so a chat that sets none carries no entry at all.
    chat =
      case Elia.Limits.stored(opts[:limits] || %{}) do
        limits when map_size(limits) > 0 -> Map.put(chat, :limits, limits)
        _none -> chat
      end

    data = :erlang.term_to_binary(chat)

    with :ok <- File.write(tmp, data), do: File.rename(tmp, path)
  end

  @spec load(binary()) :: [Message.t()]
  def load(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{messages: messages} <- decode(data) do
      Enum.map(messages, &Message.scrub/1)
    else
      _ -> []
    end
  end

  @doc "The chat's saved model selection, or `nil` (STORE-9)."
  @spec load_model(binary()) :: map() | nil
  def load_model(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{model: %{} = model} <- decode(data) do
      model
    else
      _ -> nil
    end
  end

  @doc """
  The chat's own title, or `nil` (STORE-32): `nil` when the chat is missing,
  unreadable, corrupt or has no title of its own, in which case its title is
  the first user message (STORE-7, TITLE-1).
  """
  @spec load_title(binary()) :: binary() | nil
  def load_title(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{} = chat <- decode(data) do
      shape_title(Map.get(chat, :title))
    else
      _ -> nil
    end
  end

  @doc """
  The shape a title has (TITLE-2): trimmed, its runs of whitespace collapsed to
  single spaces and cut to 60 characters — the same cut the derivation uses
  (STORE-7) — since a title is one line in a chat list. `nil` for anything that
  isn't a title at all (not a string, or blank once trimmed), so a chat is never
  listed under an empty title.
  """
  @spec shape_title(term()) :: binary() | nil
  def shape_title(text) when is_binary(text) do
    case text |> String.replace(~r/\s+/u, " ") |> String.trim() do
      "" -> nil
      title -> String.slice(title, 0, 60)
    end
  end

  def shape_title(_text), do: nil

  @doc """
  The chat's title (STORE-33, TITLE-1): the one saved with it (STORE-32) when it
  has one, else the first user message cut to 60 characters (STORE-7), else
  "New chat" — the same answer the chat list gives, for a view that has an id
  and not a listed entry.
  """
  @spec chat_title(binary()) :: binary()
  def chat_title(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{messages: messages} = chat <- decode(data) do
      shape_title(Map.get(chat, :title)) || title(messages)
    else
      _ -> "New chat"
    end
  end

  @doc "The chat's saved auto-approved tool names, or `[]` (STORE-15)."
  @spec load_auto_approve(binary()) :: [binary()]
  def load_auto_approve(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{auto_approve: [_ | _] = names} <- decode(data),
         true <- Enum.all?(names, &is_binary/1) do
      names
    else
      _ -> []
    end
  end

  @doc """
  The chat's saved jail setting (STORE-26): `true` unless the chat turned it
  off, and `true` when the chat is missing, unreadable, corrupt or has no value,
  since the jail is on by default (ISOL-16).
  """
  @spec load_jail(binary()) :: boolean()
  def load_jail(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{jail: jail} <- decode(data),
         true <- is_boolean(jail) do
      jail
    else
      _ -> true
    end
  end

  @doc """
  The chat's saved turn limits (STORE-28), over the defaults of LIMIT-1, so it
  answers like LIMIT-1 does for a chat that is missing, unreadable, corrupt or
  has none.
  """
  @spec load_limits(binary()) :: Elia.Limits.t()
  def load_limits(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{limits: %{} = limits} <- decode(data) do
      Elia.Limits.new(limits)
    else
      _ -> Elia.Limits.defaults()
    end
  end

  @doc """
  The saved sub-task metadata of a chat started by `spawn_task`, or `nil`
  (STORE-16): `%{parent_id, title, brief, started_at, status, start_commit,
  result}`.
  """
  @spec load_task(binary()) :: map() | nil
  def load_task(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{task: %{parent_id: _} = task} <- decode(data) do
      task
    else
      _ -> nil
    end
  end

  @doc "The id of the project a chat belongs to, or `nil` (STORE-19, PROJ-9)."
  @spec load_project(binary()) :: binary() | nil
  def load_project(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{project_id: project_id} <- decode(data),
         true <- is_binary(project_id) do
      project_id
    else
      _ -> nil
    end
  end

  @doc """
  The chat's saved compaction state, or `nil` (COMPACT-24): the summary, the
  ledger, the pin set, how far the ladder has gone and the chat's own options.
  """
  @spec load_compaction(binary()) :: map() | nil
  def load_compaction(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{compaction: %{} = compaction} <- decode(data) do
      compaction
    else
      _ -> nil
    end
  end

  @doc """
  The turn the chat's session was running, or `nil` (STORE-30): `%{id,
  started_at}` while a turn is in flight, left behind by a restart that stopped
  the app mid-turn (INTR-2).
  """
  @spec load_turn(binary()) :: map() | nil
  def load_turn(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         %{turn: %{id: _} = turn} <- decode(data) do
      turn
    else
      _ -> nil
    end
  end

  @doc "Saved conversations, most recently started first (STORE-12)."
  def list(limit \\ 50), do: all_entries() |> Enum.take(limit)

  @doc """
  The chat to resume when the user opens the chat list (STORE-29, UI-77): the most
  recently started chat (STORE-12) that isn't a task chat (STORE-17), as a
  listed entry, or `nil` when there is none. Every saved chat is considered,
  not only the first page of `list/1`.
  """
  @spec latest() :: map() | nil
  def latest do
    all_entries()
    |> Enum.find(&(valid_id?(&1.id) and Map.get(&1, :task_status) == nil))
  end

  @doc """
  The task chats started by `parent_id`, oldest first, as listed entries
  (STORE-18).
  """
  @spec children(binary()) :: [map()]
  def children(parent_id) do
    all_entries()
    |> Enum.filter(&(Map.get(&1, :parent_id) == parent_id))
    |> Enum.reverse()
  end

  defp all_entries do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".term"))
        |> Enum.map(&list_entry/1)
        |> Enum.sort_by(&DateTime.to_unix(&1.created_at, :microsecond), :desc)
        |> Enum.map(fn entry ->
          {messages, entry} = Map.pop(entry, :messages)
          {task, entry} = Map.pop(entry, :task)

          entry
          |> Map.merge(%{
            # STORE-33, TITLE-1: the chat's own title when it has one, else the
            # derivation from its first user message (STORE-7). The description
            # is that derivation either way (STORE-10), so hovering a row still
            # shows what was asked.
            title: Map.get(entry, :title) || title(messages),
            description: title(messages, 1000)
          })
          |> put_task(task)
        end)

      {:error, _} ->
        []
    end
  end

  # STORE-17: a sub-task chat is listed under its task title, with its parent
  # and status. A task saved as running whose child isn't the active one lost
  # its session (app restart), so it is shown as interrupted.
  defp put_task(entry, %{parent_id: parent_id} = task) do
    status =
      case task[:status] do
        "running" -> if Elia.Tasks.running?(entry.id), do: "running", else: "interrupted"
        status -> status
      end

    title = if is_binary(task[:title]) and task.title != "", do: task.title, else: entry.title

    Map.merge(entry, %{
      title: title,
      parent_id: parent_id,
      task_status: status,
      parent_call_id: task[:parent_call_id]
    })
  end

  defp put_task(entry, _task), do: entry

  defp list_entry(file) do
    id = Path.rootname(file)
    path = Path.join(dir(), file)
    mtime = path |> File.stat!(time: :posix) |> Map.fetch!(:mtime) |> DateTime.from_unix!()

    chat =
      with {:ok, data} <- File.read(path),
           %{} = chat <- decode(data) do
        chat
      else
        _ -> %{}
      end

    %{
      id: id,
      messages: Map.get(chat, :messages, []),
      task: Map.get(chat, :task),
      project_id: Map.get(chat, :project_id),
      # STORE-31: a chat that still holds a turn record (STORE-30) while no
      # session for it runs was interrupted by a restart (INTR-2).
      interrupted: not is_nil(Map.get(chat, :turn)) and not Elia.Agent.live?(id),
      # The chat's own title (STORE-32), nil when it has none (STORE-33).
      title: shape_title(Map.get(chat, :title)),
      created_at: Map.get(chat, :created_at) || mtime,
      updated_at: Map.get(chat, :updated_at) || mtime
    }
  end

  # The start date of an already saved chat, or `nil` (STORE-11).
  defp created_at(id) do
    with {:ok, data} <- File.read(path(id)),
         %{} = chat <- decode(data) do
      case chat do
        %{created_at: %DateTime{} = at} -> at
        _ -> path(id) |> File.stat!(time: :posix) |> Map.fetch!(:mtime) |> DateTime.from_unix!()
      end
    else
      _ -> nil
    end
  end

  @doc """
  Whether `id` is a valid chat id with a saved chat file (STORE-24). The file
  isn't decoded, so this is cheap; it is `false` for an invalid id (STORE-4) and
  for an id with no file.
  """
  @spec exists?(binary()) :: boolean()
  def exists?(id), do: valid_id?(id) and File.exists?(path(id))

  @doc """
  Deletes a saved chat. A chat's worktree goes with it — removed, and its branch
  pruned (DEPLOY-10) — and a chat that has no saved file yet is deleted too
  (STORE-23). Only that chat goes: a parent's task chats, and a task chat's
  parent, are left saved (UI-66).
  """
  @spec delete(binary()) :: :ok | {:error, term()}
  def delete(id) do
    if valid_id?(id) do
      Elia.Deploy.remove_worktree(id)

      case File.rm(path(id)) do
        :ok -> :ok
        # No file yet (STORE-22 writes one only once the chat is started): the
        # chat is deleted all the same.
        {:error, :enoent} -> :ok
        error -> error
      end
    else
      {:error, :invalid_id}
    end
  end

  @doc "Display title for a conversation: its first user message, cut to `max` characters."
  def title(messages, max \\ 60) do
    case Enum.find(messages, &(&1.role == :user and not Map.get(&1.meta, :harness, false))) do
      nil -> "New chat"
      message -> message |> Message.text_content() |> String.slice(0, max)
    end
  end

  defp ensure_app_loaded do
    unless :persistent_term.get({__MODULE__, :app_loaded}, false) do
      {:ok, modules} = :application.get_key(:elia, :modules)
      Code.ensure_all_loaded(modules)
      :persistent_term.put({__MODULE__, :app_loaded}, true)
    end
  end

  defp path(id), do: Path.join(dir(), id <> ".term")

  # `:safe` refuses atoms that don't exist yet. In dev, modules load lazily,
  # so after a restart atoms like `:tool_call` may not exist until the code
  # that defines them is loaded; load it all first (STORE-3).
  defp decode(data) do
    ensure_app_loaded()
    :erlang.binary_to_term(data, [:safe])
  rescue
    ArgumentError -> nil
  end
end
