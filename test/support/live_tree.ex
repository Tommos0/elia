defmodule Elia.LiveTree do
  @moduledoc """
  A throwaway live tree for tests (DEPLOY-2): a tiny git repo, checked out on the
  branch `live`, holding a one-module Mix project, so a deploy's `mix test` runs
  in a chat's worktree for real (DEPLOY-5).

      tree = Elia.LiveTree.create()
      on_exit(fn -> Elia.LiveTree.remove(tree) end)

  The helpers below all take the directory and run `git` in it.
  """

  @doc "Creates the live tree in a temp dir. `remove/1` when the test is done."
  @spec create() :: binary()
  def create do
    dir = Path.join(System.tmp_dir!(), "elia-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))

    File.write!(Path.join(dir, ".gitignore"), "/_build/\n/deps/\n/.elia/\n")

    write(dir, "mix.exs", """
    defmodule DeployTmp.MixProject do
      use Mix.Project

      def project do
        [app: :deploy_tmp, version: "0.1.0", elixir: "~> 1.17", deps: []]
      end
    end
    """)

    write(dir, "lib/deploy_tmp.ex", """
    defmodule DeployTmp do
      def hello, do: :hello
    end
    """)

    write(dir, "test/test_helper.exs", "ExUnit.start()\n")

    write(dir, "test/deploy_tmp_test.exs", """
    defmodule DeployTmpTest do
      use ExUnit.Case

      test "the project builds and its tests pass" do
        assert DeployTmp.hello() == :hello
      end
    end
    """)

    {_, 0} = git(dir, ["init", "--quiet"])
    {_, 0} = git(dir, ["add", "-A"])
    {_, 0} = git(dir, ["commit", "-q", "-m", "start"])
    # The live tree is on the branch a deploy forks from and merges into.
    {_, 0} = git(dir, ["branch", "-m", "live"])
    dir
  end

  @doc "Removes a live tree, and every worktree in it."
  def remove(dir), do: File.rm_rf!(dir)

  def git(dir, args) do
    System.cmd(
      "git",
      ["-c", "user.name=T", "-c", "user.email=t@example.com" | args],
      cd: dir,
      stderr_to_stdout: true
    )
  end

  def git!(dir, args) do
    {out, 0} = git(dir, args)
    out
  end

  def head(dir), do: dir |> git!(["rev-parse", "HEAD"]) |> String.trim()

  def branch(dir), do: dir |> git!(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()

  def commit(dir, message) do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", message])
    head(dir)
  end

  @doc "A change on a chat's branch, unique to the test, committed there."
  @spec work!(binary()) :: binary()
  def work!(path) do
    name = "deploy_#{System.unique_integer([:positive])}"
    file = "lib/#{name}.ex"
    File.write!(Path.join(path, file), "defmodule #{Macro.camelize(name)} do\nend\n")
    commit(path, "chat work")
    file
  end

  defp write(dir, path, content) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end
end
