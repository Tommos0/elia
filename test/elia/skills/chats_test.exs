defmodule Elia.Skills.ChatsTest do
  # The store is shared state (one sessions dir per run), and these tests save
  # chats of their own to read, so they don't run inside one another.
  use ExUnit.Case, async: false

  alias Elia.LLM.Message
  alias Elia.Skills.Chats
  alias Elia.Store

  defp tool(name), do: Enum.find(Chats.tools(), &(&1.name == name))
  defp call(name, input), do: Elia.Tool.call(tool(name), input, %{})

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
    assert "chats" in Enum.map(Elia.Skills.Tasks.child_skills(), & &1.name)
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

  # HIST-3: the status a chat as a whole is in, from its saved file.
  test "HIST-3 a listed chat's status is open, done, interrupted, a task's or working" do
    open = save([Message.user("an open chat")], title: "Status open")

    done = save([Message.user("a done chat")], title: "Status done", done: true)

    interrupted =
      save([Message.user("a cut short chat")],
        title: "Status interrupted",
        turn: %{id: "turn-1", started_at: DateTime.utc_now()}
      )

    task =
      save([Message.user("preamble")],
        task: %{parent_id: "someone", title: "Status blocked task", status: "blocked"}
      )

    working = save([Message.user("a chat being worked on")], title: "Status working")
    Registry.register(Elia.Agent.Registry, working, :running)

    statuses =
      Map.new(list(%{"limit" => 100}), &{&1["id"], &1["status"]})

    assert statuses[open] == "open"
    assert statuses[done] == "done"
    assert statuses[interrupted] == "interrupted"
    # A task chat keeps its task's status, and its task's title (STORE-17).
    assert statuses[task] == "blocked"
    assert listed(task)["title"] == "Status blocked task"
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

  # HIST-9: a phrase found across the chats, in text, tool results and tool
  # calls.
  test "HIST-9 search_chats finds a phrase across the chats" do
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

    # Nothing found is not an error.
    assert {:ok, "[]"} = call("search_chats", %{"query" => unique("absent")})

    # A blank query says so, and the schema refuses a missing one.
    assert {:error, message} = call("search_chats", %{"query" => "   "})
    assert message =~ "non-blank"
    assert {:error, message} = Elia.Tool.validate(tool("search_chats"), %{})
    assert message =~ "query is required"

    # The cap: at most `limit` matches, from the first chat that has them.
    assert [%{"id" => ^id}] = search(token, %{"limit" => 1})
  end

  # HIST-9: a snippet is the text around the match, cut with an ellipsis.
  test "HIST-9 a snippet is cut around the match" do
    token = unique("snippet")
    id = save([Message.user(String.duplicate("x", 300) <> token <> String.duplicate("y", 300))])

    assert [%{"id" => ^id, "role" => "user", "snippet" => snippet}] = search(token)

    assert snippet =~ token
    assert String.starts_with?(snippet, "…#{String.duplicate("x", 59)}")
    assert String.ends_with?(snippet, "…")
    # The window is 200 characters plus the two ellipses.
    assert String.length(snippet) == 202
  end

  defp search(query, extra \\ %{}) do
    {:ok, json} = call("search_chats", Map.merge(%{"query" => query, "limit" => 100}, extra))
    Jason.decode!(json)
  end

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
