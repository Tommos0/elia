defmodule Elia.Store.Index do
  @moduledoc """
  An index in memory over the text of the saved chats (SEARCH-1 to SEARCH-6):
  for a term, which saved chats hold it and in which of their messages.

  The files stay the only record (SEARCH-3). The index is derived from them —
  `Elia.Store.list/1` says which chats there are and what they are called, and
  `Elia.Store.load/1` reads a chat's messages — and it is kept in a public ETS
  table, so a restart builds it again from the files and nothing is written for
  it anywhere.

  An entry is only used while the chat's file still has the identity it was
  indexed from: the inode, size and modification time the listing cache of
  STORE-45 keys on. Every save renames a new file into place (STORE-2), which
  changes the inode, so a chat saved, replaced or deleted by this server, by
  another one or by an outside process is decoded and indexed again at the next
  search (SEARCH-4) — when the index is built or brought up to date, which a
  search does for the chats it considers before it looks anything up (SEARCH-5).

  Without this process — a hot reload adds no child to a running tree (HOT-10)
  — the table is made by the process that first searches, so a search still
  finds what the files hold. That table goes when its maker does, and the next
  search builds the index again from the files; with this process running, the
  table is the application's and lasts as long as it does.
  """

  use GenServer

  alias Elia.LLM.Message

  @table :elia_store_index
  @table_opts [:named_table, :public, :set, read_concurrency: true]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Brings the index up to date with `entries` — the chats a search considers, as
  `Elia.Store.list/1` lists them, newest first.

  A chat whose file no longer has the identity it was indexed with is decoded
  and indexed again (SEARCH-4); one whose file is gone is dropped from the
  index, and so is any other entry whose file is gone, so a deleted chat is not
  a chat that holds a term any more.
  """
  @spec refresh([map()]) :: :ok
  def refresh(entries) do
    ensure_table()

    Enum.each(entries, fn entry ->
      case Elia.Store.identity(entry.id) do
        nil ->
          drop(entry.id)

        identity ->
          if is_nil(fetch(entry.id, identity)), do: put(entry.id, identity, build(entry))
      end
    end)

    prune(MapSet.new(entries, & &1.id))
  end

  # SEARCH-3: the whole index is this one table, so it is made on demand — the
  # process below owns it for the life of the node, and a hot reload, which adds
  # no child to a running tree (HOT-10), gets an index from the process that
  # first searches instead. A table its maker dies with takes the index with it,
  # and the next search builds it again from the files.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, @table_opts)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The saved chats that hold `term`, as `{chat id, message index}` pairs — one
  per message that holds it (SEARCH-1). `term` is folded here (SEARCH-2), so
  either case finds the same messages.

  The messages of a chat that holds no term are not read for this: the entry the
  index keeps is what answers.
  """
  @spec term(binary()) :: [{binary(), pos_integer()}]
  def term(term) do
    term = fold(term)

    # `:ets.foldl/3` is OTP's own, `(function, acc, table)`: the entries are
    # streamed through it, so looking a term up doesn't copy the whole index.
    :ets.foldl(
      fn {id, _identity, entry}, found ->
        Enum.reduce(entry.tokens, found, fn {token, indexes}, found ->
          if String.contains?(token, term),
            do: Enum.reduce(indexes, found, &MapSet.put(&2, {id, &1})),
            else: found
        end)
      end,
      MapSet.new(),
      @table
    )
    |> Enum.sort()
  rescue
    ArgumentError -> []
  end

  @doc """
  The entry for `id` when its file still has `identity`, else `nil` — the entry
  a search reads: the chat's folded `title` and `description`, how many
  `messages` it holds and its `tokens`.
  """
  @spec fetch(binary(), term()) :: map() | nil
  def fetch(id, identity) do
    case :ets.lookup(@table, id) do
      [{^id, ^identity, entry}] -> entry
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec put(binary(), term(), map()) :: :ok
  def put(id, identity, entry) do
    :ets.insert(@table, {id, identity, entry})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec drop(binary()) :: :ok
  def drop(id) do
    :ets.delete(@table, id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  What a term is searched in (SEARCH-7): the text of a message's text blocks,
  the content of its tool results and the JSON of its tool calls' inputs, each
  as it was saved — `nil` for a block that holds nothing to search.
  """
  @spec searchable_texts(Message.t() | term()) :: [binary()]
  def searchable_texts(%Message{content: content}) when is_list(content) do
    content |> Enum.map(&searchable_text/1) |> Enum.reject(&is_nil/1)
  end

  def searchable_texts(_message), do: []

  defp searchable_text(%{type: :text, text: text}) when is_binary(text), do: text

  defp searchable_text(%{type: :tool_result, content: content}) when is_binary(content),
    do: content

  defp searchable_text(%{type: :tool_call, input: input}), do: Jason.encode!(input)
  defp searchable_text(_block), do: nil

  # SEARCH-1, SEARCH-2: what one chat contributes — its folded title and
  # description, how many messages it holds, and a term per folded token of its
  # messages with the message indexes holding it.
  defp build(entry) do
    messages = Elia.Store.load(entry.id)

    %{
      title: fold(Map.get(entry, :title) || ""),
      description: fold(Map.get(entry, :description) || ""),
      messages: length(messages),
      tokens:
        messages
        |> Enum.with_index(1)
        |> Enum.reduce(%{}, fn {message, index}, tokens ->
          Enum.reduce(searchable_texts(message), tokens, fn text, tokens ->
            add_tokens(tokens, text, index)
          end)
        end)
    }
  end

  # A term is a substring of the text it is in, and a query is split on
  # whitespace, so a term with no whitespace in it always lies inside one of
  # these runs: looking a term up is looking at the tokens that contain it.
  defp add_tokens(tokens, text, index) do
    text
    |> fold()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(tokens, fn token, tokens ->
      Map.update(tokens, token, MapSet.new([index]), &MapSet.put(&1, index))
    end)
  end

  # SEARCH-4: an entry whose file is gone is no longer a chat that holds
  # anything. The chats of `ids` were just refreshed, so they are not looked at
  # again.
  defp prune(ids) do
    for id <- :ets.select(@table, [{{:"$1", :_, :_}, [], [:"$1"]}]),
        not MapSet.member?(ids, id),
        Elia.Store.identity(id) == nil,
        do: :ets.delete(@table, id)

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp fold(text), do: String.downcase(text)

  @impl true
  def init(nil) do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, @table_opts)
    {:ok, nil}
  end
end
