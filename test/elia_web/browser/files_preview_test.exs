defmodule EliaWeb.Browser.FilesPreviewTest do
  @moduledoc """
  A preview of the Files page in a real headless Chromium (BROWSER-1, BROWSER-8).

  EXPL-23 (specs/file-explorer.md) asks for the picture the browser draws of a
  file the workspace holds, and `Phoenix.LiveViewTest` cannot see it: an `img`
  whose `src` serves nothing is still an `img` element, and a page that never
  asks the browser for the bytes looks exactly like one that does. This is where
  the path as a whole is asked for — the route (EXPL-24), what it serves and
  what the browser makes of it.
  """

  use EliaWeb.BrowserCase

  alias Elia.Workspace

  @dir "browser_files_preview_fixture"

  setup do
    dir = Path.join(Workspace.root(), @dir)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    # A real picture: a file of bytes the browser cannot decode would have
    # nothing to draw, whatever the page or the route did.
    File.cp!("priv/static/images/icon-192.png", Path.join(dir, "icon.png"))

    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  # EXPL-23, EXPL-24: the browser fetches the file from the route and draws it,
  # at its own size.
  test "a picture of the workspace is drawn from the raw route", %{conn: conn} do
    path = "#{@dir}/icon.png"

    conn =
      conn
      |> visit("/files?" <> URI.encode_query(%{path: path}))
      |> wait_until(
        "document.querySelector('#file-preview')?.naturalWidth === 192",
        "the browser never drew the picture the page previews (EXPL-23)"
      )

    # EXPL-26: and the header opens that same URL on a page of its own.
    assert_has(conn, "#file-preview-open[target=_blank][href*='/files/raw']")
    # EXPL-24: the bytes came from the route that serves the file, not from the page.
    assert_has(conn, "img#file-preview[src*='/files/raw']")
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
