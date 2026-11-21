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

    :ok = Store.save(id, [Message.user("hi")], auto_approve: ["shell", "spawn_task"])
    assert Store.load_auto_approve(id) == ["shell", "spawn_task"]
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

  # STORE-53, NET-28: only a mode that limits the network is stored, and only
  # the mode — the entries are the chat's project's.
  test "a chat's network setting is saved as a mode" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok = Store.save(id, [Message.user("hi")], network: %{mode: :allowlist})

    assert Store.load_network(id) == %{mode: :allowlist, hosts: []}

    chat = File.read!(Path.join(Store.dir(), id <> ".term")) |> :erlang.binary_to_term()
    assert chat.network == %{mode: :allowlist}

    :ok = Store.save(id, [Message.user("hi")], network: %{mode: :none})
    assert Store.load_network(id) == %{mode: :none, hosts: []}

    # Setting it back to unrestricted takes the entry off the file.
    :ok = Store.save(id, [Message.user("hi")], network: %{mode: :unrestricted})
    assert Store.load_network(id) == Elia.Net.unrestricted()

    chat = File.read!(Path.join(Store.dir(), id <> ".term")) |> :erlang.binary_to_term()
    refute Map.has_key?(chat, :network)

    # A chat with no entry at all is unrestricted (STORE-54).
    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_network(id) == Elia.Net.unrestricted()
  end

  # NET-1, STORE-54: a chat that has never been saved starts allowlisted where a
  # limit can be built for it, and unrestricted where it can't.
  test "a chat that has never been saved starts at the default" do
    assert Store.load_network("missing-chat") == Elia.Net.default()

    assert Store.load_network("missing-chat", jail: false) == Elia.Net.unrestricted()

    # NET-29: an older file that named hosts of its own still reaches them: its
    # session reads them and hands them to its project.
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok = Store.save(id, [Message.user("hi")], network: %{mode: :allowlist})
    path = Path.join(Store.dir(), id <> ".term")

    chat =
      path
      |> File.read!()
      |> :erlang.binary_to_term()
      |> Map.put(:network, %{mode: :allowlist, hosts: ["API.example.com"]})

    File.write!(path, :erlang.term_to_binary(chat))

    assert Store.load_network(id) == %{mode: :allowlist, hosts: ["api.example.com"]}
  end

  # STORE-54, NET-1: a chat that is unreadable, corrupt or holds a value that
  # can't be read is unrestricted.
  test "an unreadable or unreadable-valued chat is unrestricted" do
    assert Store.load_network("../bad") == Elia.Net.unrestricted()

    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [Message.user("hi")])

    File.write!(Path.join(Store.dir(), id <> ".term"), "not a term")
    assert Store.load_network(id) == Elia.Net.unrestricted()
  end

  # STORE-37, STORE-38: a chat's own reasoning effort is stored only when it has
  # one, and reads back as none when it hasn't.
  test "a chat's reasoning effort is saved only when it has one of its own" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_effort(id) == nil
    # A chat that keeps the configured default carries no entry at all.
    chat = File.read!(Path.join(Store.dir(), id <> ".term")) |> :erlang.binary_to_term()
    refute Map.has_key?(chat, :effort)

    :ok = Store.save(id, [Message.user("hi")], effort: "high")
    assert Store.load_effort(id) == "high"
    assert [%Message{}] = Store.load(id)

    # Giving the chat no effort of its own again drops the entry from the file.
    :ok = Store.save(id, [Message.user("hi")], effort: nil)
    assert Store.load_effort(id) == nil
    chat = File.read!(Path.join(Store.dir(), id <> ".term")) |> :erlang.binary_to_term()
    refute Map.has_key?(chat, :effort)

    # Only the three efforts a request can name are stored.
    :ok = Store.save(id, [Message.user("hi")], effort: "very high")
    assert Store.load_effort(id) == nil
  end

  # STORE-38: an older file has no `effort` key at all, and reads as a chat with
  # none of its own — which is why this change needs no migration.
  test "a missing, unreadable, corrupt or valueless chat has no effort of its own" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    assert Store.load_effort("missing-chat") == nil
    assert Store.load_effort("../bad") == nil
    assert Store.load_effort("") == nil

    # Written by hand, so the directory a save would make may not exist yet.
    File.mkdir_p!(Store.dir())
    File.write!(Path.join(Store.dir(), id <> ".term"), "not a term")
    assert Store.load_effort(id) == nil

    # A chat saved by an older version: no `effort` key, read as none.
    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_effort(id) == nil
  end

  # STORE-26
  test "a missing, unreadable, corrupt or valueless chat is jailed" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    assert Store.load_jail("missing-chat") == true
    assert Store.load_jail("../bad") == true
    assert Store.load_jail("") == true

    # Corrupt on disk, written by hand, so the directory a save would make may
    # not exist yet.
    File.mkdir_p!(Store.dir())
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

  # STORE-6: a listing returns up to the number of chats it was asked for, and
  # nothing more.
  test "list/1 returns up to the number of chats it is asked for" do
    with_empty_store(fn ->
      for _ <- 1..3, do: Store.save(Elia.Agent.new_id(), [Message.user("hi")])

      assert length(Store.list(1000)) == 3
      assert length(Store.list(2)) == 2
    end)
  end

  defp temp_files(id),
    do: Store.dir() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, id <> ".term."))

  # STORE-2: a save goes through a temporary file that is renamed into place, so
  # a reader never sees a half-written chat and no temporary file is left behind.
  test "a save leaves no temporary file behind" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok = Store.save(id, [Message.user("hi")])

    assert temp_files(id) == []
    assert [%Message{}] = Store.load(id)
  end

  # STORE-47: a data directory that can't be made is a save that failed like any
  # other — an error for the caller that logs it and carries on (SESS-13) — and
  # not a raise, which would take the caller down with it.
  test "a save whose data directory can't be made returns an error" do
    with_empty_store(fn ->
      # A file where the data directory belongs, so nothing can be made under it.
      File.write!(Elia.Workspace.data_dir(), "")

      assert {:error, _reason} = Store.save(Elia.Agent.new_id(), [Message.user("hi")])
    end)
  end

  # STORE-2: saves of one chat at the same time each have a temporary file of
  # their own, so every one succeeds and the file is always one of them, whole.
  test "saves of one chat at the same time never truncate or mix it" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    big = String.duplicate("x", 200_000)

    results =
      1..20
      |> Task.async_stream(
        fn n -> Store.save(id, [Message.user("#{n} #{big}")], title: "save #{n}") end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == :ok))
    assert temp_files(id) == []

    assert [%Message{} = message] = Store.load(id)
    "save " <> n = Store.load_title(id)
    assert Message.text_content(message) == "#{n} #{big}"
  end

  # STORE-2: a temporary file a crash left behind — of this version's naming, or
  # the older shared `<id>.term.tmp` — is never listed or read as a chat.
  test "a temporary file left behind is not a chat" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [Message.user("hi")])

    leftovers = [id <> ".term.tmp", id <> ".term.123-4.tmp"]
    for name <- leftovers, do: File.write!(Path.join(Store.dir(), name), "half a chat")
    on_exit(fn -> for name <- leftovers, do: File.rm(Path.join(Store.dir(), name)) end)

    assert [%{id: ^id}] = Enum.filter(Store.list(1000), &String.starts_with?(&1.id, id))
    assert [%Message{}] = Store.load(id)
  end

  # STORE-43: an update changes the keys it is asked to and keeps every other
  # key of the file as it was.
  test "an update keeps every key it doesn't change" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok =
      Store.save(id, [Message.user("hi"), Message.user("there")],
        model: %{provider: "openrouter", model: "vendor/m"},
        auto_approve: ["shell"],
        task: %{parent_id: "p", status: "running"},
        project: "proj",
        compaction: %{level: 1, covered: 1, summary: "s", pins: [], ledger: []},
        jail: false,
        limits: %{max_steps: 5},
        effort: "high",
        title: "Kept",
        turn: %{id: "t1", started_at: DateTime.utc_now()},
        done: true
      )

    read = fn -> :erlang.binary_to_term(File.read!(Path.join(Store.dir(), id <> ".term"))) end
    before = read.()

    assert :ok = Store.update(id, &Map.put(&1, :task, %{parent_id: "p", status: "done"}))

    later = read.()
    assert later.task == %{parent_id: "p", status: "done"}
    assert Map.drop(later, [:task, :updated_at]) == Map.drop(before, [:task, :updated_at])
    assert DateTime.compare(later.updated_at, before.updated_at) in [:gt, :eq]
    assert temp_files(id) == []
  end

  # STORE-43, STORE-11: a file saved before `created_at` existed keeps the
  # start date its modification time gave it.
  test "an update of a file with no created_at keeps its start date" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    File.mkdir_p!(Store.dir())
    path = Path.join(Store.dir(), id <> ".term")
    File.write!(path, :erlang.term_to_binary(%{version: 1, messages: [Message.user("old")]}))
    File.touch!(path, 1_600_000_000)

    assert :ok = Store.update(id, &Map.put(&1, :title, "Old chat"))
    assert Store.entry(id).created_at == DateTime.from_unix!(1_600_000_000)
    assert Store.load_title(id) == "Old chat"
  end

  # STORE-43: an update never creates a chat.
  test "an update of a chat with no file, or an invalid id, writes nothing" do
    id = Elia.Agent.new_id()

    assert Store.update(id, &Map.put(&1, :title, "x")) == {:error, :not_found}
    refute Store.exists?(id)
    assert Store.update("../bad", &Map.put(&1, :title, "x")) == {:error, :not_found}
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

  # STORE-52: a listing's `where:` keeps the entries it returns true for — the
  # same order and limit, and `latest/1` narrowed the same way.
  test "list/2 and latest/1 take a where: that narrows the listing" do
    keep = Elia.Agent.new_id()
    drop = Elia.Agent.new_id()
    on_exit(fn -> Enum.each([keep, drop], &Store.delete/1) end)

    :ok = Store.save(drop, [Message.user("dropped")], project: "other")
    :ok = Store.save(keep, [Message.user("kept")], project: "mine")
    where = fn entry -> entry.project_id == "mine" end

    ids = Store.list(1000, where: where) |> Enum.map(& &1.id)
    assert keep in ids
    refute drop in ids
    assert Enum.all?(Store.list(1000, where: where), &(&1.project_id == "mine"))

    # The order and the limit are the unfiltered listing's (STORE-12).
    assert Store.list(1, where: where) == [Store.entry(keep)]
    assert %{id: ^keep} = Store.latest(where: where)

    # No `where:` at all is the listing it always was, and one nothing matches
    # is an empty listing and `nil` from `latest/1` (STORE-29).
    assert length(Store.list(1000)) >= 2
    assert Store.list(1000, where: fn _ -> false end) == []
    assert Store.latest(where: fn _ -> false end) == nil
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
    task = %{parent_id: "p1", started_at: ~U[2026-01-02 03:04:05Z]}

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_task(id) == nil

    :ok = Store.save(id, [Message.user("hi")], task: task)
    assert Store.load_task(id) == task
    assert [%Message{}] = Store.load(id)

    # SUBTASK-13: the result joins the metadata when the chat is marked done.
    result = %{"task_id" => id, "summary" => "Done."}
    :ok = Store.save(id, [Message.user("hi")], task: Map.put(task, :result, result))
    assert Store.load_task(id) == Map.put(task, :result, result)

    assert Store.load_task("missing-chat") == nil
    assert Store.load_task("../bad") == nil
  end

  # STORE-16: a file an earlier version wrote carries keys this version doesn't —
  # a task `status`, `title`, `brief`, `parent_call_id`, `start_commit`, and a
  # result with `commit` and `files` (SUBTASK-9). It is read for the keys it has
  # and the rest are ignored, with nothing rewritten: no migration.
  test "an old task file's other keys are ignored, read-time only" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok =
      Store.save(id, [Message.user("hi")],
        task: %{
          parent_id: "p1",
          parent_call_id: "c1",
          title: "Do it",
          brief: "B",
          started_at: ~U[2026-01-02 03:04:05Z],
          status: "running",
          start_commit: "abc",
          result: %{"task_id" => id, "summary" => "S", "commit" => "abc", "files" => ["a"]}
        }
      )

    loaded = Store.load_task(id)

    assert loaded == %{
             parent_id: "p1",
             started_at: ~U[2026-01-02 03:04:05Z],
             result: %{"task_id" => id, "summary" => "S", "commit" => "abc", "files" => ["a"]}
           }

    refute Map.has_key?(loaded, :status)
    refute Map.has_key?(loaded, :brief)
    assert entry(Store.list(1000), id).parent_id == "p1"
    # Read-time only: the file still holds the keys it was written with.
    saved = :erlang.binary_to_term(File.read!(Path.join(Store.dir(), id <> ".term")))
    assert saved.task.status == "running"
    assert saved.task.brief == "B"
  end

  # STORE-17
  test "listed task chats carry their parent and their own title, and no status" do
    done = Elia.Agent.new_id()
    lost = Elia.Agent.new_id()
    plain = Elia.Agent.new_id()
    on_exit(fn -> Enum.each([done, lost, plain], &Store.delete/1) end)

    Store.save(done, [Message.user("preamble")],
      title: "Finished one",
      task: %{parent_id: "p1", started_at: ~U[2026-01-02 03:04:05Z]}
    )

    Store.save(lost, [Message.user("preamble")], task: %{parent_id: "p1"})

    Store.save(plain, [Message.user("just a chat")])

    list = Store.list(1000)

    # STORE-32, TITLE-3: a task chat's title is its chat's own title, and its
    # task metadata adds nothing to the row but the parent it belongs to.
    assert %{title: "Finished one", parent_id: "p1"} = entry(list, done)
    refute Map.has_key?(entry(list, done), :task_status)
    assert %{parent_id: "p1"} = entry(list, lost)
    assert entry(list, lost).title != "p1"
    refute Map.has_key?(entry(list, lost), :task_status)
    plain_entry = entry(list, plain)
    refute Map.has_key?(plain_entry, :parent_id)
    assert plain_entry.title == "just a chat"
  end

  # STORE-17: `latest/0` skips a task chat, whichever keys an older file gave
  # it — its `parent_id` is what says it is one.
  test "latest/0 never answers with a task chat" do
    parent = Elia.Agent.new_id()
    child = Elia.Agent.new_id()
    on_exit(fn -> Enum.each([parent, child], &Store.delete/1) end)

    Store.save(parent, [Message.user("preamble")], title: "The parent")

    Store.save(child, [Message.user("preamble")], task: %{parent_id: parent, title: "A task"})

    assert Store.latest().id == parent
  end

  # STORE-18
  test "children/1 lists a chat's task chats oldest first" do
    parent = Elia.Agent.new_id()
    first = Elia.Agent.new_id()
    second = Elia.Agent.new_id()
    other = Elia.Agent.new_id()
    on_exit(fn -> Enum.each([first, second, other], &Store.delete/1) end)

    Store.save(first, [Message.user("x")], task: %{parent_id: parent}, title: "T1")
    Store.save(second, [Message.user("x")], task: %{parent_id: parent}, title: "T2")
    Store.save(other, [Message.user("x")], task: %{parent_id: "someone-else"}, title: "T3")

    # STORE-18, STORE-17: each is the ordinary listed chat it is, with the parent
    # it belongs to — a parent reads its children's status from their chats.
    assert [%{id: ^first, parent_id: ^parent, title: "T1"}, %{id: ^second, parent_id: ^parent}] =
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

    # STORE-30, RESUME-5: a turn an automatic resume started says so.
    resumed = Map.put(turn, :resumed, true)
    :ok = Store.save(id, [Message.user("hi")], turn: resumed)
    assert Store.load_turn(id) == resumed

    assert Store.load_turn("missing-chat") == nil
    assert Store.load_turn("../bad") == nil
  end

  # STORE-39, RESUME-1
  test "interrupted/0 lists every chat that still holds a turn, and only those" do
    # More than one page of `list/1` (STORE-12): a scan at boot sees them all.
    ids = for _ <- 1..55, do: Elia.Agent.new_id()
    on_exit(fn -> Enum.each(ids, &Store.delete/1) end)

    turn = %{id: "turn-1", started_at: ~U[2026-01-01 00:00:00Z]}
    for id <- ids, do: :ok = Store.save(id, [Message.user("hi")], turn: turn)

    listed = Store.interrupted()

    assert length(listed) >= 55
    assert Enum.all?(ids, &(&1 in Enum.map(listed, fn entry -> entry.id end)))
    assert Enum.all?(listed, &Map.get(&1, :interrupted))

    # A chat whose turn ended, an id that isn't valid (STORE-4) and a file that
    # can't be read are left out.
    finished = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(finished) end)
    :ok = Store.save(finished, [Message.user("hi")])

    dir = Store.dir()
    File.write!(Path.join(dir, "bad!.term"), :erlang.term_to_binary(%{turn: turn}))
    File.write!(Path.join(dir, "junk.term"), "not a term")

    # STORE-51: the decodable file that isn't a chat is reported when it is read.
    parent = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(parent, {:found, Store.interrupted() |> Enum.map(& &1.id)})
      end)

    found = receive do: ({:found, ids} -> ids)
    File.rm!(Path.join(dir, "bad!.term"))
    File.rm!(Path.join(dir, "junk.term"))

    assert log =~ "bad!"
    refute finished in found
    refute "bad!" in found
    refute "junk" in found
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
      title: "Task one",
      task: %{parent_id: parent, started_at: ~U[2026-01-02 03:04:05Z]}
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
        title: "A task",
        task: %{parent_id: parent, started_at: ~U[2026-01-02 03:04:05Z]}
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

  # STORE-48, STORE-49, STORE-50: a file that decodes to a term that isn't a
  # chat is contained — every reader answers as it does for a file that can't be
  # decoded at all (STORE-3), and the file is left exactly as it was.
  test "a decodable file that isn't a chat is contained" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    path = Path.join(Store.dir(), id <> ".term")

    not_chats = [
      # STORE-48: no version of the shape STORE-1's table states.
      %{version: 2, messages: [Message.user("hi")]},
      %{version: 1, messages: nil},
      %{version: 1, messages: 5},
      %{version: 1, messages: ["not a message"]},
      %{version: 1, messages: [Message.user("hi"), "not a message"]},
      %{version: 1, messages: [%Message{role: :user, content: [%{type: :text, text: 5}]}]},
      %{
        version: 1,
        messages: [%Message{role: :system, content: [Message.text("hi")], meta: %{}}]
      },
      %{version: 1, messages: [Message.user("hi")], created_at: 5},
      %{version: 1, messages: [Message.user("hi")], updated_at: "today"},
      [1, 2, 3],
      nil
    ]

    for term <- not_chats do
      data = :erlang.term_to_binary(term)
      write_chat(id, data)

      # STORE-51: each read reports the file once, so the reads are captured.
      ExUnit.CaptureLog.capture_log(fn ->
        assert Store.load(id) == [], "load of #{inspect(term)}"
        assert Store.load_meta(id) == nil
        assert Store.load_model(id) == nil
        assert Store.load_auto_approve(id) == []
        assert Store.load_jail(id) == true
        assert Store.load_done(id) == false
        assert Store.chat_title(id) == "New chat"

        assert %{id: ^id, title: "New chat", description: "New chat", done: false} =
                 Store.entry(id),
               "entry of #{inspect(term)}"

        assert entry(Store.list(1000), id).title == "New chat"
        assert Store.update(id, &Map.put(&1, :title, "mine")) == {:error, :not_found}
      end)

      # STORE-50: nothing rewrote, repaired or removed it.
      assert File.read!(path) == data
    end
  end

  # STORE-49, STORE-39: one malformed file never takes out a listing or the
  # resume scan for the chats saved beside it.
  test "a malformed chat doesn't take a listing or the resume scan down" do
    with_empty_store(fn ->
      good = Elia.Agent.new_id()
      bad = Elia.Agent.new_id()
      turn = %{id: "turn-1", started_at: ~U[2026-01-02 03:04:05Z]}

      :ok = Store.save(good, [Message.user("still here")], turn: turn)
      write_chat(bad, :erlang.term_to_binary(%{version: 1, messages: nil}))

      ExUnit.CaptureLog.capture_log(fn ->
        assert %{title: "still here"} = entry(Store.list(1000), good)
        assert [%{id: ^good, interrupted: true}] = Store.interrupted()
        assert %{title: "New chat"} = entry(Store.list(1000), bad)
      end)
    end)
  end

  # STORE-48: a chat of the shape every save writes still reads as one, including
  # one an earlier version wrote — with no `created_at` of its own (STORE-11) and
  # a provider's raw block kept exactly as it is (LLM-6).
  test "a chat of the stored shape is still read as one" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    raw = %{type: :text, text: "from before", raw: {Elia.LLM.Anthropic, %{"type" => "text"}}}

    write_chat(
      id,
      :erlang.term_to_binary(%{version: 1, messages: [%Message{role: :user, content: [raw]}]})
    )

    assert [%Message{role: :user, content: [^raw]}] = Store.load(id)
    assert %{title: "from before"} = Store.entry(id)
    # The chat's own keys, read as they are — the version a save writes included.
    assert Store.load_meta(id) == %{version: 1}
  end

  # STORE-51: a contained chat is reported, naming it and why its file isn't a
  # chat, rather than skipped in silence.
  test "a malformed chat is reported when it is decoded" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    write_chat(id, :erlang.term_to_binary(%{version: 1, messages: nil}))

    log = ExUnit.CaptureLog.capture_log(fn -> assert Store.load(id) == [] end)

    assert log =~ id
    assert log =~ "isn't a chat"
    assert log =~ "messages"
  end

  # A saved file written as raw bytes, as a chat saved by a version that wrote
  # something this one doesn't write would be. Renamed into place, so the store
  # cache (STORE-45) sees a file it hasn't read.
  defp write_chat(id, data) do
    File.mkdir_p!(Store.dir())
    path = Path.join(Store.dir(), id <> ".term")
    File.write!(path <> ".raw", data)
    File.rename!(path <> ".raw", path)
    on_exit(fn -> File.rm(path) end)
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

  # SNAP-7: a pair of snapshots saved on a call's tool result comes back with the
  # chat, and a result saved without one reads as a call with no pair — the
  # shape a chat saved before this existed holds.
  test "a shell call's snapshot pair is saved with the chat" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    pair = %{
      root: "/tmp/tree",
      from: "refs/elia/snapshots/1-abc",
      to: "refs/elia/snapshots/2-def",
      files: [%{status: "modified", path: "lib/a.ex"}]
    }

    with_pair = Message.tool_result("c1", "ok\n\n[exit: 0]", false, %{snapshot: pair})
    without = Message.tool_result("c2", "ok\n\n[exit: 0]")

    :ok =
      Store.save(id, [
        Message.user("hi"),
        %Message{role: :tool, content: [with_pair, without]}
      ])

    assert [_, %Message{content: [loaded, older]}] = Store.load(id)
    assert loaded.snapshot == pair
    assert loaded.content == "ok\n\n[exit: 0]"
    refute Map.has_key?(older, :snapshot)
  end
end
