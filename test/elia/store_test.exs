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

  # STORE-25, STORE-26: the jail is on by default, so only "off" is stored.
  test "a chat's jail setting is saved only when it is off, and defaults to on" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_jail(id) == true
    # A chat that keeps the default carries no entry at all.
    chat = File.read!(Path.join(Store.dir(), id <> ".term")) |> :erlang.binary_to_term()
    refute Map.has_key?(chat, :jail)

    # A stored true is never written, but reads back as on all the same.
    :ok = Store.save(id, [Message.user("hi")], jail: true)
    assert Store.load_jail(id) == true

    :ok = Store.save(id, [Message.user("hi")], jail: false)
    assert Store.load_jail(id) == false
    assert [%Message{}] = Store.load(id)

    # Turning it back on removes the entry from the file.
    :ok = Store.save(id, [Message.user("hi")], jail: true)
    assert Store.load_jail(id) == true
  end

  # STORE-26
  test "a missing, unreadable, corrupt or valueless chat is jailed" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    assert Store.load_jail("missing-chat") == true
    assert Store.load_jail("../bad") == true
    assert Store.load_jail("") == true

    # Corrupt on disk.
    File.write!(Path.join(Store.dir(), id <> ".term"), "not a term")
    assert Store.load_jail(id) == true

    # A saved chat with no value of its own.
    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_jail(id) == true
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

  # STORE-13: a chat saved before LLM-32 still holds raw bytes.
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

  # STORE-19, STORE-20
  test "a chat's project id is saved with it and defaults to nil" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_project(id) == nil
    assert %{project_id: nil} = entry(Store.list(1000), id)

    :ok = Store.save(id, [Message.user("hi")], project: "proj-1")
    assert Store.load_project(id) == "proj-1"
    assert %{project_id: "proj-1"} = entry(Store.list(1000), id)
    assert [%Message{}] = Store.load(id)

    assert Store.load_compaction("missing-chat") == nil
    assert Store.load_compaction("../bad") == nil
  end

  # STORE-21
  test "a chat's compaction state is saved with it and defaults to nil" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    compaction = %{level: 2, covered: 5, summary: "so far", pins: [{1, nil}], ledger: ["x"]}

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_compaction(id) == nil

    :ok = Store.save(id, [Message.user("hi")], compaction: compaction)
    assert Store.load_compaction(id) == compaction
    assert [%Message{}] = Store.load(id)

    assert Store.load_compaction("missing-chat") == nil
    assert Store.load_compaction("../bad") == nil
  end

  # STORE-30, INTR-1
  test "a chat's turn in flight is saved with it, and its end takes the entry off" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    turn = %{id: "turn-1", started_at: ~U[2026-01-01 00:00:00Z]}

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_turn(id) == nil
    # A chat that has no turn carries no entry at all.
    chat = File.read!(Path.join(Store.dir(), id <> ".term")) |> :erlang.binary_to_term()
    refute Map.has_key?(chat, :turn)

    :ok = Store.save(id, [Message.user("hi")], turn: turn)
    assert Store.load_turn(id) == turn

    # INTR-1: the save that ends the turn drops the key.
    :ok = Store.save(id, [Message.user("hi"), Message.user("more")], turn: nil)
    assert Store.load_turn(id) == nil
    chat = File.read!(Path.join(Store.dir(), id <> ".term")) |> :erlang.binary_to_term()
    refute Map.has_key?(chat, :turn)
    assert [%Message{}, %Message{}] = Store.load(id)

    assert Store.load_turn("missing-chat") == nil
    assert Store.load_turn("../bad") == nil
  end

  # STORE-31, INTR-2
  test "a listed chat says whether a restart interrupted its turn" do
    id = Elia.Agent.new_id()
    plain = Elia.Agent.new_id()
    on_exit(fn -> Enum.each([id, plain], &Store.delete/1) end)

    turn = %{id: "turn-1", started_at: DateTime.utc_now()}
    :ok = Store.save(id, [Message.user("hi")], turn: turn)
    :ok = Store.save(plain, [Message.user("hi")])

    # The record is there and no session runs for it: the app stopped mid-turn.
    assert %{interrupted: true} = listed(id)
    # A chat with no record is not flagged, and one whose file is gone isn't
    # listed at all.
    assert %{interrupted: false} = listed(plain)
    assert listed("never-saved") == nil
  end

  # STORE-23, UI-66
  test "deleting a chat removes its file, and only its own" do
    parent = Elia.Agent.new_id()
    child = Elia.Agent.new_id()
    on_exit(fn -> Enum.each([parent, child], &Store.delete/1) end)

    :ok = Store.save(parent, [Message.user("delegate this")])
    :ok = save_task_child(child, parent)

    # UI-66: deleting the task chat leaves its parent.
    assert :ok = Store.delete(child)
    assert Store.load(child) == []
    refute listed(child)
    assert [%Message{}] = Store.load(parent)

    # UI-66: deleting the parent leaves its task chat saved.
    :ok = save_task_child(child, parent)
    assert :ok = Store.delete(parent)
    assert Store.load(parent) == []
    assert [%Message{}] = Store.load(child)
    assert %{id: ^child, parent_id: ^parent} = listed(child)
  end

  defp save_task_child(child, parent) do
    Store.save(child, [Message.user("preamble")],
      task: %{parent_id: parent, title: "Task one", status: "done"}
    )
  end

  # STORE-24
  test "exists?/1 reports whether a valid id has a saved chat file" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    refute Store.exists?(id)

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.exists?(id)

    # No decoding, so a file that can't be read as a chat still exists.
    File.write!(Path.join(Store.dir(), id <> ".term"), "not a term")
    assert Store.exists?(id)

    assert :ok = Store.delete(id)
    refute Store.exists?(id)

    refute Store.exists?("../bad")
    refute Store.exists?("")
  end

  # STORE-23
  test "deleting a chat that was never saved is ok, and an invalid id removes nothing" do
    assert :ok = Store.delete(Elia.Agent.new_id())

    kept = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(kept) end)
    :ok = Store.save(kept, [Message.user("keep me")])

    assert {:error, :invalid_id} = Store.delete("../bad")
    assert {:error, :invalid_id} = Store.delete("")
    assert {:error, :invalid_id} = Store.delete("a b")
    assert [%Message{}] = Store.load(kept)
  end

  # STORE-29, UI-77, DONE-10: the chat `/chats` resumes — the most recently
  # started chat that is neither a task chat nor done.
  test "latest/0 is the newest chat that isn't a task chat or done" do
    parent = Elia.Agent.new_id()
    task = Elia.Agent.new_id()
    done = Elia.Agent.new_id()
    on_exit(fn -> Enum.each([parent, task, done], &Store.delete/1) end)

    :ok = Store.save(parent, [Message.user("where I left off")])

    # Started after it, but a sub-task chat is reached from its parent's card,
    # not from the chat list's entry point (UI-77).
    :ok =
      Store.save(task, [Message.user("preamble")],
        task: %{parent_id: parent, title: "A task", brief: "Brief", status: "running"}
      )

    # And a done chat is finished work, not where the user left off (DONE-10).
    :ok = Store.save(done, [Message.user("finished")], done: true)

    assert Store.latest().id == parent
    assert Store.latest().title == "where I left off"
  end

  # STORE-29, UI-77: with nothing saved there is no chat to resume.
  test "latest/0 is nil when no chat is saved" do
    with_empty_store(fn ->
      assert Store.list(1000) == []
      assert Store.latest() == nil
    end)
  end

  # STORE-29, STORE-4, UI-2: a stray file whose name isn't a valid chat id is
  # not resumed — `/c/<id>` would reject it and send the browser back to `/`,
  # over and over.
  test "latest/0 skips an entry whose id isn't valid" do
    with_empty_store(fn ->
      File.mkdir_p!(Store.dir())

      File.write!(
        Path.join(Store.dir(), "not a chat.term"),
        :erlang.term_to_binary(%{version: 1, messages: []})
      )

      assert Store.latest() == nil
      assert [%{id: "not a chat"}] = Store.list(10)
    end)
  end

  defp entry(list, id), do: Enum.find(list, &(&1.id == id))

  # STORE-36: one chat's listing, without listing the others.
  test "entry/1 gives one chat the same entry list/1 would" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    assert Store.entry(id) == nil
    assert Store.entry("../bad") == nil
    assert Store.entry("") == nil

    :ok = Store.save(id, [Message.user("what I asked")], done: true, project: "proj-1")

    assert %{title: "what I asked", description: "what I asked", done: true} = Store.entry(id)
    assert Store.entry(id) == entry(Store.list(1000), id)

    # A corrupt chat has a file, so it is still an entry.
    File.write!(Path.join(Store.dir(), id <> ".term"), "not a term")
    assert %{id: ^id, title: "New chat"} = Store.entry(id)
  end

  # A store of its own: a throwaway runtime root, since that is where Elia's
  # data and so the saved chats live (DEPLOY-2).
  defp with_empty_store(fun) do
    root = Path.join(System.tmp_dir!(), "elia-latest-store-#{Elia.Agent.new_id()}")
    File.mkdir_p!(root)
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, root)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)

      File.rm_rf!(root)
    end
  end
end
