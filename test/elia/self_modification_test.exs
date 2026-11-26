defmodule Elia.SelfModificationTest do
  use ExUnit.Case, async: false

  alias Elia.{Harness, Workspace}
  alias Elia.Skills.Folder

  defp in_root(path), do: Path.join(Workspace.root(), path)

  # `count` links in `<root>/<dir>`: `l0` points at a directory outside the
  # workspace holding `file.txt`, and each `l<n>` at `l<n-1>`, so a path
  # through `l<n>` takes `n + 1` links to resolve.
  defp link_chain(dir, count) do
    outside = Path.join(System.tmp_dir!(), "elia-chain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "file.txt"), "not for the tools")
    File.mkdir_p!(in_root(dir))
    File.ln_s!(outside, in_root("#{dir}/l0"))
    for n <- 1..(count - 1)//1, do: File.ln_s!("l#{n - 1}", in_root("#{dir}/l#{n}"))
    %{outside: outside}
  end

  # One throwaway project for the whole module (VERIFY-8, VERIFY-9): the runs
  # below are real `mix test` runs, and sharing one tree keeps them to a single
  # compile — and costs the other tests in the module nothing but a temp dir.
  setup_all do
    %{hangs_tree: hanging_tree()}
  end

  describe "workspace policy" do
    # WS-2: paths are fully expanded before they are classified, so `..` can't
    # escape the workspace.
    test "classifies paths" do
      assert {_, :extension} = Workspace.resolve("skills/foo/SKILL.md")
      assert {_, :core} = Workspace.resolve("lib/elia/agent.ex")
      assert {_, :protected} = Workspace.resolve(".git/config")
      assert {_, :protected} = Workspace.resolve("deps/req/mix.exs")
      assert {_, :outside} = Workspace.resolve("../elsewhere")
      assert {_, :outside} = Workspace.resolve("/etc/passwd")
      assert {_, :outside} = Workspace.resolve("skills/../../etc")
    end

    # WS-3: a path under `skills/` that goes through a symlink is `:core`, so a
    # link can't give extension rights to files elsewhere.
    test "symlinks under skills/ are treated as core" do
      File.mkdir_p!(in_root("skills"))
      File.mkdir_p!(in_root("lib"))
      File.ln_s!(in_root("lib"), in_root("skills/sneaky"))
      assert {_, :core} = Workspace.resolve("skills/sneaky/agent.ex")
    after
      File.rm(in_root("skills/sneaky"))
    end

    # WS-5: the classes are decided on the path as written, so a caller that
    # must not be fooled by a link asks for the real location instead.
    test "the real location follows symlinks, and a missing path by its ancestor" do
      outside = Path.join(System.tmp_dir!(), "elia-real-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "file.txt"), "x")
      File.mkdir_p!(in_root("real"))
      File.ln_s!(outside, in_root("real/link"))
      File.ln_s!(Path.join(outside, "gone.txt"), in_root("real/broken"))

      on_exit(fn ->
        File.rm_rf!(in_root("real"))
        File.rm_rf!(outside)
      end)

      assert Workspace.real_location(in_root("real/link/file.txt")) ==
               Path.join(outside, "file.txt")

      # A path that isn't there yet is judged by where it would land.
      assert Workspace.real_location(in_root("real/link/new/deep.txt")) ==
               Path.join([outside, "new", "deep.txt"])

      # `File.realpath/1` gives up on a link whose target is missing; the link
      # is followed by hand instead.
      assert Workspace.real_location(in_root("real/broken")) ==
               Path.join(outside, "gone.txt")

      assert Workspace.real_location(in_root("real")) == in_root("real")
    end

    # WS-6: eight links are followed for one path, each counting once; past
    # that, or round a loop, the path has no real location.
    test "a link chain past the bound, or a loop, is unresolvable" do
      %{outside: outside} = link_chain("chain", 9)

      on_exit(fn ->
        File.rm_rf!(in_root("chain"))
        File.rm_rf!(outside)
      end)

      # `chain/l7` is eight links to the directory outside: within the bound.
      assert Workspace.real_location(in_root("chain/l7/file.txt")) ==
               Path.join(outside, "file.txt")

      # `chain/l8` is nine, and is never taken for a path inside the workspace.
      assert Workspace.real_location(in_root("chain/l8/file.txt")) == :unresolvable
      assert Workspace.real_location(in_root("chain/l8/new.txt")) == :unresolvable

      File.ln_s!("loop-b", in_root("chain/loop-a"))
      File.ln_s!("loop-a", in_root("chain/loop-b"))
      assert Workspace.real_location(in_root("chain/loop-a/file.txt")) == :unresolvable
    end
  end

  describe "folder skills" do
    setup do
      dir = in_root("skills/tmp-skill")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    # FOLDER-1, FOLDER-2, FOLDER-4, FOLDER-5: a directory under `skills/` is a
    # candidate skill and must hold a `SKILL.md` with `name` and `description`
    # frontmatter; `tools.json` is a list of entries that need `description` and
    # `command` too; and each load failure says what is wrong.
    test "reports helpful errors", %{dir: dir} do
      assert {:error, "cannot read SKILL.md" <> _} = Folder.load(dir)

      File.write!(Path.join(dir, "SKILL.md"), "no frontmatter")
      assert {:error, "SKILL.md must start" <> _} = Folder.load(dir)

      File.write!(Path.join(dir, "SKILL.md"), "---\nname: Bad Name\ndescription: x\n---\n")
      assert {:error, "name \"Bad Name\" must match" <> _} = Folder.load(dir)

      File.write!(Path.join(dir, "SKILL.md"), "---\nname: ok\ndescription: x\n---\nBody")
      File.write!(Path.join(dir, "tools.json"), ~s([{"name": "t"}]))
      assert {:error, "tools.json entry 0: missing description"} = Folder.load(dir)
    end

    # SKILL-6: `reload_skills` rescans the skills folder and answers with the
    # skills it loaded and their tool names, plus any folder that failed.
    test "reload_skills answers with the loaded skills and a folder that failed", %{dir: dir} do
      File.write!(
        Path.join(dir, "SKILL.md"),
        "---\nname: tmp-skill\ndescription: x\n---\nUse it."
      )

      File.write!(
        Path.join(dir, "tools.json"),
        ~s([{"name": "tmp_tool", "description": "d", "command": "echo hi"}])
      )

      [tool] = Enum.filter(Elia.Skills.Harness.tools(), &(&1.name == "reload_skills"))

      # The registry is shared: another test's leftover folder can make the
      # reload answer `{:error, …}` with its own failure, so the answer that
      # matters is this test's own line, not the status.
      {_status, output} = tool.run.(%{})
      assert output =~ "- tmp-skill (tools: tmp_tool)"

      # A folder that fails to load is named with its reason instead.
      File.write!(Path.join(dir, "SKILL.md"), "no frontmatter")
      assert {:error, output} = tool.run.(%{})
      assert output =~ "skills/tmp-skill"
    after
      Elia.Skills.reload()
    end

    test "registry reports load errors and conflicts", %{dir: dir} do
      File.write!(Path.join(dir, "SKILL.md"), "---\nname: shell\ndescription: dup\n---\n")
      %{errors: errors} = Elia.Skills.reload()
      assert {"skills/tmp-skill", "a skill named shell already exists"} in errors
    after
      File.rm_rf!(dir)
      Elia.Skills.reload()
    end
  end

  describe "the instruction a chat in Elia's own project carries" do
    # DEPLOY-28, DEPLOY-29, DEPLOY-30, DEPLOY-37, SHELL-14: the instruction tells
    # a chat its workspace is the project's folder and no worktree was made for
    # it, how to make its own — forked from the trunk, on the branch its chat id
    # names, with the copies that save its first command minutes — how its work
    # lands, what to do when it can't, and that the live tree is left clean
    # (DEPLOY-37). `AGENTS.md` is its only home: the
    # `self-modification` skill that carried a second copy is retired (SKILL-9,
    # PROJ-17), so there is one place to change it.
    test "the project's AGENTS.md carries the worktree recipe" do
      agents = File.read!("AGENTS.md")

      assert agents =~ "works in the project's folder"
      assert agents =~ "Don't write anything there"
      # DEPLOY-37: the live tree stays clean — a draft written there before the
      # worktree existed moves into it and the tree is put back, and a deploy
      # puts aside what is left.
      assert agents =~ "git status --porcelain"
      assert agents =~ "aside in a git stash"
      assert agents =~ "git worktree add"
      assert agents =~ "tmp/worktrees/"
      assert agents =~ "chat/$ELIA_CHAT_ID"
      assert agents =~ "deps _build"
      assert agents =~ "cp -a assets/node_modules"
      assert agents =~ "ELIA_CHAT_ID"
      # DEPLOY-13: merging its own branch into the trunk is where the agent's
      # part ends.
      assert agents =~ "git push . HEAD:master"
      # ...and it says what to do when the worktree or the merge can't be made
      # (DEPLOY-30).
      assert agents =~ "ask the user"
      assert agents =~ "rather than editing the live tree"
    end

    # WTREE-5, DEPLOY-28: a finished chat leaves its worktree and its branch
    # where they are — the server's sweep removes them (WTREE-6) — so the
    # recipe ends at the merge and says so, rather than removing the tree the
    # chat no longer needs.
    test "the worktree recipe leaves a finished chat's worktree to the sweep" do
      agents = File.read!("AGENTS.md")

      assert agents =~ "leave the worktree and its branch where they are"
      assert agents =~ "the server sweep removes them"
      assert agents =~ "WTREE-5"
      # WTREE-9: the branch goes only once its work is in the trunk, and the
      # recipe says which condition that is.
      assert agents =~ "deletes `chat/<chat id>` only when that branch is in `master`"
      # The chat no longer removes what it made: the recipe has no removal step.
      refute agents =~ "git worktree remove"
      refute agents =~ "git branch -D"
    end
  end

  describe "run_tests" do
    # VERIFY-2: only arguments that can't run arbitrary code are accepted.
    test "rejects arguments that could run arbitrary code" do
      assert {:error, "Unsupported test argument: skills/x_test.exs"} =
               Harness.run_tests(["skills/x_test.exs"])

      assert {:error, _} = Harness.run_tests(["test/../skills/x_test.exs"])
      assert {:error, _} = Harness.run_tests(["--seed", "1; rm -rf /"])
      assert {:error, _} = Harness.run_tests(["--include-anything"])
    end

    # VERIFY-1, VERIFY-8: the per-test timeout is `mix test`'s own, so a test that
    # sets no timeout of its own fails the run instead of holding it. A real run
    # in a throwaway project, because the flag has to reach ExUnit.
    test "the per-test timeout reaches ExUnit", %{hangs_tree: tree} do
      assert {:error, output} =
               Harness.run_tests(["test/hangs_test.exs"], tree,
                 jail: false,
                 timeout_seconds: 120,
                 test_timeout_ms: 1_000
               )

      assert output =~ "timed out after 1000ms"
      assert output =~ "[exit: 2]"
    end

    # VERIFY-9, VERIFY-10: the run's own timeout is the configured one, a call
    # may ask for another within the ceiling — and a run stopped by it says so
    # and names the lever, rather than reading as a suite that failed.
    test "the run's timeout is the configured one, clamped to the configured maximum", %{
      hangs_tree: tree
    } do
      previous = Application.get_env(:elia, Harness, [])

      Application.put_env(:elia, Harness, Keyword.merge(previous, timeout: 2, max_timeout: 3))
      on_exit(fn -> Application.put_env(:elia, Harness, previous) end)

      # A call that gives none gets the default, and it holds however long the
      # suite would otherwise run.
      assert {:error, output} = Harness.run_tests(["test/hangs_test.exs"], tree, jail: false)
      assert output =~ "[exit: timeout after 2s]"
      assert output =~ "stopped by its timeout (2s)"
      assert output =~ "`timeout_seconds`"

      # A call that asks for more than the maximum runs with the maximum, and is
      # told which ceiling it hit (SHELL-10).
      assert {:error, output} =
               Harness.run_tests(["test/hangs_test.exs"], tree,
                 jail: false,
                 timeout_seconds: 9_999
               )

      assert output =~ "[exit: timeout after 3s (asked for 9999s, the most is 3s)]"
      assert output =~ "stopped by its timeout (3s)"
    end

    # VERIFY-9: a timeout that isn't one changes nothing and runs nothing.
    test "rejects a timeout that isn't a whole number of at least 1" do
      assert {:error, output} = Harness.run_tests([], "test", timeout_seconds: 0)

      assert output =~ "timeout_seconds must be a whole number of at least 1"
      assert output =~ "the default is 600 and the most is 1800"

      assert {:error, output} = Harness.run_tests([], "test", test_timeout_ms: -1)

      assert output =~ "test_timeout_ms must be a whole number of at least 1"
      assert output =~ "the default is 60000 and the most is 600000"
    end

    # VERIFY-8, VERIFY-9: the settings say what a run uses, whatever the code
    # around them does.
    test "the timeouts are settings with defaults" do
      for key <- [:timeout, :max_timeout, :test_timeout, :max_test_timeout] do
        assert is_integer(Harness.timeout_config(key))
        assert Harness.timeout_config(key) > 0
      end

      assert Harness.timeout_config(:timeout) <= Harness.timeout_config(:max_timeout)

      assert Harness.timeout_config(:test_timeout) <=
               Harness.timeout_config(:max_test_timeout)
    end
  end

  # A throwaway Mix project (DEPLOY-2) with a test that hangs, so a run in it can
  # only end by a timeout (VERIFY-8, VERIFY-9).
  defp hanging_tree do
    tree = Elia.LiveTree.create()

    File.write!(Path.join(tree, "test/hangs_test.exs"), """
    defmodule HangsTest do
      use ExUnit.Case, async: false

      test "hangs" do
        Process.sleep(60_000)
      end
    end
    """)

    on_exit(fn -> Elia.LiveTree.remove(tree) end)
    tree
  end
end
