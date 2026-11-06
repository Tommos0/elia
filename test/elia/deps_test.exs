defmodule Elia.DepsTest do
  # ISOL-7, DEPLOY-10: a worktree's dependency layer — where it lives, that it is
  # made when a command first needs it, and that it goes with the worktree.
  use ExUnit.Case, async: true

  alias Elia.{Deps, Workspace}

  setup do
    root = Workspace.runtime_root()
    id = "deps-#{System.unique_integer([:positive])}"
    dir = Path.join([root, ".elia", "worktrees", id])
    on_exit(fn -> File.rm_rf!(Deps.layer(dir, root)) end)
    %{root: root, dir: dir, id: id}
  end

  # ISOL-7: one layer per worktree, under the live tree's data dir (DEPLOY-2),
  # keyed on the worktree's own name — a chat's id.
  test "a worktree's layer is its own, under the data dir", %{root: root, dir: dir, id: id} do
    assert Deps.layer(dir, root) == Path.join([root, ".elia", "deps_layer", id])
    refute Deps.layer(dir, root) == Deps.layer(dir <> "-other", root)
  end

  # ISOL-7: the upper layer and the overlay's work directory are made when a
  # command first needs them, and nothing is made before that.
  test "opening a layer makes its upper layer and work directory", %{root: root, dir: dir} do
    refute File.exists?(Deps.layer(dir, root))

    assert {:ok, {upper, work}} = Deps.open(dir, root)
    assert upper == Path.join(Deps.layer(dir, root), "upper")
    assert work == Path.join(Deps.layer(dir, root), "work")
    assert File.dir?(upper) and File.dir?(work)

    # Opening it again keeps what a command wrote there: a dependency the chat
    # added is still there for the next command (ISOL-7).
    File.write!(Path.join(upper, "kept"), "x")
    assert {:ok, {^upper, ^work}} = Deps.open(dir, root)
    assert File.read!(Path.join(upper, "kept")) == "x"
  end

  # DEPLOY-10: the layer goes when the worktree does, and removing one that was
  # never made is harmless.
  test "removing a layer removes it, and is harmless when there is none", %{
    root: root,
    dir: dir
  } do
    assert {:ok, _} = Deps.open(dir, root)
    assert :ok = Deps.remove(dir, root)
    refute File.exists?(Deps.layer(dir, root))
    assert :ok = Deps.remove(dir, root)
  end
end
