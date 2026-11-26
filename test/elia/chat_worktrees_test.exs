defmodule Elia.ChatWorktreesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Elia.{Agent, LiveTree, Projects, Store, Worktrees}
  alias Elia.LLM.Message

  # WTREE-3 to WTREE-12: the worktree a chat has, read from the filesystem
  # (WTREE-3, WTREE-4) rather than made by the harness (DEPLOY-1), the sweep that
  # removes the ones nothing needs any more (WTREE-6 to WTREE-12), and what it
  # writes to the log (WTREE-11). Every sweep is handed the folders to read and
  # the moment to measure against, so a test places a worktree an hour in the
  # past instead of waiting for one.
  #
  # WTREE-5 — a finished chat leaves its worktree where it is — is the recipe
  # `AGENTS.md` carries, so it is `self_modification_test.exs`.

  describe "reading the filesystem" do
    # WTREE-3: a chat has a worktree when its project folder holds
    # `tmp/worktrees/<chat id>` (DEPLOY-28) — the live tree for a chat of Elia's
    # own project (DEPLOY-3).
    test "a chat has a worktree when its project folder holds a directory for it" do
      folder = Projects.harness().folder
      assert folder == Elia.Workspace.runtime_root()

      id = Agent.new_id()
      path = Path.join([folder, "tmp", "worktrees", id])
      on_exit(fn -> File.rm_rf!(path) end)

      refute File.dir?(path)
      assert Worktrees.worktrees_in(folder) == []

      File.mkdir_p!(path)
      assert [%{chat_id: ^id, path: ^path, folder: ^folder}] = Worktrees.worktrees_in(folder)

      # A file of that name is not a chat's tree, and a folder that isn't there
      # holds no worktree at all.
      File.rm_rf!(path)
      File.write!(path, "")
      assert Worktrees.worktrees_in(folder) == []
      assert Worktrees.worktrees_in(Path.join(folder, "elsewhere")) == []
    end

    # WTREE-4: the views read the set the last scan found, without a filesystem
    # call of their own — so a worktree a command made is marked, and one a
    # command removed stops being marked, with no restart.
    test "the set the views read follows the filesystem, one folder at a time" do
      folder = Projects.harness().folder
      id = Agent.new_id()
      other = Agent.new_id()
      path = Path.join([folder, "tmp", "worktrees", id])
      other_path = Path.join([folder, "tmp", "worktrees", other])
      on_exit(fn -> File.rm_rf!(path) && File.rm_rf!(other_path) end)

      refute Worktrees.exists?(id)

      File.mkdir_p!(path)
      assert %{chat_id: ^id} = Enum.find(Worktrees.scan(), &(&1.chat_id == id))
      assert Worktrees.exists?(id)
      assert id in Worktrees.ids()

      # The command removed it, and the next scan says so.
      File.rm_rf!(path)
      Worktrees.scan()
      refute Worktrees.exists?(id)

      # A scan of one folder leaves another folder's rows where they are — a
      # project's worktrees are not dropped by reading a different tree.
      File.mkdir_p!(other_path)
      Worktrees.scan(folders: [folder])
      assert Worktrees.exists?(other)
      Worktrees.scan(folders: [Path.join(folder, "nowhere")])
      assert Worktrees.exists?(other)
    end

    # WTREE-10: a scan reads the live tree and the folder of each registered
    # project (PROJ-3, PROJ-4), so a worktree made in another project's tree is
    # swept too.
    test "a scan reads the live tree and every registered project" do
      tree = LiveTree.create()
      on_exit(fn -> LiveTree.remove(tree) end)

      {:ok, project} = Projects.create("Worktree sweep #{Agent.new_id()}", tree)
      on_exit(fn -> Projects.delete(project.id) end)

      live_id = Agent.new_id()
      project_id = Agent.new_id()
      live_path = Path.join([Projects.harness().folder, "tmp", "worktrees", live_id])
      project_path = Path.join([tree, "tmp", "worktrees", project_id])
      for path <- [live_path, project_path], do: File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf!(live_path) && File.rm_rf!(project_path) end)

      found = Worktrees.scan()
      assert live_id in Enum.map(found, & &1.chat_id)
      assert Enum.find(found, &(&1.chat_id == project_id)).folder == tree
    end
  end

  describe "the sweep" do
    # WTREE-6: a chat that has been marked done an hour ago has its worktree
    # removed.
    test "a chat marked done an hour ago loses its worktree" do
      tree = git_tree()
      id = Agent.new_id()
      path = worktree!(tree, id)
      :ok = Store.save(id, [Message.user("the work is in")], done: true)

      sweep = Worktrees.sweep(folders: [tree], now: in_hours(2))

      assert [%{chat_id: ^id}] = sweep.removed
      refute File.exists?(path)
      # WTREE-4: and it is no longer marked.
      refute Worktrees.exists?(id)
    end

    # WTREE-6: an hour is the least age — the chat marked done just now keeps its
    # worktree.
    test "a chat marked done just now keeps its worktree" do
      tree = git_tree()
      id = Agent.new_id()
      path = worktree!(tree, id)
      :ok = Store.save(id, [Message.user("marked done just now")], done: true)

      sweep = Worktrees.sweep(folders: [tree])

      assert %{reason: :recent} = Enum.find(sweep.left, &(&1.chat_id == id))
      assert sweep.removed == []
      assert File.dir?(path)
    end

    # WTREE-12: a chat that is not done keeps its worktree however old it is, so
    # an idle chat still has its tree when it is resumed.
    test "a chat that is not done keeps its worktree however old it is" do
      tree = git_tree()
      id = Agent.new_id()
      path = worktree!(tree, id)
      :ok = Store.save(id, [Message.user("still going")])

      sweep = Worktrees.sweep(folders: [tree], now: in_hours(2))

      assert %{reason: :not_done} = Enum.find(sweep.left, &(&1.chat_id == id))
      assert File.dir?(path)
    end

    # WTREE-6: nothing is removed from under a chat whose turn is running — its
    # worktree is the directory its own commands run in (SHELL-2, SESS-28).
    test "a worktree whose chat is running a turn is left alone" do
      tree = git_tree()
      id = Agent.new_id()
      path = worktree!(tree, id)
      :ok = Store.save(id, [Message.user("working")], done: true)
      # SESS-28: a session of that chat is running a turn.
      {:ok, _} = Registry.register(Elia.Agent.Registry, id, :running)

      sweep = Worktrees.sweep(folders: [tree], now: in_hours(2))

      assert %{reason: :running} = Enum.find(sweep.left, &(&1.chat_id == id))
      assert File.dir?(path)
    end

    # WTREE-7: deleting a chat deletes the chat and nothing else, so its
    # worktree is left for the sweep — which takes it once the worktree itself
    # has been an hour old.
    test "the worktree of a chat that is gone goes once it is an hour old" do
      tree = git_tree()
      old_id = Agent.new_id()
      fresh_id = Agent.new_id()
      old_path = worktree!(tree, old_id)
      fresh_path = worktree!(tree, fresh_id)

      refute Store.load_meta(old_id)
      File.touch!(old_path, System.os_time(:second) - 7_200)

      sweep = Worktrees.sweep(folders: [tree])

      assert [%{chat_id: ^old_id}] = sweep.removed
      refute File.exists?(old_path)
      assert %{reason: :recent} = Enum.find(sweep.left, &(&1.chat_id == fresh_id))
      assert File.dir?(fresh_path)
    end

    # WTREE-8: what a chat left uncommitted is not discarded.
    test "a worktree with uncommitted changes is left where it is" do
      tree = git_tree()
      id = Agent.new_id()
      path = worktree!(tree, id)
      :ok = Store.save(id, [Message.user("done, with work left over")], done: true)
      File.write!(Path.join(path, "wip.txt"), "half done")

      sweep = Worktrees.sweep(folders: [tree], now: in_hours(2))

      assert %{reason: :uncommitted} = Enum.find(sweep.left, &(&1.chat_id == id))
      assert File.dir?(path)
      assert File.read!(Path.join(path, "wip.txt")) == "half done"
    end

    # WTREE-9: the branch `chat/<id>` goes with the worktree only when its work
    # is already in the trunk; a branch holding work that has not landed stays.
    test "the branch goes with the worktree only when its work is in the trunk" do
      tree = git_tree()
      merged_id = Agent.new_id()
      unlanded_id = Agent.new_id()
      merged_path = worktree!(tree, merged_id)
      unlanded_path = worktree!(tree, unlanded_id)

      # A commit on one branch that has not landed on `master`.
      File.write!(Path.join(unlanded_path, "change.txt"), "work")
      LiveTree.commit(unlanded_path, "work")

      :ok = Store.save(merged_id, [Message.user("landed")], done: true)
      :ok = Store.save(unlanded_id, [Message.user("not landed")], done: true)

      sweep = Worktrees.sweep(folders: [tree], now: in_hours(2))

      assert Enum.sort(Enum.map(sweep.removed, & &1.chat_id)) ==
               Enum.sort([merged_id, unlanded_id])

      refute File.exists?(merged_path)
      refute File.exists?(unlanded_path)
      refute branch?(tree, "chat/" <> merged_id)
      assert branch?(tree, "chat/" <> unlanded_id)
    end

    # WTREE-11: every worktree a sweep removes is written to the log, with the
    # branch it deleted or left.
    test "a removal is written to the server's log" do
      tree = git_tree()
      id = Agent.new_id()
      path = worktree!(tree, id)
      :ok = Store.save(id, [Message.user("the work is in")], done: true)

      # The suite logs warnings only (`config/test.exs`), so the level is raised
      # for the removal that is logged at :info — `capture_log/2` puts it back.
      log =
        capture_log(fn ->
          Logger.configure(level: :info)
          Worktrees.sweep(folders: [tree], now: in_hours(2))
        end)

      assert log =~ "worktree swept: #{path}"
      assert log =~ "branch chat/#{id} deleted"
    end

    # WTREE-11: a removal that fails is written to the log too, with what git
    # said, and the tree stays where it is.
    test "a worktree git cannot remove is left, and the log says why" do
      tree = git_tree()
      id = Agent.new_id()
      # A directory where a worktree would be, but not one git knows of.
      path = Path.join([tree, "tmp", "worktrees", id])
      File.mkdir_p!(path)
      File.touch!(path, System.os_time(:second) - 7_200)

      log =
        capture_log(fn ->
          sweep = Worktrees.sweep(folders: [tree])
          assert %{reason: :failed} = Enum.find(sweep.left, &(&1.chat_id == id))
        end)

      assert log =~ "worktree left: #{path}"
      assert File.dir?(path)
    end

    # WTREE-6, WTREE-10: the least age is an hour, the process the application
    # starts is the one that sweeps, and a test run leaves its timer off so a
    # sweep never fires under a test (config/test.exs).
    test "the sweep waits at least an hour, and its timer is off under the tests" do
      assert Worktrees.min_age_ms() == 3_600_000
      assert Worktrees.interval_ms() == 0
      assert Process.whereis(Worktrees)
      # WTREE-4: the server still scans when it comes up, so the views have the
      # set before any interval has passed.
      assert is_list(Worktrees.ids())
    end
  end

  # A tree with the trunk `master` a chat's branch forks from and merges into
  # (DEPLOY-13) and a `tmp/` git does not track (DEPLOY-28).
  defp git_tree do
    tree = LiveTree.create()
    on_exit(fn -> LiveTree.remove(tree) end)
    tree
  end

  # WTREE-3: the worktree a chat's own command made (DEPLOY-28).
  defp worktree!(tree, id) do
    path = Path.join([tree, "tmp", "worktrees", id])
    LiveTree.git!(tree, ["worktree", "add", "-q", "-b", "chat/" <> id, path])
    path
  end

  defp branch?(tree, name) do
    {out, 0} = LiveTree.git(tree, ["branch", "--list", name])
    String.trim(out) != ""
  end

  # WTREE-6: the moment a sweep measures against, so a chat marked done now is an
  # hour old without the test waiting for one.
  defp in_hours(hours), do: DateTime.add(DateTime.utc_now(), hours, :hour)
end
