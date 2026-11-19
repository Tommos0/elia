defmodule EliaWeb.Browser.FilesLineTest do
  @moduledoc """
  The line a file-and-line link names, as a real headless Chromium draws it
  (BROWSER-1, BROWSER-8).

  EXPL-27 (specs/file-explorer.md) asks the viewer to mark the named line and
  bring it into sight, and both are the browser's own work: the mark is applied
  *after* highlight.js has replaced the element's markup (EXPL-13), and the
  scroll belongs to the pane the text sits in. `Phoenix.LiveViewTest` sees the
  attribute the server sends and nothing of what the hook makes of it, so this
  is where the mark, its text and the scroll are asked for.
  """

  use EliaWeb.BrowserCase

  alias Elia.Workspace

  @dir "browser_files_line_fixture"

  setup do
    dir = Path.join(Workspace.root(), @dir)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    # Long enough that the named line is well below the pane's first screen.
    File.write!(Path.join(dir, "long.txt"), Enum.map_join(1..120, "\n", &"line #{&1}"))
    File.write!(Path.join(dir, "sample.ex"), "defmodule Sample do\n  def a, do: 1\nend\n")

    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  # EXPL-27: the line is marked and scrolled into the pane the text scrolls in.
  test "the named line is marked and brought into sight", %{conn: conn} do
    conn = visit(conn, line_url("#{@dir}/long.txt", "90"))

    wait_until(
      conn,
      "document.querySelector('#file-content .file-line-mark')?.textContent === 'line 90'",
      "the line the link names was never marked (EXPL-27)"
    )

    assert_has(conn, "#file-content .file-line-mark", text: "line 90")

    evaluate(conn, line_view(), fn view ->
      assert view["marked"] == "line 90", "the mark is not on the line: #{inspect(view)}"
      assert view["marked_only_once"], "a line was marked twice: #{inspect(view)}"

      assert view["in_sight"],
             "the marked line is not in sight in the pane (EXPL-27): #{inspect(view)}"

      assert view["scrolled"] > 0,
             "the pane never scrolled to the marked line (EXPL-27): #{inspect(view)}"
    end)
  end

  # EXPL-13, EXPL-27: the mark goes on after the highlighting, so a highlighted
  # file marks its line too — a line whose characters are inside the token spans
  # highlight.js wrote — and the marked text is the file's own line, without the
  # newline that ends it.
  test "a highlighted file marks its line too", %{conn: conn} do
    path = "#{@dir}/sample.ex"
    conn = visit(conn, line_url(path, "2"))

    wait_until(
      conn,
      "!!document.querySelector('#file-content span[class^=\"hljs-\"]')",
      "the file was never highlighted (EXPL-13)"
    )

    wait_until(
      conn,
      "!!document.querySelector('#file-content .file-line-mark')",
      "the mark never survived the highlighting (EXPL-27)"
    )

    evaluate(
      conn,
      "document.querySelector('#file-content .file-line-mark').textContent",
      fn marked ->
        assert marked == "  def a, do: 1"
      end
    )

    # EXPL-13: the highlighting, mark and all, leaves the text as the file's.
    expected = File.read!(Path.join(Workspace.root(), path))

    evaluate(conn, "document.querySelector('#file-content').textContent", fn text ->
      assert text == expected
    end)
  end

  # A file and the line a link names, as CITE-10's tooltip links it.
  defp line_url(path, line), do: "/files?" <> URI.encode_query(%{path: path, line: line})

  # What the mark became in the page: its text, that there is one mark, that it
  # sits inside the pane that scrolls the text, and how far that pane scrolled.
  defp line_view do
    """
    (() => {
      const content = document.querySelector('#file-content')
      const marks = content.querySelectorAll('.file-line-mark')
      const pane = content.closest('.overflow-auto')
      if (!pane || marks.length === 0) return {marked: null}

      const mark = marks[0].getBoundingClientRect()
      const view = pane.getBoundingClientRect()

      return {
        marked: marks[0].textContent,
        marked_only_once: marks.length === 1,
        in_sight:
          mark.height > 0 && mark.top >= view.top - 1 && mark.bottom <= view.bottom + 1,
        scrolled: Math.round(pane.scrollTop),
      }
    })()
    """
  end

  # A promise the page resolves: the expression is evaluated until it is truthy
  # or the deadline passes, so the test never races the socket or the hook.
  defp wait_until(conn, expression, message, timeout \\ 10_000) do
    evaluate(
      conn,
      """
      new Promise(resolve => {
        const until = Date.now() + #{timeout}
        const check = () => {
          try {
            if (#{expression}) return resolve(true)
          } catch (e) {}
          if (Date.now() > until) return resolve(false)
          setTimeout(check, 25)
        }
        check()
      })
      """,
      [timeout: timeout + 2_000],
      fn reached -> assert reached, "#{message} (within #{timeout}ms)" end
    )
  end
end
