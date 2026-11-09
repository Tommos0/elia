defmodule Elia.PreviewTest do
  use ExUnit.Case, async: false

  alias Elia.Preview

  # PREVIEW-4
  describe "the file a path's picture gets" do
    test "is the path's position and a slug of the path" do
      assert Preview.file_name(0, "/") == "0-root.png"
      assert Preview.file_name(1, "/files?path=lib%2Felia") == "1-files-path-lib-2felia.png"
      assert Preview.file_name(2, Preview.sample_path()) == "2-c-preview.png"
    end

    test "is cut short for a long path" do
      name = Preview.file_name(3, "/c/" <> String.duplicate("x", 100))

      assert String.starts_with?(name, "3-c-")
      assert String.ends_with?(name, ".png")
      assert String.length(name) == String.length("3-") + 40 + String.length(".png")
    end
  end

  # PREVIEW-11
  describe "the sample chat's path" do
    test "is fixed, and `@chat` stands for it" do
      assert Preview.sample_id() == "preview"
      assert Preview.sample_path() == "/c/preview"
      assert Preview.resolve_path("@chat") == "/c/preview"
      assert Preview.resolve_path("/files") == "/files"
    end

    test "is what the app serves a picture at" do
      assert Preview.url("preview", "0-root.png") == "/preview/preview/0-root.png"
    end
  end

  # PREVIEW-15
  describe "the chat whose turn is paused on a question" do
    test "is fixed, and `@ask` stands for it" do
      assert Preview.question_id() == "preview-question"
      assert Preview.question_path() == "/c/preview-question"
      assert Preview.resolve_path("@ask") == "/c/preview-question"
    end

    # PREVIEW-15: one question, a few short options — the card the picture shows
    # is the card a real question renders (UI-75).
    test "asks a question with short options" do
      input = Preview.question_input()

      assert is_binary(input["question"])
      assert input["question"] != ""

      options = input["options"]
      assert length(options) >= 2
      assert length(options) <= 6
      assert Enum.all?(options, &(is_binary(&1) and byte_size(&1) <= 40))
      assert Preview.question_prompt() != ""
    end

    # PREVIEW-15: the turn is a real one — the app's own agent, answered by the
    # scripted provider — so the page renders the wait itself.
    test "starts the chat's own turn, which waits for an answer" do
      start_supervised!(Elia.FakeLLM)
      id = Preview.question_id()
      on_exit(fn -> Elia.Agent.delete(id) end)

      Elia.FakeLLM.push(
        Elia.FakeLLM.assistant([
          Elia.FakeLLM.tool_call("q1", "ask_user", Preview.question_input())
        ])
      )

      Elia.Agent.subscribe(id)

      assert :ok = Preview.start_question()
      assert_receive {:agent, ^id, {:status, :awaiting_input}}, 5000
      assert id in Elia.Agent.awaiting_input()
    end
  end

  # PREVIEW-13
  describe "the colour scheme a preview emulates" do
    test "is the one `ELIA_PREVIEW_THEME` names" do
      assert Preview.theme("dark") == :dark
      assert Preview.theme("light") == :light
    end

    test "is the browser's own default otherwise" do
      assert Preview.theme(nil) == nil
      assert Preview.theme("") == nil
      assert Preview.theme("darkk") == nil
      assert Preview.theme("system") == nil
    end
  end

  # PREVIEW-5
  describe "the chat a preview's link is for" do
    test "is the worktree's own name" do
      assert Preview.worktree_chat("/live/.elia/worktrees/abc123") == "abc123"
      assert Preview.worktree_chat("/live/.elia/worktrees/abc123/") == "abc123"
    end

    test "is nothing outside a chat's worktree" do
      assert Preview.worktree_chat("/live") == nil
      assert Preview.worktree_chat("/home/me/project") == nil
      assert Preview.worktree_chat("/live/.elia/worktrees/") == nil
      assert Preview.worktree_chat("/live/.elia/projects/abc123") == nil
    end
  end

  # PREVIEW-7
  describe "the file a URL names" do
    setup :live_tree

    test "is the picture in that chat's own worktree", %{tree: tree} do
      worktree = worktree(tree)
      dir = Preview.dir(worktree)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "0-root.png"), "png bytes")

      assert {:ok, path} = Preview.path("previewChat", "0-root.png", tree)
      assert path == Path.join(dir, "0-root.png")
    end

    test "is nothing else", %{tree: tree} do
      worktree = worktree(tree)
      dir = Preview.dir(worktree)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "0-root.png"), "png bytes")
      File.mkdir_p!(Path.join(dir, "dir.png"))
      # A file outside the preview dir, and a link to it from inside (EXPL-2).
      File.write!(Path.join(worktree, "secret.png"), "not a preview")
      File.ln_s(Path.join(worktree, "secret.png"), Path.join(dir, "link.png"))

      assert {:error, :not_found} = Preview.path("previewChat", "1-root.png", tree)
      assert {:error, :not_found} = Preview.path("previewChat", "notes.txt", tree)
      assert {:error, :not_found} = Preview.path("previewChat", "dir.png", tree)
      assert {:error, :not_found} = Preview.path("previewChat", "link.png", tree)
      assert {:error, :not_found} = Preview.path("previewChat", "../secret.png", tree)
      assert {:error, :not_found} = Preview.path("previewChat", "sub/0-root.png", tree)
      assert {:error, :not_found} = Preview.path("otherChat", "0-root.png", tree)
      assert {:error, :not_found} = Preview.path("bad/id", "0-root.png", tree)
    end

    test "is not reached through a symlinked preview dir", %{tree: tree} do
      worktree = worktree(tree)
      elsewhere = Path.join(worktree, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.write!(Path.join(elsewhere, "0-root.png"), "png bytes")
      File.ln_s(elsewhere, Preview.dir(worktree))

      assert {:error, :not_found} = Preview.path("previewChat", "0-root.png", tree)
    end
  end

  # PREVIEW-10, PREVIEW-11
  describe "the sample chat" do
    setup :live_tree

    test "is saved with the pieces a transcript renders" do
      assert Preview.seed() == :ok

      messages = Elia.Store.load(Preview.sample_id())
      assert [%{role: :user} | _] = messages

      assistant = Enum.find(messages, &(&1.role == :assistant))
      assert Enum.any?(assistant.content, &(&1.type == :reasoning))

      # TITLE-5, UI-74: the set_title call is one of them; FLINK-4: a read_file
      # call for a file of the workspace is another, so its card links it.
      assert Enum.count(assistant.content, &(&1.type == :tool_call)) == 4

      assert Enum.any?(
               assistant.content,
               &(&1.type == :tool_call and Map.get(&1, :name) == "read_file")
             )

      text = Enum.find_value(assistant.content, &(&1.type == :text && &1.text))
      assert text =~ "## "
      assert text =~ "| --- |"
      assert text =~ "```"
      assert text =~ "]("
      assert text =~ "- "

      results = messages |> Enum.filter(&(&1.role == :tool)) |> Enum.flat_map(& &1.content)
      assert Enum.count(results, & &1.is_error) == 1
      assert Enum.count(results, &(not &1.is_error)) == 3
    end

    # PREVIEW-10, TITLE-1: it is a named chat, so a preview shows the title a
    # chat the agent named shows.
    test "carries a title of its own, set by its own set_title call" do
      assert Preview.seed() == :ok

      title = Elia.Store.load_title(Preview.sample_id())
      assert is_binary(title)

      assert %{title: ^title} =
               Enum.find(Elia.Store.list(100), &(&1.id == Preview.sample_id()))

      call =
        Preview.sample_messages()
        |> Enum.find(&(&1.role == :assistant))
        |> Map.fetch!(:content)
        |> Enum.find(&(Map.get(&1, :name) == "set_title"))

      assert call.input["title"] == title
    end

    # PREVIEW-16: more chats than the chat list's first page holds (UI-4), so the
    # list's "Load more chats" button (UI-84) and its next page can be seen in a
    # picture — and the sample chat is the newest of them, so the page the
    # picture is of still lists it (STORE-12).
    test "seeds more chats than the list's first page, the sample chat newest" do
      assert Preview.seed() == :ok

      listed = Elia.Store.list(1000)

      assert length(listed) > 30
      assert hd(listed).id == Preview.sample_id()
      assert Enum.uniq_by(listed, & &1.id) == listed
    end
  end

  defp worktree(tree) do
    {:ok, path} = Elia.Deploy.ensure_worktree("previewChat", tree)
    path
  end

  # A throwaway live tree, so a preview's worktree, files and data stay out of
  # the scratch workspace the rest of the suite shares.
  defp live_tree(context) do
    tree = Elia.LiveTree.create()
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, tree)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)

      Elia.LiveTree.remove(tree)
    end)

    Map.put(context, :tree, tree)
  end
end
