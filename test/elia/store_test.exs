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
end
