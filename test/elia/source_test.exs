defmodule Elia.SourceTest do
  use ExUnit.Case, async: true

  alias Elia.Source

  @source ~S"""
  defmodule Alpha do
    defmodule Nested do
      def run(a), do: a
    end

    def plain(a, b \\ 1), do: {a, b}
    defp guarded(a) when is_integer(a), do: a
    defmacro mac(x), do: x
    defdelegate dele(a, b), to: Other
    def noargs do
      :ok
    end
  end
  """

  # FUNC-4: a workspace is any directory, and its source is its own.
  defp workspace(files) do
    root = Path.join(System.tmp_dir!(), "elia_source_#{System.unique_integer([:positive])}")

    for {name, content} <- files do
      path = Path.join(root, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # FUNC-5, FUNC-6, FUNC-10: each definition's own head line, the arities its
  # defaults make, and the module it is inside — a definition within another
  # module belongs to the inner one, and a file whose path doesn't match the
  # module's name is read as it is.
  test "reads each definition's module, line and arities" do
    root = workspace(%{"lib/alpha.ex" => @source})

    assert Source.definitions(root) == %{
             "Alpha.Nested.run/1" => %{path: "lib/alpha.ex", line: 3},
             "Alpha.plain/1" => %{path: "lib/alpha.ex", line: 6},
             "Alpha.plain/2" => %{path: "lib/alpha.ex", line: 6},
             "Alpha.guarded/1" => %{path: "lib/alpha.ex", line: 7},
             "Alpha.mac/1" => %{path: "lib/alpha.ex", line: 8},
             "Alpha.dele/2" => %{path: "lib/alpha.ex", line: 9},
             "Alpha.noargs/0" => %{path: "lib/alpha.ex", line: 10}
           }
  end

  # FUNC-4, FUNC-6: a definition is found by module, name *and* arity, so an
  # arity a default argument doesn't reach names nothing.
  test "a definition is found by module, name and arity" do
    root = workspace(%{"lib/alpha.ex" => @source})

    assert Source.definition(root, "Alpha", "plain", 1) == %{path: "lib/alpha.ex", line: 6}
    assert Source.definition(root, "Alpha", "plain", 2) == %{path: "lib/alpha.ex", line: 6}
    assert Source.definition(root, "Alpha", "plain", 0) == nil
    assert Source.definition(root, "Alpha", "plain", 3) == nil
    assert Source.definition(root, "Alpha.Nested", "run", 1) == %{path: "lib/alpha.ex", line: 3}
    # FUNC-5: `run` is the inner module's, not the outer one's.
    assert Source.definition(root, "Alpha", "run", 1) == nil
    # FUNC-9: Elixir's own and a dependency's functions are not the workspace's.
    assert Source.definition(root, "Enum", "map", 2) == nil
  end

  # FUNC-10: a module several files define is the one whose path sorts first, so
  # a function only another file defines is not one the workspace defines.
  test "a module several files define is the one whose path sorts first" do
    root =
      workspace(%{
        "lib/b/second.ex" => "defmodule Twice do\n  def b, do: 2\nend\n",
        "lib/a/first.ex" => "defmodule Twice do\n  def a, do: 1\nend\n"
      })

    assert Source.definition(root, "Twice", "a", 0) == %{path: "lib/a/first.ex", line: 2}
    assert Source.definition(root, "Twice", "b", 0) == nil
  end

  # FUNC-9: the workspace's own `.ex`/`.exs` files — not a dependency's, a build
  # output's, Elia's own data's, a worktree's (DEPLOY-28) or a file nothing can
  # be parsed from — and a symlink is not followed.
  test "reads only the workspace's own source" do
    root =
      workspace(%{
        "lib/real.ex" => "defmodule Real do\n  def go, do: :ok\nend\n",
        "script.exs" => "defmodule Script do\n  def go, do: :ok\nend\n",
        "deps/dep/lib/dep.ex" => "defmodule Dep do\n  def go, do: :ok\nend\n",
        "_build/lib/built.ex" => "defmodule Built do\n  def go, do: :ok\nend\n",
        ".elia/x/hidden.ex" => "defmodule Hidden do\n  def go, do: :ok\nend\n",
        "tmp/worktrees/w/lib/wt.ex" => "defmodule Worktree do\n  def go, do: :ok\nend\n",
        "assets/node_modules/x/x.ex" => "defmodule Vendored do\n  def go, do: :ok\nend\n",
        "lib/broken.ex" => "defmodule Broken do\n",
        "lib/notes.txt" => "defmodule Notes do\n  def go, do: :ok\nend\n"
      })

    assert Map.keys(Source.definitions(root)) |> Enum.sort() == ["Real.go/0", "Script.go/0"]

    for module <- ["Dep", "Built", "Hidden", "Worktree", "Vendored", "Broken", "Notes"] do
      assert Source.definition(root, module, "go", 0) == nil, module
    end

    # A symlink to a file of the workspace is not a second copy of it.
    File.ln_s!(Path.join(root, "lib/real.ex"), Path.join(root, "lib/alias.ex"))
    assert Map.keys(Source.definitions(root)) |> Enum.sort() == ["Real.go/0", "Script.go/0"]
  end

  # FUNC-4: the check is made as the message is rendered, so it follows a
  # function that appears or goes.
  test "a definition that appears is seen" do
    root = workspace(%{"lib/real.ex" => "defmodule Real do\n  def go, do: :ok\nend\n"})

    assert Source.definition(root, "Real", "go", 0) != nil
    assert Source.definition(root, "Real", "stop", 0) == nil

    File.write!(
      Path.join(root, "lib/real.ex"),
      "defmodule Real do\n  def go, do: :ok\n  def stop(a), do: a\nend\n"
    )

    assert Source.definition(root, "Real", "stop", 1) == %{path: "lib/real.ex", line: 3}

    # A file that goes takes its definitions with it.
    File.rm!(Path.join(root, "lib/real.ex"))
    assert Source.definition(root, "Real", "go", 0) == nil
  end
end
