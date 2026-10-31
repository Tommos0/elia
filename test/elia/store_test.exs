defmodule Elia.StoreTest do
  use ExUnit.Case, async: false

  alias Elia.Store
  alias Elia.LLM.Message

  # STORE-1, STORE-9
  test "a chat's model selection is saved with it and defaults to nil" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    model = %{provider: "openrouter", model: "vendor/m", name: "Vendor M"}

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_model(id) == nil

    :ok = Store.save(id, [Message.user("hi")], model: model)
    assert Store.load_model(id) == model
    assert [%Message{}] = Store.load(id)

    assert Store.load_model("missing-chat") == nil
    assert Store.load_model("../bad") == nil
  end

  # STORE-1, STORE-14, STORE-15
  test "a chat's auto-approved tools are saved with it and default to none" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_auto_approve(id) == []

    :ok = Store.save(id, [Message.user("hi")], auto_approve: ["shell", "edit_file"])
    assert Store.load_auto_approve(id) == ["shell", "edit_file"]
    assert [%Message{}] = Store.load(id)

    # An empty list leaves the key out, so turning the last tool off clears it.
    :ok = Store.save(id, [Message.user("hi")], auto_approve: [])
    assert Store.load_auto_approve(id) == []

    assert Store.load_auto_approve("missing-chat") == []
    assert Store.load_auto_approve("../bad") == []
  end

  # STORE-3: a fresh dev VM hasn't loaded the modules whose atoms a saved
  # chat uses; loading must load them before the safe decode.
  test "loading a chat loads app modules first so the safe decode succeeds" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok =
      Store.save(id, [
        Message.user("hi"),
        %Message{role: :assistant, content: [Message.text("yo")], meta: %{}}
      ])

    :persistent_term.erase({Store, :app_loaded})
    :code.purge(Elia.SystemStats)
    :code.delete(Elia.SystemStats)
    refute :code.is_loaded(Elia.SystemStats)

    assert [%Message{role: :user}, %Message{role: :assistant}] = Store.load(id)
    assert {:file, _} = :code.is_loaded(Elia.SystemStats)
    assert Store.title(Store.load(id)) == "hi"
  end

  # STORE-7, STORE-10
  test "listed chats carry a 60-char title and a 1000-char description" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [Message.user(String.duplicate("a", 1500))])

    chat = Enum.find(Store.list(1000), &(&1.id == id))
    assert String.length(chat.title) == 60
    assert String.length(chat.description) == 1000

    :ok = Store.save(id, [Message.user("short")])
    chat = Enum.find(Store.list(1000), &(&1.id == id))
    assert %{title: "short", description: "short"} = chat

    :ok = Store.save(id, [])
    assert %{description: "New chat"} = Enum.find(Store.list(1000), &(&1.id == id))
  end

  defp listed(id), do: Enum.find(Store.list(1000), &(&1.id == id))

  # STORE-11
  test "created_at is set by the first save and kept by later saves" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok = Store.save(id, [Message.user("hi")])
    %{created_at: %DateTime{} = created_at} = listed(id)

    :ok = Store.save(id, [Message.user("hi"), Message.user("again")])
    assert %{created_at: ^created_at} = listed(id)
  end

  # STORE-11: a file saved before created_at existed keeps its mtime as the
  # start date, including through its next save.
  test "chats without created_at use their modification time" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [Message.user("hi")])

    path = Path.join(Store.dir(), id <> ".term")
    legacy = path |> File.read!() |> :erlang.binary_to_term() |> Map.delete(:created_at)
    File.write!(path, :erlang.term_to_binary(legacy))
    mtime = ~U[2020-01-02 03:04:05Z]
    File.touch!(path, DateTime.to_unix(mtime))

    assert %{created_at: ^mtime} = listed(id)

    :ok = Store.save(id, [Message.user("hi")])
    assert %{created_at: ^mtime} = listed(id)
  end

  # STORE-12: saving an older chat doesn't move it above a newer one.
  test "chats are listed newest started first, regardless of later saves" do
    older = Elia.Agent.new_id()
    newer = Elia.Agent.new_id()
    on_exit(fn -> Enum.each([older, newer], &Store.delete/1) end)

    :ok = Store.save(older, [Message.user("older")])
    :ok = Store.save(newer, [Message.user("newer")])
    :ok = Store.save(older, [Message.user("older, updated")])

    ids = Store.list(1000) |> Enum.map(& &1.id) |> Enum.filter(&(&1 in [older, newer]))
    assert ids == [newer, older]
    assert %{updated_at: %DateTime{}} = listed(older)
  end

  # STORE-13: a chat saved before LLM-28 still holds raw bytes.
  test "loading replaces invalid UTF-8 but keeps raw blocks exact" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    raw = {Elia.LLM.Anthropic, %{"signature" => <<0x83>>}}

    :ok =
      Store.save(id, [
        %Message{role: :assistant, content: [%{type: :text, text: <<"a", 0x83>>, raw: raw}]},
        %Message{
          role: :tool,
          content: [%{type: :tool_result, tool_call_id: "1", content: <<0x83>>, is_error: false}]
        }
      ])

    assert [
             %Message{content: [%{text: "a�", raw: ^raw}]},
             %Message{content: [%{content: "�"}]}
           ] = Store.load(id)
  end

  # STORE-16
  test "a chat's task metadata is saved with it and defaults to nil" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    task = %{parent_id: "p1", title: "Do it", brief: "B", status: "running", start_commit: "abc"}

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_task(id) == nil

    :ok = Store.save(id, [Message.user("hi")], task: task)
    assert Store.load_task(id) == task
    assert [%Message{}] = Store.load(id)

    assert Store.load_task("missing-chat") == nil
    assert Store.load_task("../bad") == nil
  end

  # STORE-17
  test "listed task chats carry their parent, status and task title" do
    done = Elia.Agent.new_id()
    lost = Elia.Agent.new_id()
    plain = Elia.Agent.new_id()
    on_exit(fn -> Enum.each([done, lost, plain], &Store.delete/1) end)

    Store.save(done, [Message.user("preamble")],
      task: %{parent_id: "p1", title: "Finished one", status: "done"}
    )

    Store.save(lost, [Message.user("preamble")],
      task: %{parent_id: "p1", title: "Lost one", status: "running"}
    )

    Store.save(plain, [Message.user("just a chat")])

    list = Store.list(1000)
    assert %{title: "Finished one", parent_id: "p1", task_status: "done"} = entry(list, done)
    # Saved as running, but it isn't the active child: its session was lost.
    assert %{task_status: "interrupted"} = entry(list, lost)
    plain_entry = entry(list, plain)
    refute Map.has_key?(plain_entry, :parent_id)
    assert plain_entry.title == "just a chat"
  end

  # STORE-18
  test "children/1 lists a chat's task chats oldest first, with their call ids" do
    parent = Elia.Agent.new_id()
    first = Elia.Agent.new_id()
    second = Elia.Agent.new_id()
    other = Elia.Agent.new_id()
    on_exit(fn -> Enum.each([first, second, other], &Store.delete/1) end)

    task = fn parent_id, call_id ->
      %{parent_id: parent_id, parent_call_id: call_id, title: "T #{call_id}", status: "done"}
    end

    Store.save(first, [Message.user("x")], task: task.(parent, "c1"))
    Store.save(second, [Message.user("x")], task: task.(parent, "c2"))
    Store.save(other, [Message.user("x")], task: task.("someone-else", "c3"))

    assert [%{id: ^first, parent_call_id: "c1"}, %{id: ^second, parent_call_id: "c2"}] =
             Store.children(parent)

    assert Store.children("nobody") == []
  end

  defp entry(list, id), do: Enum.find(list, &(&1.id == id))
end
