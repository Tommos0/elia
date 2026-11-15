defmodule Elia.StoreCacheTest do
  # The cache is one table for the whole VM, and the listing reads every chat.
  use ExUnit.Case, async: false

  alias Elia.Store
  alias Elia.LLM.Message

  setup do
    test_pid = self()
    handler = "store-decodes-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:elia, :store, :decode],
      fn _event, _measure, %{id: id}, _ -> send(test_pid, {:decoded, id}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp new_chat(messages \\ [Message.user("hello")], opts \\ []) do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, messages, opts)
    id
  end

  # How many times `id`'s file was decoded since the last call.
  defp decodes(id), do: count_decodes(id, 0)

  defp count_decodes(id, n) do
    receive do
      {:decoded, ^id} -> count_decodes(id, n + 1)
    after
      0 -> n
    end
  end

  defp listed(id), do: Enum.find(Store.list(10_000), &(&1.id == id))

  defp path(id), do: Path.join(Store.dir(), id <> ".term")

  # STORE-44: every saved key but the messages, from one decode — and the
  # per-key loaders answer from it, so a session's start reads its settings
  # with one decode rather than one per key.
  test "load_meta holds every saved key but the messages, and the loaders decode once" do
    model = %{provider: "openrouter", model: "vendor/m"}

    id =
      new_chat([Message.user("hello")],
        model: model,
        auto_approve: ["shell"],
        project: "proj",
        jail: false,
        limits: %{max_steps: 5},
        effort: "high",
        title: "Mine",
        done: true
      )

    decodes(id)

    meta = Store.load_meta(id)
    refute Map.has_key?(meta, :messages)
    assert %{model: ^model, auto_approve: ["shell"], project_id: "proj", jail: false} = meta
    assert %{limits: %{max_steps: 5}, effort: "high", title: "Mine", done: true} = meta

    assert Store.load_model(id) == model
    assert Store.load_auto_approve(id) == ["shell"]
    assert Store.load_project(id) == "proj"
    assert Store.load_jail(id) == false
    assert Store.load_limits(id).max_steps == 5
    assert Store.load_effort(id) == "high"
    assert Store.load_title(id) == "Mine"
    assert Store.load_done(id) == true
    assert Store.load_task(id) == nil
    assert Store.load_turn(id) == nil
    assert Store.load_compaction(id) == nil
    assert Store.chat_title(id) == "Mine"

    assert decodes(id) == 1

    assert Store.load_meta("../bad") == nil
    assert Store.load_meta(Elia.Agent.new_id()) == nil
  end

  # STORE-44: a corrupt file has no meta, and its loaders answer their defaults.
  test "a corrupt chat has no meta, and each loader answers its default" do
    id = new_chat()
    File.write!(path(id), "not a term")

    assert Store.load_meta(id) == nil
    assert Store.load_model(id) == nil
    assert Store.load_jail(id) == true
    assert Store.load_auto_approve(id) == []
    assert Store.chat_title(id) == "New chat"
  end

  # STORE-45: a listing decodes only the files that changed since the last one.
  test "a second listing of an unchanged chat decodes nothing" do
    id = new_chat()
    assert %{title: "hello"} = listed(id)
    assert decodes(id) == 1

    assert %{title: "hello"} = listed(id)
    assert decodes(id) == 0
  end

  # STORE-45: a save from another process changes the file's identity, so the
  # next read decodes it afresh.
  test "a save by another process is seen at the next read" do
    id = new_chat()
    assert %{title: "hello"} = listed(id)

    Task.async(fn -> Store.save(id, [Message.user("hello")], title: "Renamed") end)
    |> Task.await()

    assert %{title: "Renamed"} = listed(id)
    assert Store.load_title(id) == "Renamed"
  end

  # STORE-45: a file replaced outside `Elia.Store` — another OS process, say —
  # is seen too: the identity is the file's, not anything Elia recorded.
  test "a file replaced or removed outside the store is seen at the next read" do
    id = new_chat()
    assert %{title: "hello"} = listed(id)
    assert Store.load_done(id) == false

    other = Path.join(Store.dir(), "#{id}.outside")
    chat = %{version: 1, messages: [Message.user("from outside")], done: true}
    File.write!(other, :erlang.term_to_binary(chat))
    File.rename!(other, path(id))

    assert %{title: "from outside", done: true} = listed(id)
    assert Store.load_done(id) == true

    File.rm!(path(id))

    assert listed(id) == nil
    assert Store.load_meta(id) == nil
    assert :ets.lookup(:elia_store_cache, id) == []
  end

  # STORE-45: a save and a delete through the store drop the entry at once.
  test "a save or a delete through the store drops the chat's entry" do
    id = new_chat()
    assert listed(id)
    assert [_] = :ets.lookup(:elia_store_cache, id)

    :ok = Store.save(id, [Message.user("again")])
    assert :ets.lookup(:elia_store_cache, id) == []

    assert listed(id)
    :ok = Store.delete(id)
    assert :ets.lookup(:elia_store_cache, id) == []
  end

  # STORE-45, STORE-31: whether a chat was interrupted depends on whether a
  # session runs for it, which is never cached: the same unchanged file lists
  # as interrupted, then not while a session runs, then interrupted again.
  test "running state is worked out at every listing, never cached" do
    id = new_chat([Message.user("hello")], turn: %{id: "t", started_at: DateTime.utc_now()})

    assert %{interrupted: true} = listed(id)

    {:ok, _owner} = Registry.register(Elia.Agent.Registry, id, nil)
    assert %{interrupted: false} = listed(id)

    :ok = Registry.unregister(Elia.Agent.Registry, id)
    assert %{interrupted: true} = listed(id)

    assert decodes(id) == 1
  end
end
