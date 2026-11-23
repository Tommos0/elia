defmodule EliaWeb.Browser.PreviewHostTest do
  @moduledoc """
  SERVE-11 as behaviour, in a real headless Chromium (BROWSER-1, BROWSER-8): a
  page the preview host serves runs its own script and keeps its own storage.

  That is what the raw view's policy denies (EXPL-24) and why a preview host
  exists at all, and it is the browser's decision, not the page's markup: what a
  test of the response headers can only promise, a browser shows. The same page
  loaded through the app's own raw view is what `files_raw_test.exs` asserts the
  other way round.
  """

  use EliaWeb.BrowserCase

  alias Elia.{Projects, Settings, Workspace}

  @dir "browser_preview_host_fixture"

  setup do
    dir = Path.join(Workspace.root(), @dir)
    File.rm_rf!(dir)
    # SERVE-16: what the preview serves is the project's `dist` folder.
    File.mkdir_p!(Path.join(dir, "dist"))

    File.write!(Path.join(dir, "dist/page.html"), """
    <!doctype html>
    <title>before its script</title>
    <script>
      document.title = "a script ran"
      try {
        localStorage.setItem("preview", "kept")
        window.stored = "ok"
      } catch (error) {
        window.stored = error.name
      }
    </script>
    """)

    {:ok, project} = Projects.create("Browser preview", dir)
    :ok = Projects.set_default(project.id)

    # The preview host is this very server at the other of the two loopback
    # names, which is a host of its own (SERVE-1, SERVE-4): the browser case's
    # own pages are loaded from the one in its base URL.
    base = Application.fetch_env!(:phoenix_test, :base_url) |> URI.parse()
    host = if base.host == "127.0.0.1", do: "localhost", else: "127.0.0.1"
    preview = "#{host}:#{base.port}"
    Application.put_env(:elia, EliaWeb.PreviewHost, host: preview)

    on_exit(fn ->
      Application.delete_env(:elia, EliaWeb.PreviewHost)
      Settings.delete(:default_project)
      Projects.delete(project.id)
      File.rm_rf!(dir)
    end)

    %{url: "http://#{preview}", slug: Projects.slug(project.name)}
  end

  # SERVE-11
  test "a page the preview serves runs its own script and keeps its storage", %{
    conn: conn,
    url: url,
    slug: slug
  } do
    conn = visit(conn, "#{url}/#{slug}/page.html")

    # The document is in an origin of its own, not this app's.
    evaluate(conn, "window.origin", fn origin -> assert origin == url end)

    # Its script ran: no policy turned scripting off in it.
    assert_has(conn, "title", text: "a script ran")

    # And the origin is a real one, not opaque — storage works.
    evaluate(conn, "window.stored", fn stored -> assert stored == "ok" end)

    evaluate(conn, "localStorage.getItem('preview')", fn kept ->
      assert kept == "kept"
    end)
  end
end
