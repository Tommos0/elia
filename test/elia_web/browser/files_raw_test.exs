defmodule EliaWeb.Browser.FilesRawTest do
  @moduledoc """
  A file's own bytes in a real headless Chromium (BROWSER-1, BROWSER-8).

  EXPL-24 and EXPL-32 (specs/file-explorer.md) are promises about the browser,
  not about the page's markup: whether a document is parsed or shown as text,
  whether its own styles apply, whether its script runs, and whether the frame it
  is drawn in can reach this app's origin are all the browser's own decisions,
  made from the content type, the policy and the sandbox attribute. A LiveView
  test sees the `src` and the attribute and nothing of what they do; only a
  browser sees the rest.
  """

  use EliaWeb.BrowserCase

  alias Elia.Workspace
  alias EliaWeb.BrowserJsLogger

  @dir "browser_files_raw_fixture"
  @raw "/files/raw?" <> URI.encode_query(%{path: "#{@dir}/page.html"})

  setup do
    dir = Path.join(Workspace.root(), @dir)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    # A page that says which of these the browser did: parsed as a document,
    # styled by its own inline style, and holding a script that would mark it if
    # it were ever run.
    File.write!(Path.join(dir, "page.html"), """
    <!doctype html>
    <html>
      <head><title>raw page</title></head>
      <body>
        <h1 id="heading" style="color: rgb(0, 128, 0)">hello from the workspace</h1>
        <script>document.title = 'a script ran'</script>
      </body>
    </html>
    """)

    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  # EXPL-24: the file's own URL, opened on its own (EXPL-26), is parsed by the
  # browser as the document it is, its own inline styles apply, its script never
  # runs, and its document is in an origin of its own.
  test "a page served raw is parsed, styled and never run", %{conn: conn} do
    conn = visit(conn, @raw)

    # A document, not the markup printed as text: the heading is an element the
    # browser made out of the file's own `<h1>`, not a line of source.
    assert_has(conn, "#heading")

    evaluate(conn, "document.querySelector('#heading').textContent", fn text ->
      assert text == "hello from the workspace"
    end)

    # The document's own inline styles still apply...
    evaluate(conn, "getComputedStyle(document.querySelector('#heading')).color", fn color ->
      assert color == "rgb(0, 128, 0)"
    end)

    # ...its script did not run, though the document holds one...
    evaluate(conn, "document.querySelectorAll('script').length", fn count ->
      assert count == 1
    end)

    evaluate(conn, "document.title", fn title -> assert title == "raw page" end)

    # ...and it is in an origin of its own, so nothing it says can reach this
    # app's (EXPL-24).
    evaluate(conn, "window.origin", fn origin -> assert origin == "null" end)

    only_the_files_own_refusals!()
  end

  # EXPL-32: the page draws the file in a frame that is sandboxed with nothing
  # allowed, so the document it holds is not this app's origin's to read — and
  # the app's own page around it is untouched by what the file says.
  test "the frame a raw view draws is sandboxed", %{conn: conn} do
    conn =
      conn
      |> visit("/files?" <> URI.encode_query(%{path: "#{@dir}/page.html", mode: "raw"}))
      |> wait_until(
        "document.querySelector('#file-raw')?.contentDocument === null",
        "the frame never held a document of its own origin (EXPL-32)"
      )

    # The file's own bytes, and not this app's page, are what it holds.
    assert_has(conn, "#file-raw[src*='/files/raw']")

    evaluate(conn, "document.querySelector('#file-raw').getAttribute('sandbox')", fn sandbox ->
      assert sandbox == ""
    end)

    # The app's own page is still this app's: it can be read from the outside.
    evaluate(conn, "document.title !== ''", fn readable -> assert readable end)

    only_the_files_own_refusals!()
  end

  # The file's script is refused by the browser, which logs that refusal as a
  # console error — an error of the file's, not of this app's own JavaScript,
  # which is what BROWSER-8's rule is about. Reading the log says so, and leaves
  # the case nothing to flunk on.
  defp only_the_files_own_refusals! do
    errors = BrowserJsLogger.take()

    assert Enum.all?(errors, &(&1 =~ "Content Security Policy" or &1 =~ "sandboxed")),
           "the page logged an error of its own: #{inspect(errors)}"
  end

  # A promise the page resolves: the expression is evaluated until it is truthy
  # or the deadline passes, so the test never races the browser's own fetch.
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
