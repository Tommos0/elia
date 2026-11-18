defmodule Elia.Skills.ChatsTest do
  # The store is shared state (one sessions dir per run), and these tests save
  # chats of their own to read, so they don't run inside one another.
  use ExUnit.Case, async: false

  alias Elia.LLM.Message
  alias Elia.Skills.Chats
  alias Elia.Store

  defp tool(name), do: Enum.find(Chats.tools(), &(&1.name == name))

  # HIST-2: a call runs in a chat, which is what the `children` filter reads
  # (`ctx[:session_id]`, STORE-18); a case that doesn't care runs with none.
  defp call(name, input, ctx \\ %{}), do: Elia.Tool.call(tool(name), input, ctx)

  # A chat of this test's own, removed when it ends.
  defp save(messages, opts \\ []) do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, messages, opts)
    id
  end

  # A word no other test can match.
  defp unique(prefix), do: "#{prefix}-#{Elia.Agent.new_id()}"

  defp listed(id) do
    {:ok, json} = call("list_chats", %{"limit" => 100})
    Enum.find(Jason.decode!(json), &(&1["id"] == id))
  end

  # HIST-1: built in, for every project and in a sub-task, and its instructions
  # say what it reads and where the limit is.
  test "HIST-1 the chats skill is built in and tells the model what it can read" do
    assert Chats.name() == "chats"
    assert Chats.description() =~ "earlier chats"
    assert Chats.tools() |> Enum.map(& &1.name) == ~w(list_chats read_chat search_chats)
    assert Chats in Application.get_env(:elia, Elia.Skills)[:builtin]

    instructions = Chats.instructions()

    for name <- ~w(list_chats read_chat search_chats) do
      assert instructions =~ "`#{name}`"
      assert tool(name).description =~ "chat"
    end

    # What it reads: Elia's own saved chats, by the id in a chat's URL, through
    # the harness rather than a command or the file tools, so a jailed chat has
    # it too, and it is read-only.
    assert instructions =~ "/c/<id>"
    assert instructions =~ "jail"
    assert instructions =~ "saved chats through the harness"
    assert instructions =~ "only read"
    assert instructions =~ "asks for approval"
    assert instructions =~ "last saved"

    # SUBTASK-1: a sub-task's skills are the registry's without `tasks`, so it
    # has the three too.
    assert "chats" in Enum.map(Elia.Skills.for_child(), & &1.name)
  end

  # HIST-2: newest first, the fields a decision needs, and the filters.
  test "HIST-2 list_chats lists chats newest first, with query, project and limit" do
    older = save([Message.user("the older one")], title: "Older chat")
    newer = save([Message.user("the newer one")], title: "Newer chat")
    project = save([Message.user("of a project")], project: "proj-#{unique("p")}")

    ids =
      list(%{"limit" => 100})
      |> Enum.map(& &1["id"])
      |> Enum.filter(&(&1 in [older, newer, project]))

    assert ids == [project, newer, older]

    assert %{
             "id" => ^newer,
             "title" => "Newer chat",
             "project" => nil,
             "status" => "open",
             "messages" => 1
           } = listed(newer)

    assert {:ok, _, _} = DateTime.from_iso8601(listed(newer)["created_at"])
    assert {:ok, _, _} = DateTime.from_iso8601(listed(newer)["updated_at"])

    # A query matches the title or the description (the first user message).
    assert Enum.map(matches("newer c"), & &1["id"]) == [newer]
    assert Enum.map(matches("the older one"), & &1["id"]) == [older]

    # A project id keeps just that project's chats.
    assert Enum.map(list(%{"project" => listed(project)["project"]}), & &1["id"]) == [project]

    # A limit returns at most that many, newest first.
    assert length(list(%{"limit" => 2})) == 2

    # Nothing matching is not an error.
    assert {:ok, "[]"} = call("list_chats", %{"query" => unique("absent")})
  end

  defp matches(query), do: list(%{"query" => query, "limit" => 100})

  defp list(input) do
    {:ok, json} = call("list_chats", input)
    Jason.decode!(json)
  end

  # HIST-2: the `children` filter — this chat's own sub-tasks with `true`,
  # those together with their own children with `"all"`, nothing filtered by
  # parent without it — and the `parent` every listed chat carries (STORE-17,
  # STORE-18).
  test "HIST-2 list_chats filters by parent with children, and lists parent" do
    parent = save([Message.user("the parent")], title: "A parent")
    first = child_of(parent, "First child")
    second = child_of(parent, "Second child")
    grandchild = child_of(first, "Grandchild")
    unrelated = save([Message.user("nothing to do with the task")], title: "Unrelated")

    # `true` keeps the chats this one started and nothing else.
    assert group_of(parent, true) == Enum.sort([first, second])

    # `"all"` keeps those together with their own children.
    assert group_of(parent, "all") == Enum.sort([first, second, grandchild])

    # Absent, and `false`, filter nothing by parent: the listing is every chat,
    # as it was before the filter existed.
    assert unrelated in ids(%{"limit" => 100})
    assert unrelated in ids(%{"children" => false, "limit" => 100})

    # A chat with no children of its own keeps nothing with `true` ...
    assert group_of(unrelated, true) == []

    # ... while a chat that is itself a sub-task has no children of its own, so
    # `true` keeps what it started and `"all"` the same, with nothing below it
    # (SUBTASK-1: depth is one).
    assert group_of(first, "all") == [grandchild]
    assert group_of(first, true) == [grandchild]

    # A tool context that names no chat has no sub-tasks to keep, so the filter
    # keeps none of them.
    assert group_of(nil, true) == []
    assert group_of(nil, "all") == []

    # HIST-2, STORE-17: an entry's `parent` is the chat that spawned it, or
    # null for a chat nothing spawned.
    assert listed(first)["parent"] == parent
    assert listed(grandchild)["parent"] == first
    assert listed(parent)["parent"] == nil
  end

  # A chat started by `parent`, as a spawn starts one (STORE-16).
  defp child_of(parent, title) do
    save([Message.user("a brief for #{title}")],
      title: title,
      task: %{parent_id: parent, started_at: DateTime.utc_now()}
    )
  end

  defp group_of(session_id, children) do
    ctx = %{session_id: session_id}
    {:ok, json} = call("list_chats", %{"children" => children, "limit" => 100}, ctx)
    json |> Jason.decode!() |> Enum.map(& &1["id"]) |> Enum.sort()
  end

  defp ids(input), do: list(input) |> Enum.map(& &1["id"])

  # HIST-3: the status a chat as a whole is in, from its saved file.
  test "HIST-3 a listed chat's status is open, done, interrupted or working" do
    open = save([Message.user("an open chat")], title: "Status open")

    done = save([Message.user("a done chat")], title: "Status done", done: true)

    interrupted =
      save([Message.user("a cut short chat")],
        title: "Status interrupted",
        turn: %{id: "turn-1", started_at: DateTime.utc_now()}
      )

    # STORE-16, STORE-17, UI-46: a sub-task chat has no status of its own — it
    # reads as the chat it is, under its own title (STORE-32, TITLE-3).
    task =
      save([Message.user("preamble")],
        title: "A task chat",
        task: %{parent_id: "someone", started_at: DateTime.utc_now()}
      )

    working = save([Message.user("a chat being worked on")], title: "Status working")
    Registry.register(Elia.Agent.Registry, working, :running)

    statuses =
      Map.new(list(%{"limit" => 100}), &{&1["id"], &1["status"]})

    assert statuses[open] == "open"
    assert statuses[done] == "done"
    assert statuses[interrupted] == "interrupted"
    assert statuses[task] == "open"
    assert listed(task)["title"] == "A task chat"
    assert statuses[working] == "working"
  end

  # HIST-4, HIST-5, HIST-6: the header, and one line per message with its tool
  # calls and results.
  test "HIST-4 read_chat reads a chat by id" do
    id =
      save(
        [
          Message.user("What is in store.ex?"),
          %Message{
            role: :assistant,
            content: [
              Message.text("Looking."),
              %{
                type: :tool_call,
                id: "c1",
                name: "read_file",
                input: %{"path" => "lib/elia/store.ex"}
              }
            ]
          },
          %Message{role: :tool, content: [Message.tool_result("c1", "[exit: 0] defmodule")]},
          %Message{role: :tool, content: [Message.tool_result("c2", "no such file", true)]},
          Message.harness("a notice"),
          %Message{role: :assistant, content: [%{type: :reasoning, text: "hidden thinking"}]}
        ],
        title: "Store questions"
      )

    assert {:ok, text} = call("read_chat", %{"id" => id})

    assert text =~ "# Store questions (#{id})"
    assert text =~ "project none, open, 6 messages"
    assert text =~ "[messages 1-6 of 6]"
    assert text =~ "[1] user: What is in store.ex?"
    assert text =~ "[2] assistant: Looking."
    assert text =~ ~s(  → read_file {"path":"lib/elia/store.ex"})
    assert text =~ "[3] tool: (no text)"
    assert text =~ "  ← [exit: 0] defmodule"
    assert text =~ "  ← [error] no such file"
    # STORE-7, UI-9: a message the harness wrote is marked as one.
    assert text =~ "[5] user (harness): [Elia harness] a notice"
    # UI-29: reasoning is not the conversation.
    assert text =~ "[6] assistant: (no text)"
    refute text =~ "hidden thinking"
    # No paging note while the whole chat is shown.
    refute text =~ "more messages"
  end

  # HIST-6: a long message and a long tool result are cut, with the amount that
  # was left out.
  test "HIST-6 a message's text and a tool result are cut" do
    id =
      save([
        Message.user(String.duplicate("a", 2_100)),
        %Message{role: :tool, content: [Message.tool_result("c", String.duplicate("b", 1_050))]}
      ])

    assert {:ok, text} = call("read_chat", %{"id" => id})

    assert text =~ "…[+100 more characters]"
    assert text =~ "…[+50 more characters]"
    # The rest of a long message is left out, not carried along.
    assert text =~ "[1] user: #{String.duplicate("a", 2_000)}…"
    refute String.contains?(text, String.duplicate("a", 2_001))
  end

  # HIST-4, HIST-7: paging, and what a wrong offset says.
  test "HIST-7 read_chat pages through a long chat" do
    id = save(for n <- 1..5, do: Message.user("message #{n}"))

    assert {:ok, first} = call("read_chat", %{"id" => id, "limit" => 2})
    assert first =~ "[messages 1-2 of 5]"
    assert first =~ "[1] user: message 1"
    assert first =~ "[2] user: message 2"
    refute first =~ "[3] user"
    assert first =~ "[+3 more messages: read again with offset=3]"

    assert {:ok, next} = call("read_chat", %{"id" => id, "offset" => 3, "limit" => 2})
    assert next =~ "[messages 3-4 of 5]"
    assert next =~ "[3] user: message 3"
    assert next =~ "[+1 more messages: read again with offset=5]"

    # The last page carries no note.
    assert {:ok, last} = call("read_chat", %{"id" => id, "offset" => 5})
    assert last =~ "[messages 5-5 of 5]"
    refute last =~ "more messages"

    # A limit above the cap is the cap, and doesn't break the reading.
    assert {:ok, all} = call("read_chat", %{"id" => id, "limit" => 5_000})
    assert all =~ "[messages 1-5 of 5]"

    assert {:error, message} = call("read_chat", %{"id" => id, "offset" => 9})
    assert message =~ "not a message of this chat: it holds 5 messages (1-5)"
    assert {:error, _} = call("read_chat", %{"id" => id, "offset" => 0})

    # A chat with no messages reads as its header alone.
    empty = save([], title: "Nothing said")
    assert {:ok, text} = call("read_chat", %{"id" => empty})
    assert text =~ "# Nothing said (#{empty})"
    assert text =~ "[messages 0-0 of 0]"
  end

  # HIST-4, HIST-8: reading by a title, and what the tools say when they can't.
  test "HIST-8 read_chat takes an id or one chat's title, and reports the rest" do
    assert {:error, message} = call("read_chat", %{})
    assert message =~ "Give the chat's `id`"

    assert {:error, message} = call("read_chat", %{"id" => "../bad"})
    assert message =~ "not a valid chat id"

    assert {:error, message} = call("read_chat", %{"id" => Elia.Agent.new_id()})
    assert message =~ "No saved chat has the id"

    token = unique("distinctive")
    id = save([Message.user("hi")], title: "A #{token} title")

    assert {:ok, text} = call("read_chat", %{"query" => token})
    assert text =~ "# A #{token} title (#{id})"

    assert {:error, message} = call("read_chat", %{"query" => unique("nothing")})
    assert message =~ "No saved chat's title matches"

    # Several chats matching: name them, so the model can pick one by id.
    other = save([Message.user("hi")], title: "A #{token} other title")
    assert {:error, message} = call("read_chat", %{"query" => token})
    assert message =~ "2 chats' titles match"
    assert message =~ id
    assert message =~ other
  end

  # SEARCH-7: the terms a query is split into, found in a message's text, a
  # tool result's content and a tool call's input JSON.
  test "SEARCH-7 search_chats searches the terms a query is split into" do
    token = unique("seek")

    id =
      save(
        [
          Message.user("nothing here"),
          %Message{role: :assistant, content: [Message.text("the answer has #{token} inside")]},
          %Message{
            role: :tool,
            content: [Message.tool_result("c", "a result mentioning #{token}")]
          },
          %Message{
            role: :assistant,
            content: [
              %{type: :tool_call, id: "c2", name: "shell", input: %{"command" => "echo #{token}"}}
            ]
          }
        ],
        title: "Searchable chat"
      )

    matches = search(String.upcase(token))

    assert [%{"index" => 2, "role" => "assistant"} = first, second, third] =
             Enum.filter(matches, &(&1["id"] == id))

    assert first["title"] == "Searchable chat"
    assert first["snippet"] =~ token
    assert second["index"] == 3
    assert second["role"] == "tool"
    assert third["index"] == 4
    assert third["role"] == "assistant"

    # A term is a substring of the text, not a word of it: part of one finds
    # every message holding it.
    assert Enum.map(search(String.slice(token, 3, 8)), & &1["id"]) == [id, id, id]

    # SEARCH-7: the terms of a query are its whitespace-separated parts, and
    # every one of them has to be found (SEARCH-8): a second term that is not
    # there leaves nothing.
    assert [%{"id" => ^id, "index" => 2}] = search("the #{token}")
    assert search("#{token} #{unique("absent")}") == []
  end

  # SEARCH-8: a message matches when every term is in it, and a chat whose
  # title holds them all matches even when none of its messages does.
  test "SEARCH-8 every term has to be in the message, and a title can match alone" do
    one = unique("alpha")
    two = unique("beta")

    apart =
      save([Message.user("this message holds #{one}"), Message.user("this one holds #{two}")],
        title: "Both terms, each in a message of its own"
      )

    # No message holds both terms, so neither does the chat ...
    assert search("#{one} #{two}") == []

    # ... while each term on its own finds the message holding it.
    assert indexes(one, apart) == [1]
    assert indexes(two, apart) == [2]

    # A message holding both is what the query finds.
    together = save([Message.user("a message holding #{one} and #{two}")], title: "Both together")
    assert indexes("#{one} #{two}", together) == [1]

    # SEARCH-8: a chat whose title holds every term whose messages do not match
    # contributes one match of its own — its first message.
    titled =
      save([Message.user("nothing of the query in this message")], title: "A #{one} #{two} title")

    assert [{^titled, 1}] =
             for(
               match <- search("#{one} #{two}", %{"limit" => 100}),
               match["id"] == titled,
               do: {match["id"], match["index"]}
             )
  end

  # SEARCH-9: a chat whose title holds every term first, then the newer chat,
  # then the earlier message — and `limit` is that many from the front.
  test "SEARCH-9 matches come title-matching chats first, then newest, then earliest" do
    token = unique("order")

    # The oldest of the three, and the only one whose title holds the term: an
    # ordinary title of this chat's own, so nothing else about it is what puts
    # it first.
    title_only =
      save([Message.user("nothing here")], title: "A chat about #{token} and nothing else")

    # Two messages holding it each, so their order within the chat is visible,
    # and a title that does not hold the term.
    two =
      save([Message.user("#{token} in the first"), Message.user("#{token} in the second")],
        title: "Two messages"
      )

    # The newest of the three.
    newest = save([Message.user("and #{token} in the newest chat")], title: "The newest chat")

    assert Enum.map(search(token), &{&1["id"], &1["index"]}) == [
             {title_only, 1},
             {newest, 1},
             {two, 1},
             {two, 2}
           ]

    assert Enum.map(search(token, %{"limit" => 2}), & &1["id"]) == [title_only, newest]
  end

  # SEARCH-10: a snippet is the text around the match, cut to 200 characters;
  # a short message is carried whole, and the match a title alone makes shows
  # its message from the start.
  test "SEARCH-10 a snippet is the text around the match, cut to 200 characters" do
    token = unique("snippet")
    id = save([Message.user(String.duplicate("x", 300) <> token <> String.duplicate("y", 300))])

    assert [%{"id" => ^id, "role" => "user", "snippet" => snippet}] = search(token)

    assert snippet =~ token
    assert String.starts_with?(snippet, "…#{String.duplicate("x", 59)}")
    assert String.ends_with?(snippet, "…")
    # The window is 200 characters plus the two ellipses.
    assert String.length(snippet) == 202

    # SEARCH-8's title match: the message from its start, uncut and without an
    # ellipsis, since it is shorter than a window.
    titled =
      save([Message.user("a first message holding nothing of it")], title: "A #{token} title")

    assert [%{"id" => ^titled, "snippet" => from_start}] =
             Enum.filter(search(token), &(&1["id"] == titled))

    assert from_start == "a first message holding nothing of it"
  end

  # SEARCH-11: `query` is required and non-blank, and `limit` is 20 by default
  # and at most 100, clamped rather than refused.
  test "SEARCH-11 a blank query is an error, and the limit is clamped" do
    assert {:error, message} = call("search_chats", %{"query" => "   "})
    assert message =~ "non-blank"
    assert {:error, message} = Elia.Tool.validate(tool("search_chats"), %{})
    assert message =~ "query is required"

    # Nothing found is not an error.
    assert {:ok, "[]"} = call("search_chats", %{"query" => unique("absent")})

    token = unique("limited")
    id = save(for n <- 1..21, do: Message.user("#{token} number #{n}"))

    # A search with no limit returns the default, 20, from the front of the
    # order (SEARCH-9) — the newer chat's 21 matches.
    assert {:ok, json} = call("search_chats", %{"query" => token})
    assert json |> Jason.decode!() |> length() == 20

    # A limit above the cap is the cap, and one below the smallest sensible
    # value is that value rather than an error.
    assert length(search(token, %{"limit" => 100_000})) == 21
    assert length(search(token, %{"limit" => -5})) == 1
    assert Enum.map(search(token, %{"limit" => 1}), & &1["id"]) == [id]
  end

  # SEARCH-12: the skill's instructions say how a query is read.
  test "SEARCH-12 the chats skill's instructions say how a query is read" do
    instructions = Chats.instructions()

    assert instructions =~ "search_chats"
    assert instructions =~ "terms split on whitespace"
    assert instructions =~ "every one of them has to be there"
    assert instructions =~ "title"

    assert tool("search_chats").description =~ "terms"
    assert tool("search_chats").description =~ "title"
  end

  defp search(query, extra \\ %{}) do
    {:ok, json} = call("search_chats", Map.merge(%{"query" => query, "limit" => 100}, extra))
    Jason.decode!(json)
  end

  # The messages of `id` a query matches, in the order they are reported.
  defp indexes(query, id), do: for(match <- search(query), match["id"] == id, do: match["index"])

  # HIST-10: reading changes nothing and never needs approval.
  test "HIST-10 the tools never write and never need approval" do
    id = save([Message.user("a chat to read")], title: "Read only")
    path = Path.join(Store.dir(), id <> ".term")
    before = File.read!(path)

    for name <- ~w(list_chats read_chat search_chats) do
      assert Elia.Tool.approval(tool(name), %{}, %{}) == :never
    end

    assert {:ok, _} = call("list_chats", %{})
    assert {:ok, _} = call("read_chat", %{"id" => id})
    assert {:ok, _} = call("search_chats", %{"query" => "a chat to read"})

    # Reading a chat starts no session for it: it is not resumed (SESS-14).
    refute Elia.Agent.live?(id)
    # And the saved chat is exactly as it was.
    assert File.read!(path) == before
  end
end
