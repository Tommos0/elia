defmodule EliaWeb.FunctionLinksTest do
  use ExUnit.Case, async: false

  alias Elia.Workspace
  alias EliaWeb.FunctionLinks

  # STORE-5: a chat id is 12 URL-safe characters.
  @chat "funclinkchat"
  @dir "function_links_fixture"

  @source ~S"""
  defmodule Sample do
    def run(a, b \\ 1), do: {a, b}
    defp hidden(a), do: a
  end
  """

  # FUNC-4: a mention resolves in the workspace the chat works in (PROJ-12,
  # FLINK-5); the fixture is a workspace of its own inside this one.
  setup do
    root = Path.join(Workspace.root(), @dir)
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/sample.ex"), @source)
    on_exit(fn -> File.rm_rf!(root) end)

    %{links: %{chat_id: @chat, root: root}}
  end

  # FUNC-4: the link is that file's Files page at the function's own line, in the
  # chat's workspace — the same page a file mention opens (FLINK-5, EXPL-27).
  test "links a function the workspace defines, at its line", %{links: links} do
    # FLINK-5, EXPL-17: the path is relative to the chat's own workspace, which
    # is the fixture here.
    expected = fn line -> "/files?chat=#{@chat}&path=lib%2Fsample.ex&line=#{line}" end

    assert FunctionLinks.url(links, "Sample.run/1") == expected.(2)
    assert FunctionLinks.url(links, "Sample.run/2") == expected.(2)
    # FUNC-5: the line is the head that names it, private or not.
    assert FunctionLinks.url(links, "Sample.hidden/1") == expected.(3)
  end

  # FUNC-2: a mention is `<Module>.<name>/<arity>` — the whole token and nothing
  # less — and a function the workspace does not define is no link at all
  # (FUNC-4).
  test "what is not a function mention is not a link", %{links: links} do
    for mention <- [
          # a bare module
          "Sample",
          # no arity
          "Sample.run",
          # a module is a capitalised name
          "sample.run/1",
          # an arity is a whole number
          "Sample.run/x",
          # the whole token, with nothing around it
          " Sample.run/1",
          "Sample.run/1 ",
          "Sample.run/1,",
          # not the workspace's own source (FUNC-4, FUNC-9)
          "Enum.map/2",
          "Sample.run/3",
          "Other.run/1",
          # a mention in a command's or a path's shape
          "lib/sample.ex",
          ""
        ] do
      assert FunctionLinks.url(links, mention) == nil, mention
    end
  end

  # FUNC-3: `Elixir.` names the same module.
  test "the Elixir. prefix names the same module", %{links: links} do
    assert FunctionLinks.url(links, "Elixir.Sample.run/1") ==
             FunctionLinks.url(links, "Sample.run/1")
  end

  # FUNC-4: with no chat's workspace to resolve in — a message rendered without
  # one — a mention is no link.
  test "no context, no link" do
    assert FunctionLinks.url(nil, "Sample.run/1") == nil
  end
end
