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

  # PREVIEW-17
  describe "the chat whose terminal is running" do
    test "is fixed, and `@terminal` stands for it" do
      assert Preview.terminal_id() == "preview-terminal"
      assert Preview.terminal_path() == "/c/preview-terminal"
      assert Preview.resolve_path("@terminal") == "/c/preview-terminal"
    end

    # PREVIEW-17: the terminal is a real one — the app's own session (TERM-1) —
    # so the row a picture shows is a row the app marked itself (UI-111,
    # TERM-41). Without tmux there is no terminal to run (TERM-29), so the chat
    # is still saved and only the mark is missing.
    @tag skip: if(Elia.Terminal.available?(), do: false, else: "tmux is not installed")
    test "saves the chat and starts its own terminal" do
      id = Preview.terminal_id()
      on_exit(fn -> Elia.Agent.delete(id) end)

      assert Preview.start_terminal() == :ok

      assert id in Elia.Terminal.running_ids()
      assert {:ok, %{running: true}} = Elia.Terminal.status(id)
      assert Enum.any?(Elia.Store.list(1000), &(&1.id == id))
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

  # PREVIEW-7
  describe "the file a URL names" do
    setup :live_tree

    # PREVIEW-7, DEPLOY-1: a chat's pictures are in the tmp/preview/ of the tree
    # the preview ran in — its project's folder, which is where a chat's own
    # workspace is now that the harness makes no worktree for it.
    test "is the picture in the tree the preview ran in", %{tree: tree} do
      dir = Preview.dir(tree)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "0-root.png"), "png bytes")

      assert {:ok, path} = Preview.path("previewChat", "0-root.png", tree)
      assert path == Path.join(dir, "0-root.png")
    end

    # PREVIEW-7, DEPLOY-28: a chat that made itself a worktree inside that folder
    # wrote its pictures in the worktree's own tmp/preview/, which is the one
    # served first; one that isn't there is served from the folder's own.
    test "is the picture in the worktree the chat made for itself", %{tree: tree} do
      worktree = chat_worktree(tree)
      dir = Preview.dir(worktree)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "0-root.png"), "the worktree's")
      File.mkdir_p!(Preview.dir(tree))
      File.write!(Path.join(Preview.dir(tree), "0-root.png"), "the folder's own")
      File.write!(Path.join(Preview.dir(tree), "1-files.png"), "the folder's own")

      assert {:ok, path} = Preview.path("previewChat", "0-root.png", tree)
      assert path == Path.join(dir, "0-root.png")
      assert File.read!(path) == "the worktree's"

      assert {:ok, path} = Preview.path("previewChat", "1-files.png", tree)
      assert path == Path.join(Preview.dir(tree), "1-files.png")
    end

    test "is nothing else", %{tree: tree} do
      dir = Preview.dir(tree)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "0-root.png"), "png bytes")
      File.mkdir_p!(Path.join(dir, "dir.png"))
      # A file outside the preview dir, and a link to it from inside (EXPL-2).
      File.write!(Path.join(tree, "secret.png"), "not a preview")
      File.ln_s(Path.join(tree, "secret.png"), Path.join(dir, "link.png"))

      assert {:error, :not_found} = Preview.path("previewChat", "1-root.png", tree)
      assert {:error, :not_found} = Preview.path("previewChat", "notes.txt", tree)
      assert {:error, :not_found} = Preview.path("previewChat", "dir.png", tree)
      assert {:error, :not_found} = Preview.path("previewChat", "link.png", tree)
      assert {:error, :not_found} = Preview.path("previewChat", "../secret.png", tree)
      assert {:error, :not_found} = Preview.path("previewChat", "sub/0-root.png", tree)
      # A chat id that isn't one is a 404 whatever is on disk (PREVIEW-7); a
      # valid one shares its project's own tmp/preview/, which is that tree's.
      assert {:ok, _} = Preview.path("otherChat", "0-root.png", tree)
      assert {:error, :not_found} = Preview.path("bad/id", "0-root.png", tree)
    end

    # A chat's own worktree is where its pictures are, not a way out of
    # tmp/preview/: a symlinked preview dir reaches nothing (EXPL-2, PREVIEW-7).
    test "is not reached through a symlinked preview dir", %{tree: tree} do
      worktree = chat_worktree(tree)
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

      # TITLE-5, UI-74: the `set_title` call is one of them; FLINK-4: a `cd` call
      # for a directory of the workspace is another, so its card links it;
      # UI-43: a `spawn_task` call is a third, with its brief under it;
      # VISION-16: a `view_image` call is one whose card shows the picture it
      # looked at.
      assert Enum.count(assistant.content, &(&1.type == :tool_call)) == 6

      assert Enum.any?(
               assistant.content,
               &(&1.type == :tool_call and Map.get(&1, :name) == "cd" and
                   is_binary(&1.input["path"]))
             )

      # UI-43, SUBTASK-2: a spawn is a call like any other, with a briefing
      # input and the result a spawn returns.
      assert Enum.any?(
               assistant.content,
               &(&1.type == :tool_call and Map.get(&1, :name) == "spawn_task" and
                   is_binary(&1.input["brief"]))
             )

      text = Enum.find_value(assistant.content, &(&1.type == :text && &1.text))
      assert text =~ "## "
      assert text =~ "| --- |"
      assert text =~ "```"
      assert text =~ "]("
      assert text =~ "- "

      results = messages |> Enum.filter(&(&1.role == :tool)) |> Enum.flat_map(& &1.content)
      assert Enum.count(results, & &1.is_error) == 1
      assert Enum.count(results, &(not &1.is_error)) == 5

      # VISION-12, VISION-16: the look's result records the picture's path, media
      # type and size, which is what the card renders the picture from and what
      # the request counts (VISION-10).
      assert %{image: %{path: picture, media_type: "image/png", size: size}} =
               Enum.find(results, &(&1.tool_call_id == "call-preview-6"))

      assert File.regular?(Path.join(File.cwd!(), picture))
      assert size == File.stat!(Path.join(File.cwd!(), picture)).size

      # SNAP-6, SNAP-10: the `shell` call's result carries the pair of snapshots
      # bracketing it, so its card shows the files the call changed and their
      # diff — a sample writes those shapes rather than taking a snapshot
      # (PREVIEW-10).
      assert %{snapshot: %{files: [_ | _], diff: diff}} =
               Enum.find(results, &(&1.tool_call_id == "call-preview-1"))

      assert diff =~ "--- a/"
      assert diff =~ "+++ b/"
    end

    # MSGAT-9: each message carries the moment it arrived, oldest first, so a
    # picture of the chat shows the times the transcript puts under its items.
    test "carries a stamp on every message" do
      assert Preview.seed() == :ok

      stamps = Preview.sample_id() |> Elia.Store.load() |> Enum.map(&Elia.LLM.Message.at/1)
      assert length(stamps) == length(Preview.sample_messages())
      assert Enum.all?(stamps, &match?(%DateTime{}, &1))
      assert stamps == Enum.sort(stamps, DateTime)
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

    # PREVIEW-18: a chat with sub-tasks of its own, so the dropdown the list
    # draws (UI-112, UI-113) is in a picture, `@subtasks` naming its page.
    test "seeds a chat with sub-tasks, near the top of the list" do
      assert Preview.seed() == :ok

      parent = Preview.subtasks_id()
      assert Preview.resolve_path("@subtasks") == "/c/#{parent}"

      listed = Enum.map(Elia.Store.list(1000), & &1.id)
      assert parent in listed

      for id <- ["preview-task-1", "preview-task-2"] do
        assert id in listed
        # STORE-16, STORE-17: the task metadata that nests it under the parent.
        assert %{parent_id: ^parent} = Elia.Store.load_task(id)
      end

      # Near the top of the list — below the sample chat, which stays the newest
      # (PREVIEW-10, PREVIEW-16).
      assert Enum.find_index(listed, &(&1 == Preview.sample_id())) == 0
      assert Enum.find_index(listed, &(&1 == parent)) == 1
    end
  end

  # DEPLOY-28: the worktree a chat makes for itself, inside its project's folder
  # — the harness makes none, so the test makes the one a chat would.
  defp chat_worktree(tree) do
    path = Path.join([tree, "tmp", "worktrees", "previewChat"])
    File.mkdir_p!(path)
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
