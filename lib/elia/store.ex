defmodule Elia.Store do
  @moduledoc """
  Saves conversations as Erlang term files under `.elia/sessions/`.

  Terms (rather than JSON) keep provider-specific raw blocks exact, which
  matters because they are echoed back to the provider unchanged.
  """

  require Logger

  alias Elia.LLM.Message
  alias Elia.Store.Cache
  alias Elia.Store.Index

  @id_format ~r/^[A-Za-z0-9_-]{1,64}$/

  # LLM-39, STORE-37: the reasoning efforts a chat may have of its own.
  @efforts ["low", "medium", "high"]

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
  default (LIMIT-1) are stored, `opts[:title]` the chat's own title
  (STORE-32), which is stored only when it isn't blank (TITLE-2),
  `opts[:done]` (a boolean) whether the chat is marked done (STORE-34), which is
  stored only when it is `true`, `opts[:effort]` the chat's own reasoning
  effort (`"low"`, `"medium"` or `"high"`, LLM-39, STORE-37), which is stored
  only when the chat has one of its own, and `opts[:cwd]` the chat's working
  directory as an absolute path (STORE-46, WD-1), which is stored only when the
  chat has one of its own — a chat working in its workspace root carries no
  entry (WD-7).
  """
  @spec save(binary(), [Message.t()], keyword()) :: :ok | {:error, term()}
  def save(id, messages, opts \\ []) do
    true = valid_id?(id)
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

    # STORE-34, DONE-1: a chat is open by default, so only "done" is written and
    # reopening it takes the entry off the file.
    chat = if opts[:done] == true, do: Map.put(chat, :done, true), else: chat

    # STORE-37: only an effort the chat has of its own is written, so a chat
    # that keeps the configured default (LLM-38) carries no entry and giving the
    # chat no effort again drops the key from the file.
    chat = if opts[:effort] in @efforts, do: Map.put(chat, :effort, opts[:effort]), else: chat

    # STORE-46, WD-7: the chat's working directory, written only when it is not
    # its workspace root, so a chat that never changed directory carries no
    # entry and moving back to the root drops the key from the file.
    chat = if cwd = opts[:cwd], do: Map.put(chat, :cwd, cwd), else: chat

    # STORE-27: only the limits that aren't the default (LIMIT-1) are written,
    # so a chat that sets none carries no entry at all.
    chat =
      case Elia.Limits.stored(opts[:limits] || %{}) do
        limits when map_size(limits) > 0 -> Map.put(chat, :limits, limits)
        _none -> chat
      end

    write(id, chat)
  end

  @doc """
  Changes some keys of a saved chat and keeps the rest of its file as it was
  (STORE-43): `fun` gets the saved chat's map and returns the new one, and
  `updated_at` is set to now. Writes nothing for an invalid id, a chat with no
  file or a malformed saved chat (STORE-49), so it never creates a chat.
  """
  @spec update(binary(), (map() -> map())) :: :ok | {:error, term()}
  def update(id, fun) when is_function(fun, 1) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         {:ok, chat} <- saved_chat(data, id) do
      # STORE-11: a file older than `created_at` gets the date it would have
      # been listed with, before this write changes its modification time.
      chat
      |> Map.put_new_lazy(:created_at, fn -> created_at(id) end)
      |> fun.()
      |> Map.put(:updated_at, DateTime.utc_now())
      |> then(&write(id, &1))
    else
      _ -> {:error, :not_found}
    end
  end

  # STORE-2: each write has a temporary file of its own, flushed before it is
  # renamed into place, so saves of one chat at the same time never write into
  # or rename away each other's. The name doesn't end in `.term`, so a file a
  # crash leaves behind is never listed (`all_entries/0`).
  defp write(id, chat) do
    with :ok <- ensure_dir() do
      path = path(id)
      tmp = "#{path}.#{System.os_time()}-#{System.unique_integer([:positive])}.tmp"

      with :ok <- write_synced(tmp, :erlang.term_to_binary(chat)),
           :ok <- File.rename(tmp, path) do
        # STORE-45, SEARCH-4: the rename already changed the file's identity;
        # the cache's entry and the index's go now rather than waiting for a
        # listing or a search to find them stale.
        Cache.drop(id)
        Index.drop(id)
        :ok
      else
        error ->
          _ = File.rm(tmp)
          error
      end
    end
  end

  # STORE-47: a data directory that can't be made is a save that failed like any
  # other — logged and carried on from (SESS-13) — so it answers an error rather
  # than raising as `File.mkdir_p!/1` would.
  defp ensure_dir do
    case File.mkdir_p(dir()) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp write_synced(path, data) do
    with {:ok, io} <- :file.open(path, [:write, :binary, :raw]) do
      try do
        with :ok <- :file.write(io, data), do: :file.sync(io)
      after
        :file.close(io)
      end
    end
  end

  @spec load(binary()) :: [Message.t()]
  def load(id) do
    with true <- valid_id?(id),
         {:ok, data} <- File.read(path(id)),
         # SEARCH-5, SEARCH-6: this is a decode of the chat's file, reported the
         # way the cache of STORE-45 reports its own (`decode_record/4`), so a
         # test can count which chats a search read.
         :ok <- decoded(id) do
      # STORE-3, STORE-49: a file that can't be read as a chat gives an empty
      # history — a corrupt one, and a decodable term that isn't a chat.
      case saved_chat(data, id) do
        {:ok, chat} -> Enum.map(chat.messages, &Message.scrub/1)
        :error -> []
      end
    else
      _ -> []
    end
  end

  defp decoded(id) do
    :telemetry.execute([:elia, :store, :decode], %{count: 1}, %{id: id})
    :ok
  end

  @doc """
  The identity of a chat's file — its inode, size and modification time, in
  POSIX time — or `nil` for an id that isn't one and for an id with no file.

  It is what the listing cache of STORE-45 and the search index of SEARCH-4 key
  a chat's decoded form on: every save renames a new file into place (STORE-2),
  so a file written by anything has an identity no entry was made from. Read
  with one `stat`, so asking is cheap.
  """
  @spec identity(binary()) :: {integer(), integer(), integer()} | nil
  def identity(id) do
    if valid_id?(id), do: stat(id)
  end

  @doc """
  A chat's saved keys other than `messages`, as one map (STORE-44), or `nil`
  for an invalid id or a chat that is missing, unreadable or corrupt. Every
  per-key loader below reads it, so they decode the file once between them —
  and not at all while it is unchanged (STORE-45).
  """
  @spec load_meta(binary()) :: map() | nil
  def load_meta(id) do
    with true <- valid_id?(id),
         %{meta: %{} = meta} <- record(id) do
      meta
    else
      _ -> nil
    end
  end

  @doc "The chat's saved model selection, or `nil` (STORE-9)."
  @spec load_model(binary()) :: map() | nil
  def load_model(id) do
    case load_meta(id) do
      %{model: %{} = model} -> model
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
    case load_meta(id) do
      %{} = meta -> shape_title(Map.get(meta, :title))
      nil -> nil
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
         %{meta: %{} = meta, title: derived} <- record(id) do
      shape_title(Map.get(meta, :title)) || derived
    else
      _ -> "New chat"
    end
  end

  @doc """
  Whether the chat is marked done, or `false` (STORE-34, DONE-1): `false` when
  the chat is missing, unreadable, corrupt or has no value, since a chat is open
  until it is marked done.
  """
  @spec load_done(binary()) :: boolean()
  def load_done(id) do
    case load_meta(id) do
      %{} = meta -> Map.get(meta, :done) == true
      nil -> false
    end
  end

  @doc "The chat's saved auto-approved tool names, or `[]` (STORE-15)."
  @spec load_auto_approve(binary()) :: [binary()]
  def load_auto_approve(id) do
    with %{auto_approve: [_ | _] = names} <- load_meta(id),
         true <- Enum.all?(names, &is_binary/1) do
      names
    else
      _ -> []
    end
  end

  @doc """
  The chat's saved working directory (STORE-46, WD-1), or `nil` when it has
  none — a chat working in its workspace root, and a chat saved before the key
  existed (WD-7) — and when the chat is missing, unreadable or corrupt.
  """
  @spec load_cwd(binary()) :: binary() | nil
  def load_cwd(id) do
    case load_meta(id) do
      %{cwd: cwd} when is_binary(cwd) -> cwd
      _none -> nil
    end
  end

  @doc """
  The chat's saved jail setting (STORE-26): `true` unless the chat turned it
  off, and `true` when the chat is missing, unreadable, corrupt or has no value,
  since the jail is on by default (ISOL-16).
  """
  @spec load_jail(binary()) :: boolean()
  def load_jail(id) do
    with %{jail: jail} <- load_meta(id),
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
    case load_meta(id) do
      %{limits: %{} = limits} -> Elia.Limits.new(limits)
      _ -> Elia.Limits.defaults()
    end
  end

  @doc """
  The chat's own reasoning effort, or `nil` (STORE-38): `nil` when the chat is
  missing, unreadable, corrupt or has none of its own, in which case the
  configured effort applies (LLM-38). A chat saved before this field existed
  reads as one with no effort of its own, so nothing older needs a migration.
  """
  @spec load_effort(binary()) :: binary() | nil
  def load_effort(id) do
    with %{effort: effort} <- load_meta(id),
         true <- effort in @efforts do
      effort
    else
      _ -> nil
    end
  end

  @doc """
  The saved sub-task metadata of a chat started by `spawn_task`, or `nil`
  (STORE-16): `%{parent_id, started_at}` and, once the chat is marked done, its
  `result` (SUBTASK-9, SUBTASK-13). It carries no status — a chat's status is
  derived from the chat itself (UI-59, STORE-31) — no title and no brief, which
  are the chat's own title (STORE-32) and the first message of its transcript
  (SUBTASK-5): a `status`, `title`, `brief`, `parent_call_id` or `start_commit`
  key an earlier version wrote is ignored, and such a chat's metadata reads as
  the keys it has (STORE-16).
  """
  @spec load_task(binary()) :: map() | nil
  def load_task(id) do
    case load_meta(id) do
      %{task: %{parent_id: _} = task} -> Map.take(task, [:parent_id, :started_at, :result])
      _ -> nil
    end
  end

  @doc "The id of the project a chat belongs to, or `nil` (STORE-19, PROJ-9)."
  @spec load_project(binary()) :: binary() | nil
  def load_project(id) do
    with %{project_id: project_id} <- load_meta(id),
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
    case load_meta(id) do
      %{compaction: %{} = compaction} -> compaction
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
    case load_meta(id) do
      %{turn: %{id: _} = turn} -> turn
      _ -> nil
    end
  end

  @doc "Saved conversations, most recently started first (STORE-12)."
  def list(limit \\ 50), do: all_entries() |> Enum.take(limit)

  @doc """
  The chats a restart cut a turn short in (STORE-39, RESUME-1): the listed
  entries (STORE-12, STORE-31) of every saved chat that still holds a turn
  record (STORE-30) while no session of it runs, newest first. Every saved chat
  is read, not only one page of `list/1` (STORE-12); an id that isn't valid
  (STORE-4) and a chat whose file can't be read are skipped.
  """
  @spec interrupted() :: [map()]
  def interrupted do
    all_entries()
    |> Enum.filter(&(valid_id?(&1.id) and Map.get(&1, :interrupted, false)))
  end

  @doc """
  One chat's listed entry (STORE-36) — the same fields `list/1` gives it,
  derived the same way — without reading the other chats' files, or `nil` when
  the id is invalid (STORE-4) or has no saved chat (STORE-24).
  """
  @spec entry(binary()) :: map() | nil
  def entry(id) do
    if valid_id?(id) and File.exists?(path(id)), do: listed(id <> ".term"), else: nil
  end

  @doc """
  The chat to resume when the user opens the chat list (STORE-29, UI-77): the most
  recently started chat (STORE-12) that isn't a task chat (STORE-17 — one
  started by `spawn_task` carries its `parent_id`) and isn't done (STORE-35,
  DONE-10), as a listed entry, or `nil` when there is none. Every saved chat is
  considered, not only the first page of `list/1`.
  """
  @spec latest() :: map() | nil
  def latest do
    all_entries()
    |> Enum.find(fn entry ->
      valid_id?(entry.id) and Map.get(entry, :parent_id) == nil and
        Map.get(entry, :done) != true
    end)
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

  # STORE-45: a chat whose file is gone by the time it is read is not listed,
  # and its cache entry goes with the rest of the files no longer there.
  defp all_entries do
    case File.ls(dir()) do
      {:ok, files} ->
        files = Enum.filter(files, &String.ends_with?(&1, ".term"))
        Cache.keep_only(MapSet.new(files, &Path.rootname/1))

        files
        |> Enum.map(&listed/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&DateTime.to_unix(&1.created_at, :microsecond), :desc)

      {:error, _} ->
        []
    end
  end

  # A file's listed entry: the saved fields, plus the title and description the
  # chat list shows (STORE-10, STORE-33, STORE-35) and what a sub-task chat adds
  # to them (STORE-17), or `nil` when the file is gone. A corrupt or unreadable
  # file is listed as a chat with nothing saved, as it always was.
  defp listed(file) do
    id = Path.rootname(file)

    with %{} = record <- record(id) do
      meta = if is_map(record.meta), do: record.meta, else: %{}
      mtime = DateTime.from_unix!(record.mtime)

      %{
        id: id,
        project_id: Map.get(meta, :project_id),
        # STORE-31, STORE-45: a chat that still holds a turn record (STORE-30)
        # while no session for it runs was interrupted by a restart (INTR-2).
        # Running state, so worked out here at every listing, never cached.
        interrupted: not is_nil(Map.get(meta, :turn)) and not Elia.Agent.live?(id),
        # STORE-33, TITLE-1: the chat's own title when it has one (STORE-32),
        # else the derivation from its first user message (STORE-7). The
        # description is that derivation either way (STORE-10), so hovering a
        # row still shows what was asked.
        title: shape_title(Map.get(meta, :title)) || record.title,
        description: record.description,
        # STORE-35, DONE-1: whether the chat is marked done, a boolean like
        # STORE-31's `interrupted`, so a chat nobody marked reads as open.
        done: Map.get(meta, :done) == true,
        created_at: Map.get(meta, :created_at) || mtime,
        updated_at: Map.get(meta, :updated_at) || mtime
      }
      |> put_task(Map.get(meta, :task))
    end
  end

  # STORE-17: a sub-task chat is listed as the ordinary chat it is, with the
  # parent it belongs to, so the list nests it (UI-45). Its title is its own
  # (STORE-33, TITLE-3) and its status the status any chat's is (STORE-31), so
  # it carries neither a task title nor a task status of its own.
  defp put_task(entry, %{parent_id: parent_id}),
    do: Map.put(entry, :parent_id, parent_id)

  defp put_task(entry, _task), do: entry

  # STORE-45: what the store knows of a chat's file without its messages — the
  # saved keys other than `messages` (`:corrupt` for a file that doesn't decode
  # to a chat), the title and description derived from the messages, and the
  # modification time listing falls back on — or `nil` when there is no file.
  # It is decoded only when the file's identity differs from the cached one.
  defp record(id) do
    path = path(id)

    case stat(id) do
      nil ->
        nil

      {_inode, _size, mtime} = identity ->
        Cache.fetch(id, identity) || decode_record(id, path, identity, mtime)
    end
  end

  # STORE-45: a chat's file identity, which the cache and SEARCH-4's index key
  # on — the inode, size and modification time a stat gives, in POSIX time — or
  # `nil` when there is no file.
  defp stat(id) do
    case File.stat(path(id), time: :posix) do
      {:ok, %File.Stat{inode: inode, size: size, mtime: mtime}} -> {inode, size, mtime}
      {:error, _} -> nil
    end
  end

  defp decode_record(id, path, identity, mtime) do
    :telemetry.execute([:elia, :store, :decode], %{count: 1}, %{id: id})

    record =
      case File.read(path) do
        {:ok, data} ->
          # STORE-48, STORE-49: a decodable term that isn't a chat is a corrupt
          # file like one that doesn't decode at all, so it is listed as a chat
          # with nothing saved rather than taking the listing down with it.
          case saved_chat(data, id) do
            {:ok, chat} ->
              {messages, meta} = Map.pop(chat, :messages, [])
              %{meta: meta, title: title(messages), description: title(messages, 1000)}

            :error ->
              corrupt()
          end

        # Gone between the stat and the read.
        {:error, :enoent} ->
          nil

        {:error, _} ->
          corrupt()
      end

    if record do
      record = Map.put(record, :mtime, mtime)
      Cache.put(id, identity, record)
      record
    end
  end

  defp corrupt, do: %{meta: :corrupt, title: title([]), description: title([], 1000)}

  # The start date of an already saved chat, or `nil` (STORE-11): its own, or
  # for a file saved before there was one, its modification time.
  defp created_at(id) do
    case record(id) do
      %{meta: %{created_at: %DateTime{} = at}} -> at
      %{meta: %{}, mtime: mtime} -> DateTime.from_unix!(mtime)
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
  Deletes a saved chat and nothing else. A chat that has no saved file yet is
  deleted too (STORE-23). Only that chat goes: a parent's task chats, and a task
  chat's parent, are left saved (UI-66), and so is a worktree a chat made for
  itself (DEPLOY-28, DEPLOY-10) — the harness removes no tree of a chat's. Its
  step records go too, so no `.timing` file outlives its chat (TIME-10).
  """
  @spec delete(binary()) :: :ok | {:error, term()}
  def delete(id) do
    if valid_id?(id) do
      Elia.StepTiming.delete(id)

      # STORE-45, SEARCH-4: the entry goes now, not at the next listing, and so
      # does the index's, not at the next search.
      Cache.drop(id)
      Index.drop(id)

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

  @doc """
  Display title for a conversation: its first user message, cut to `max`
  characters.

  UPLOAD-14: a message whose files are all it carries (UPLOAD-5) says nothing to
  name the chat after, so the title is the first message the user *wrote* — one
  that has text of its own, without UPLOAD-10's line of paths (UPLOAD-12) — and
  `"New chat"` while they have written none.
  """
  def title(messages, max \\ 60) do
    case Enum.find(messages, &title_message?/1) do
      nil -> "New chat"
      message -> message |> Message.user_text() |> String.slice(0, max)
    end
  end

  defp title_message?(%Message{role: :user} = message) do
    not Map.get(message.meta, :harness, false) and
      String.trim(Message.user_text(message)) != ""
  end

  defp title_message?(_message), do: false

  defp ensure_app_loaded do
    unless :persistent_term.get({__MODULE__, :app_loaded}, false) do
      {:ok, modules} = :application.get_key(:elia, :modules)
      Code.ensure_all_loaded(modules)
      :persistent_term.put({__MODULE__, :app_loaded}, true)
    end
  end

  defp path(id), do: Path.join(dir(), id <> ".term")

  # STORE-48, STORE-49, STORE-51: the chat a saved file holds, or `:error`. A
  # file that doesn't decode and one that decodes to a term that isn't a chat
  # are both read as no chat at all (STORE-3, STORE-49); the second is a file
  # someone will want to know about, so it is reported once (STORE-51).
  defp saved_chat(data, id) do
    with {:ok, term} <- decode(data) do
      case chat(term) do
        {:ok, chat} ->
          {:ok, chat}

        {:error, why} ->
          Logger.warning(
            "Saved chat #{id} isn't a chat (#{why}), so it is read as a chat with no " <>
              "history; its file is left as it is."
          )

          :error
      end
    end
  end

  # STORE-48: whether a decoded term is a chat of the shape STORE-1's table
  # states, and otherwise why it isn't one (STORE-51). The messages are checked
  # only as far as this module reads them — the UTF-8 scrub (STORE-13) and the
  # title it derives from the first user message (STORE-7, STORE-10) — so a
  # provider's own block is kept exactly as it is (LLM-6).
  defp chat(%{version: 1} = chat) do
    cond do
      not is_list(chat[:messages]) -> {:error, "its messages aren't a list"}
      not Enum.all?(chat[:messages], &message?/1) -> {:error, "one of its messages isn't one"}
      not timestamp?(chat[:created_at]) -> {:error, "its created_at isn't a date and time"}
      not timestamp?(chat[:updated_at]) -> {:error, "its updated_at isn't a date and time"}
      true -> {:ok, chat}
    end
  end

  defp chat(%{}), do: {:error, "its version isn't 1"}
  defp chat(_term), do: {:error, "it isn't a map"}

  # STORE-48, LLM-5: a message of the three roles, whose blocks are maps and
  # whose text and tool results are the strings the scrub (STORE-13) and the
  # title (STORE-7) are read from.
  defp message?(%Message{role: role, content: content, meta: meta}) do
    role in [:user, :assistant, :tool] and is_list(content) and is_map(meta) and
      Enum.all?(content, &block?/1)
  end

  defp message?(_term), do: false

  defp block?(%{type: :text} = block), do: is_binary(Map.get(block, :text))
  defp block?(%{type: :reasoning} = block), do: is_binary(Map.get(block, :text))
  defp block?(%{type: :tool_result} = block), do: is_binary(Map.get(block, :content))
  defp block?(block), do: is_map(block)

  # STORE-11: a file saved before `created_at` existed carries none, and its
  # modification time is the start date it is read with.
  defp timestamp?(nil), do: true
  defp timestamp?(%DateTime{}), do: true
  defp timestamp?(_term), do: false

  # `:safe` refuses atoms that don't exist yet. In dev, modules load lazily,
  # so after a restart atoms like `:tool_call` may not exist until the code
  # that defines them is loaded; load it all first (STORE-3).
  defp decode(data) do
    ensure_app_loaded()
    {:ok, :erlang.binary_to_term(data, [:safe])}
  rescue
    ArgumentError -> :error
  end
end
