defmodule Elia.SnapshotTest do
  # Not async: the `max_diff` one test sets is application-wide (SNAP-11), and a
  # snapshot is git work in a tree of its own.
  use ExUnit.Case, async: false

  alias Elia.{LiveTree, Snapshot}

  setup do
    tree = LiveTree.create()
    on_exit(fn -> LiveTree.remove(tree) end)
    %{tree: tree}
  end

  defp write(tree, path, content) do
    file = Path.join(tree, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, content)
  end

  defp refs(tree) do
    tree
    |> LiveTree.git!(["for-each-ref", "--format=%(refname)", "refs/elia/snapshots"])
    |> String.split("\n", trim: true)
  end

  # SNAP-1: a snapshot is the tree as it stands — its tracked files and its
  # untracked ones — built through a temporary index, so nothing of the tree's
  # own git moves: HEAD, the branch, the index, the stash and the working files
  # are as they were.
  test "a snapshot takes the tree as it is and leaves the tree's git alone", %{tree: tree} do
    write(tree, "loose.txt", "loose\n")
    head = LiveTree.head(tree)
    branch = LiveTree.branch(tree)
    status = LiveTree.git!(tree, ["status", "--porcelain"])
    index = File.read!(Path.join(tree, ".git/index"))

    ref = Snapshot.current(tree)

    assert ref =~ "refs/elia/snapshots/"
    # The tree as it stands: the file it tracks and the one its index has never
    # heard of are both in the snapshot.
    assert LiveTree.git!(tree, ["show", "#{ref}:loose.txt"]) =~ "loose"
    assert LiveTree.git!(tree, ["show", "#{ref}:mix.exs"]) =~ "DeployTmp"

    # Nothing of the tree's own git moved.
    assert LiveTree.head(tree) == head
    assert LiveTree.branch(tree) == branch
    assert LiveTree.git!(tree, ["status", "--porcelain"]) == status
    assert File.read!(Path.join(tree, ".git/index")) == index
    assert LiveTree.git!(tree, ["stash", "list"]) == ""
  end

  # SNAP-2: the snapshot is reached by its own ref and by nothing else, so the
  # tree's own history and branches say nothing of it — and the ref keeps the
  # objects it holds.
  test "a snapshot is reachable from its own ref and nothing else", %{tree: tree} do
    ref = Snapshot.current(tree)

    assert refs(tree) == [ref]
    refute LiveTree.git!(tree, ["branch", "--all"]) =~ "elia"
    refute LiveTree.git!(tree, ["log", "--format=%s"]) =~ "snapshot"
    assert LiveTree.git!(tree, ["cat-file", "-t", ref]) |> String.trim() == "commit"
    assert LiveTree.sha(tree, ref) =~ ~r/^[0-9a-f]{40}$/
  end

  # SNAP-3: untracked files are in the snapshot, and what the tree's own ignore
  # rules exclude is not.
  test "a snapshot holds untracked files and leaves ignored ones out", %{tree: tree} do
    write(tree, "untracked.txt", "u\n")
    write(tree, "_build/junk.txt", "junk\n")
    write(tree, "tmp/junk.txt", "junk\n")

    ref = Snapshot.current(tree)
    names = LiveTree.git!(tree, ["ls-tree", "-r", "--name-only", ref])

    assert names =~ "untracked.txt"
    refute names =~ "_build"
    refute names =~ "tmp/"
  end

  # SNAP-5: a tree with no snapshot gets one, and a tree that has one keeps it,
  # so a chat's first command in a tree is compared with the tree it found.
  test "a tree with no snapshot gets one, and a tree with one keeps it", %{tree: tree} do
    assert refs(tree) == []

    first = Snapshot.current(tree)

    assert refs(tree) == [first]
    assert Snapshot.current(tree) == first
    assert refs(tree) == [first]
  end

  # SNAP-4: a tree that hasn't moved is the snapshot it has — no second ref, and
  # a pair of one snapshot is a call that changed nothing.
  test "a tree that hasn't moved keeps the snapshot it has", %{tree: tree} do
    first = Snapshot.current(tree)

    pair = Snapshot.record(tree, first)

    assert pair.from == first
    assert pair.to == first
    assert pair.files == []
    assert refs(tree) == [first]
  end

  # SNAP-10: the files a pair differs in, each with the status that says what the
  # call did to it.
  test "a pair's files carry the status of each", %{tree: tree} do
    write(tree, "gone.txt", "gone\n")
    LiveTree.commit(tree, "a file to delete")

    from = Snapshot.current(tree)

    write(tree, "new.txt", "new\n")
    File.rm!(Path.join(tree, "gone.txt"))
    LiveTree.git!(tree, ["mv", "mix.exs", "mix2.exs"])

    pair = Snapshot.record(tree, from)

    assert %{status: "added", path: "new.txt"} in pair.files
    assert %{status: "deleted", path: "gone.txt"} in pair.files
    assert %{status: "renamed", path: "mix2.exs"} in pair.files
  end

  # SNAP-12: a pair's diff is read from its two snapshots, so it still says what
  # its own call did after later calls have moved the tree on.
  test "a pair's diff is read from its snapshots, not from the tree", %{tree: tree} do
    write(tree, "a.txt", "one\n")
    from = Snapshot.current(tree)

    write(tree, "a.txt", "two\n")
    pair = Snapshot.record(tree, from)

    write(tree, "a.txt", "three\n")
    diff = pair.diff

    assert diff =~ "-one"
    assert diff =~ "+two"
    refute diff =~ "three"
  end

  # SNAP-11: a diff longer than `max_diff` is cut, with a marker saying how much
  # was left out.
  test "a diff longer than max_diff is cut with a marker", %{tree: tree} do
    previous = Application.get_env(:elia, Elia.Snapshot)
    on_exit(fn -> Application.put_env(:elia, Elia.Snapshot, previous) end)
    Application.put_env(:elia, Elia.Snapshot, max_diff: 40, timeout: 30_000)

    from = Snapshot.current(tree)
    write(tree, "big.txt", String.duplicate("x", 400) <> "\n")
    pair = Snapshot.record(tree, from)

    diff = pair.diff

    assert diff =~ "more characters not shown"
    assert String.length(diff) < 200
  end

  # SNAP-9: a directory that is no git work tree, and one that is not there at
  # all, have no snapshot — nothing raises, and the caller carries on.
  test "a directory that is no git work tree has no snapshot" do
    dir = Path.join(System.tmp_dir!(), "elia-no-tree-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert Snapshot.current(dir) == nil
    assert Snapshot.record(dir, nil) == nil
    refute Snapshot.current(Path.join(dir, "missing"))
  end
end
