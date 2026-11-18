defmodule Elia.ChatIndexTest do
  # SEARCH-1 to SEARCH-6: the index the server keeps in memory over the saved
  # chats, and what a search decodes while it uses it.
  #
  # The index is one table for the whole VM and the store it is derived from is
  # shared state, so this test runs on its own (`async: false`) and points the
  # store at a data directory of its own (SUITE-10): what it saves, indexes and
  # decodes is only its own. The claims about decoding are counted — one
  # telemetry event per decode of a chat's file — rather than timed.
  use ExUnit.Case, async: false

  alias Elia.LLM.Message
  alias Elia.Skills.Chats
  alias Elia.Store
  alias Elia.Store.Index

  setup do
    data = Path.join(System.tmp_dir!(), "elia-index-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, data)

    test_pid = self()
    handler = "index-decodes-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:elia, :store, :decode],
      fn _event, _measure, %{id: id}, _ -> send(test_pid, {:decoded, id}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)

      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)

      File.rm_rf(data)
    end)

    :ok
  end

  ## Helpers

  defp save(messages, opts \\ []) do
    id = Elia.Agent.new_id()
    :ok = Store.save(id, messages, opts)
    id
  end

  # A word no other chat holds, so a search for it finds only this test's chat.
  defp unique(prefix), do: "#{prefix}-#{Elia.Agent.new_id()}"

  defp tool(name), do: Enum.find(Chats.tools(), &(&1.name == name))

  defp search(query, extra \\ %{}) do
    {:ok, json} =
      Elia.Tool.call(
        tool("search_chats"),
        Map.merge(%{"query" => query, "limit" => 100}, extra),
        %{}
      )

    Jason.decode!(json)
  end

  defp found(query), do: query |> search() |> Enum.map(& &1["id"]) |> Enum.uniq()

  # The messages of `id` a query matches, in the order they are reported.
  defp indexes(query, id), do: for(match <- search(query), match["id"] == id, do: match["index"])

  # A listing of every chat, which is what a search reads its candidates from,
  # and so what warms the cache of STORE-45 before a decode is counted.
  defp warm, do: Store.list(1_000)

  # How many times `id`'s file was decoded since the last call.
  defp decodes(id), do: count_decodes(id, 0)

  defp count_decodes(id, n) do
    receive do
      {:decoded, ^id} -> count_decodes(id, n + 1)
    after
      0 -> n
    end
  end

  ## The index (SEARCH-1 to SEARCH-3)

  # SEARCH-1: the server keeps an index in memory over the saved chats: for a
  # term, which saved chats hold it and in which of their messages.
  test "SEARCH-1 the index says which chat holds a term, and in which message" do
    token = unique("indexed")
    id = save([Message.user("nothing here"), Message.user("the #{token} is in this one")])

    # Nothing is indexed until a search needs it (SEARCH-5).
    assert Index.term(token) == []

    assert [%{"id" => ^id, "index" => 2}] = search(token)

    # The index is what answered, and it holds the term with the message it is
    # in — the second one, which is what a search reports.
    assert Index.term(token) == [{id, 2}]

    # A term no chat holds is in none of them.
    assert Index.term(unique("absent")) == []
  end

  # SEARCH-2: a chat's messages, its title and its description are indexed,
  # folded the way a query is folded, so a term is found whatever its case.
  test "SEARCH-2 the index is folded, and holds the title and the description" do
    titled = unique("Title")
    described = unique("Description")
    id = save([Message.user("the description is #{described}")], title: "A #{titled} title")

    assert [%{"id" => ^id, "index" => 1}] = search(titled)

    # The chat's own title is indexed as it is folded, and so is the description
    # derived from its first user message (STORE-10, STORE-33).
    entry = Index.fetch(id, Store.identity(id))
    assert entry.title == String.downcase("A #{titled} title")
    assert entry.description == String.downcase("the description is #{described}")

    # A term is folded too, so the same term is found in either case — in the
    # text of a message as in a title.
    in_message = save([Message.user("a message holding #{described}")], title: "Another chat")

    assert indexes(described, in_message) == [1]
    assert indexes(String.upcase(described), in_message) == [1]
  end

  # SEARCH-3: the index is derived from the saved chat files and nothing else —
  # it is in memory only, nothing about it is written to `.elia/`, and a restart
  # builds it again from the files.
  test "SEARCH-3 the index is in memory only, and is built again from the files" do
    token = unique("inmemory")
    id = save([Message.user("a chat holding #{token}")], title: "Kept in a file")

    path = Path.join(Store.dir(), id <> ".term")
    files = Store.dir() |> File.ls!() |> Enum.sort()
    bytes = File.read!(path)

    assert [%{"id" => ^id}] = search(token)

    # In memory: the index is a table of this VM (SEARCH-1) ...
    assert :ets.whereis(:elia_store_index) != :undefined
    # ... and nothing about it reached the disk: no file was added or changed,
    # and the chat's own file is as it was.
    assert Store.dir() |> File.ls!() |> Enum.sort() == files
    assert File.read!(path) == bytes

    # A restart keeps no index — there is nothing on disk to read one back from
    # — and the next search builds it again from the files.
    :ets.delete_all_objects(:elia_store_index)
    assert Index.term(token) == []
    assert [%{"id" => ^id}] = search(token)
    assert Index.term(token) == [{id, 1}]
  end

  # SEARCH-3: the index is in memory only, so a search that finds no index
  # builds one from the files rather than reading the chats itself — the case a
  # hot reload makes (a reload adds no child to a running tree, HOT-10).
  test "SEARCH-3 the index is made again wherever there is none" do
    token = unique("remade")
    id = save([Message.user("a chat holding #{token}")], title: "Made again")

    assert found(token) == [id]

    # The table gone is the index gone; the next search makes it again from the
    # files, as the restart in the test above did.
    :ets.delete(:elia_store_index)
    assert Index.term(token) == []
    assert found(token) == [id]
    assert Index.term(token) == [{id, 1}]

    # What made the table is the process that searched, and this test's own
    # process is about to go, so the application's is put back: the child that
    # owns it for the life of the node is restarted with no table of its own.
    :ets.delete(:elia_store_index)
    :ok = Supervisor.terminate_child(Elia.Supervisor, Index)
    {:ok, _pid} = Supervisor.restart_child(Elia.Supervisor, Index)
  end

  ## Following the files (SEARCH-4)

  # SEARCH-4: the index follows the files rather than its own copy of them — a
  # chat saved, replaced or deleted by this server, by another one or by an
  # outside process is indexed as it is now at the next search, without a
  # restart.
  test "SEARCH-4 a chat saved, replaced or deleted is indexed as it is now" do
    before = unique("before")
    id = save([Message.user("this chat said #{before}")], title: "Changing")

    assert found(before) == [id]

    # Another process saves it: the new file has a new identity, so the chat is
    # indexed again, and the term only the old text held is gone.
    after_save = unique("after")

    Task.async(fn -> Store.save(id, [Message.user("now it says #{after_save}")]) end)
    |> Task.await()

    assert found(before) == []
    assert found(after_save) == [id]

    # A file written outside the store — another OS process, say — is seen too.
    outside = unique("outside")
    write_outside(id, outside)

    assert found(after_save) == []
    assert found(outside) == [id]

    # A chat deleted is not a chat that holds a term any more.
    :ok = Store.delete(id)

    assert found(outside) == []
    assert Index.term(outside) == []
  end

  # A chat's file written outside `Elia.Store` — another OS process, say — by
  # renaming a new file into place, which is what every save does (STORE-2).
  defp write_outside(id, token) do
    path = Path.join(Store.dir(), id <> ".term")
    now = DateTime.utc_now()

    chat = %{
      version: 1,
      messages: [Message.user("written outside, holding #{token}")],
      title: "Outside",
      created_at: now,
      updated_at: now
    }

    File.write!(path <> ".outside", :erlang.term_to_binary(chat))
    File.rename!(path <> ".outside", path)
  end

  ## What a search decodes (SEARCH-5, SEARCH-6)

  # SEARCH-5: the index is built when a search first needs it — that build
  # decodes every saved chat's messages once — and a later search decodes no
  # chat it has already indexed whose file has not changed.
  test "SEARCH-5 the first search decodes every chat once, a later one no unchanged chat" do
    token = unique("built")
    absent = unique("absent")
    one = save([Message.user("holding #{token}")], title: "One")
    two = save([Message.user("holding nothing of it")], title: "Two")

    # A listing first, so the cache of STORE-45 (STORE-45) has decoded what it
    # holds and what is counted below is the search's own decodes.
    warm()
    decodes(one)
    decodes(two)

    # The first search builds the index: it decodes every chat the search
    # considers, once each.
    assert search(absent) == []
    assert decodes(one) == 1
    assert decodes(two) == 1

    # A later search decodes nothing at all: the index holds both chats, and
    # neither file has changed.
    assert search(absent) == []
    assert decodes(one) == 0
    assert decodes(two) == 0

    # SEARCH-6: a search that reports a match decodes the chats it reports from
    # — for the snippet — and no other.
    assert found(token) == [one]
    assert decodes(one) == 1
    assert decodes(two) == 0

    # A chat whose file has changed is decoded and indexed again at the next
    # search; one whose file has not is not (SEARCH-4).
    :ok = Store.save(two, [Message.user("holding nothing of it")], title: "Two again")
    warm()
    decodes(one)
    decodes(two)

    assert search(absent) == []
    assert decodes(one) == 0
    assert decodes(two) == 1
  end

  # SEARCH-6: a search decodes the chats it reports matches from — for the
  # snippet of SEARCH-10 — and no other: once the index is built, a query whose
  # terms match nothing decodes no chat's messages.
  test "SEARCH-6 a search decodes only the chats it reports matches from" do
    token = unique("reported")
    id = save([Message.user("a chat holding #{token}")], title: "Reported")
    other = save([Message.user("nothing to do with it")], title: "Other")

    # Building the index, and one search that matches so both are indexed.
    assert found(token) == [id]
    warm()
    decodes(id)
    decodes(other)

    # A query whose terms match nothing decodes no chat's messages at all.
    assert search(unique("nothing")) == []
    assert decodes(id) == 0
    assert decodes(other) == 0

    # One that matches decodes the chat it reports from, once, and no other.
    assert found(token) == [id]
    assert decodes(id) == 1
    assert decodes(other) == 0

    # The match a chat's title alone makes (SEARCH-8) decodes that chat too:
    # the snippet is the message's own text (SEARCH-10).
    titled = save([Message.user("no mention of the query here")], title: "A #{token} title")
    assert search(unique("still nothing")) == []
    warm()
    decodes(titled)

    assert found(token) |> Enum.sort() == Enum.sort([id, titled])
    assert decodes(titled) == 1
  end
end
