defmodule Elia.ChatTitlesTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    %{id: Agent.new_id()}
  end

  # A session started for `id`, with the store as it is when the test asks for
  # it (a session loads its saved title at start, SESS-33).
  defp start_session(id) do
    {:ok, pid} = Agent.ensure_started(id)
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    pid
  end

  defp await_status(id, status), do: assert_receive({:agent, ^id, {:status, ^status}}, 5000)

  defp listed(id), do: Store.list() |> Enum.filter(&(&1.id == id))

  ## The stored title (TITLE-1, TITLE-2, STORE-32, STORE-33)

  # STORE-7, TITLE-1: a chat that never gets a title of its own is listed and
  # displayed exactly as before.
  test "a chat without a title of its own keeps the first-message title", %{id: id} do
    first = "Chat titles. I would like some mechanism to set short one sentence titles"
    :ok = Store.save(id, [Message.user(first)])
    on_exit(fn -> Store.delete(id) end)

    assert Store.load_title(id) == nil
    assert Store.chat_title(id) == String.slice(first, 0, 60)

    assert [entry] = listed(id)
    assert entry.title == String.slice(first, 0, 60)
    assert entry.description == first
  end

  # STORE-33: a view with an id and no listing gets the same answer.
  test "the title of a chat with no file is \"New chat\"" do
    assert Store.chat_title(Agent.new_id()) == "New chat"
    assert Store.chat_title("") == "New chat"
    assert Store.chat_title("../bad") == "New chat"
  end

  # TITLE-2, STORE-32
  test "a title is shaped: trimmed, whitespace collapsed, cut to 60 characters" do
    assert Store.shape_title("  Chat \n  titles\tnow ") == "Chat titles now"
    assert Store.shape_title(String.duplicate("x", 70)) == String.duplicate("x", 60)

    # Anything that isn't a title at all (TITLE-2).
    assert Store.shape_title("   \n ") == nil
    assert Store.shape_title("") == nil
    assert Store.shape_title(nil) == nil
    assert Store.shape_title(42) == nil
  end

  # STORE-32, TITLE-2
  test "a chat's own title is saved with it, and a blank one drops the entry" do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_title(id) == nil

    :ok = Store.save(id, [Message.user("hi")], title: "  Chat   titles ")
    assert Store.load_title(id) == "Chat titles"
    # The chat's history is kept as it was.
    assert [%Message{}] = Store.load(id)

    # A blank title is no title at all, so the chat falls back to STORE-7.
    :ok = Store.save(id, [Message.user("hi")], title: "   ")
    assert Store.load_title(id) == nil
    assert Store.chat_title(id) == "hi"

    assert Store.load_title("missing-chat") == nil
    assert Store.load_title("../bad") == nil
  end

  # STORE-33, TITLE-1: the list shows the chat's own title, while the hover text
  # stays the first user message (STORE-10, UI-33).
  test "the list shows a chat's own title and still describes it by its first message" do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    first = "Chat titles. I would like some mechanism to set short one sentence titles"
    :ok = Store.save(id, [Message.user(first)], title: "Chat titles")

    assert [entry] = listed(id)
    assert entry.title == "Chat titles"
    assert entry.description == first
    assert Store.chat_title(id) == "Chat titles"
  end

  # STORE-33, STORE-17, TITLE-3: a sub-task is named by its task.
  test "a task chat is listed under its task title, whatever it has stored" do
    child = Agent.new_id()
    on_exit(fn -> Store.delete(child) end)

    task = %{
      parent_id: Agent.new_id(),
      title: "Add the file",
      brief: "b",
      started_at: DateTime.utc_now(),
      status: "done"
    }

    :ok = Store.save(child, [Message.user("preamble")], title: "Not this one", task: task)

    assert [entry] = listed(child)
    assert entry.title == "Add the file"
  end

  ## Setting it (TITLE-4, TITLE-6, SESS-33)

  # TITLE-4, SESS-33, SESS-6
  test "the chat's own title is set, saved and broadcast", %{id: id} do
    :ok = Store.save(id, [Message.user("hi")])
    on_exit(fn -> Store.delete(id) end)
    start_session(id)

    assert {:ok, "Chat titles"} = Agent.set_title(id, "  Chat \n titles  ")

    assert_receive {:agent, ^id, {:title, "Chat titles"}}
    assert Agent.snapshot(id).title == "Chat titles"
    assert Store.load_title(id) == "Chat titles"
    assert Store.chat_title(id) == "Chat titles"
    assert [entry] = listed(id)
    assert entry.title == "Chat titles"
  end

  # SESS-33: a session started for a saved chat takes its title, and one whose
  # state predates the field is upgraded on its next call (SESS-15).
  test "a session loads the chat's saved title", %{id: id} do
    :ok = Store.save(id, [Message.user("hi")], title: "Chat titles")
    on_exit(fn -> Store.delete(id) end)
    pid = start_session(id)

    assert Agent.snapshot(id).title == "Chat titles"

    # A session that outlived a hot reload (SESS-15).
    :sys.replace_state(pid, &Map.delete(&1, :title))
    assert Agent.snapshot(id).title == "Chat titles"
  end

  # TITLE-2, TITLE-6: a blank title changes nothing and is reported.
  test "a blank title is refused", %{id: id} do
    :ok = Store.save(id, [Message.user("hi")])
    on_exit(fn -> Store.delete(id) end)
    start_session(id)

    assert {:error, message} = Agent.set_title(id, "   \n ")
    assert message =~ "blank"

    refute_receive {:agent, ^id, {:title, _}}, 50
    assert Agent.snapshot(id).title == nil
    assert Store.load_title(id) == nil
    assert Store.chat_title(id) == "hi"
  end

  # TITLE-3, TITLE-6: a sub-task is named by its task title (STORE-17), so it
  # takes no title of its own.
  test "a sub-task chat is refused" do
    child = Agent.new_id()
    on_exit(fn -> Store.delete(child) end)

    task = %{
      parent_id: Agent.new_id(),
      title: "Add the file",
      brief: "b",
      started_at: DateTime.utc_now(),
      status: "running"
    }

    :ok = Store.save(child, [Message.user("preamble")], task: task)
    start_session(child)

    assert {:error, message} = Agent.set_title(child, "Something else")
    assert message =~ "sub-task"

    refute_receive {:agent, ^child, {:title, _}}, 50
    assert Agent.snapshot(child).title == nil
    assert Store.load_title(child) == nil
    assert [entry] = listed(child)
    assert entry.title == "Add the file"
  end

  ## The skill and its tool (TITLE-5, SKILL-7)

  # SKILL-7, TITLE-5
  test "the titles skill is built in, and offers one approval-free tool" do
    assert Elia.Skills.Titles in Elia.Skills.builtin()

    assert [tool] = Elia.Skills.Titles.tools()
    assert tool.name == "set_title"
    assert Elia.Tool.approval(tool, %{"title" => "x"}, %{}) == :never
    assert Elia.Skills.Titles.instructions() =~ "set_title"
  end

  # TITLE-5, TITLE-4: the tool is what the model calls, and it sets the title.
  test "the set_title tool sets the chat's title" do
    id = Agent.new_id()
    :ok = Store.save(id, [Message.user("hi")])
    on_exit(fn -> Store.delete(id) end)
    start_session(id)

    [tool] = Elia.Skills.Titles.tools()

    assert {:ok, output} = Elia.Tool.call(tool, %{"title" => "Chat titles"}, %{session_id: id})
    assert output =~ "Chat titles"
    assert Store.load_title(id) == "Chat titles"
    assert_receive {:agent, ^id, {:title, "Chat titles"}}
  end

  # TITLE-6: the tool reports a refusal to the model as an error result.
  test "the set_title tool reports a refusal" do
    child = Agent.new_id()
    on_exit(fn -> Store.delete(child) end)

    task = %{parent_id: Agent.new_id(), title: "T", brief: "b", started_at: DateTime.utc_now()}
    :ok = Store.save(child, [Message.user("preamble")], task: task)
    start_session(child)

    [tool] = Elia.Skills.Titles.tools()

    assert {:error, message} = Elia.Tool.call(tool, %{"title" => "x"}, %{session_id: child})
    assert message =~ "sub-task"
  end

  ## The trigger (TITLE-7)

  # TITLE-7, TITLE-1: nothing but the tool sets a title — no provider call, no
  # timer, no end-of-turn hook — so a turn that doesn't name the chat leaves the
  # derived title in place.
  test "a turn that doesn't name the chat leaves its derived title", %{id: id} do
    start_session(id)
    FakeLLM.push(FakeLLM.assistant([Message.text("Hello!")]))

    :ok = Agent.send_message(id, "Chat titles, please")
    await_status(id, :idle)

    assert [%Message{role: :user}, %Message{role: :assistant}] = Agent.snapshot(id).messages
    assert Store.load_title(id) == nil
    assert Store.chat_title(id) == "Chat titles, please"
    assert [entry] = listed(id)
    assert entry.title == "Chat titles, please"
  end
end
