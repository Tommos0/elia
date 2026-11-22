defmodule EliaWeb.PreviewHostTest do
  @moduledoc """
  A project's files at a hostname of their own (`specs/preview-host.md`), over
  the endpoint: what is served, what is refused, and what is never reached there.

  The preview host is `preview.localhost:7000` throughout, which the test
  connection is not: it names the preview in `x-forwarded-host`, the way a proxy
  in front of the app does (SERVE-5).
  """

  use EliaWeb.ConnCase, async: false

  alias Elia.{Projects, Settings, Workspace}

  @host "preview.localhost:7000"

  setup do
    open = Path.join(Workspace.root(), "preview_host_open")
    parts = Path.join(Workspace.root(), "preview_host_parts")
    File.rm_rf!(open)
    File.rm_rf!(parts)
    File.mkdir_p!(Path.join(open, "sub"))
    File.mkdir_p!(Path.join(open, "noindex"))
    File.mkdir_p!(Path.join(open, ".git"))
    File.mkdir_p!(parts)

    File.write!(
      Path.join(open, "index.html"),
      "<!doctype html><title>open</title><p>the open project</p>"
    )

    File.write!(Path.join(open, "sub/index.html"), "<!doctype html><title>sub</title>")
    File.write!(Path.join(open, "page.html"), "<!doctype html><title>page</title>")
    File.write!(Path.join(open, "app.css"), "body { color: red }")
    File.write!(Path.join(open, "app.js"), "console.log('hi')")
    File.write!(Path.join(open, "data.json"), ~s({"ok":true}))
    File.write!(Path.join(open, "thing.unknown"), "bytes")
    File.write!(Path.join(open, ".git/config"), "[core]")
    File.ln_s!("/etc/passwd", Path.join(open, "link.html"))
    File.write!(Path.join(parts, "index.html"), "<!doctype html><title>parts</title>")

    {:ok, open_project} = Projects.create("preview host open", open)
    {:ok, parts_project} = Projects.create("Parts preview", parts)
    :ok = Projects.set_default(open_project.id)
    :ok = set_host(@host)

    on_exit(fn ->
      Settings.delete(:default_project)
      Projects.delete(open_project.id)
      Projects.delete(parts_project.id)
      set_host(nil)
      File.rm_rf!(open)
      File.rm_rf!(parts)
    end)

    %{
      open: open,
      parts: parts,
      slug: Projects.slug(open_project.name),
      parts_slug: Projects.slug(parts_project.name)
    }
  end

  defp set_host(nil), do: Application.delete_env(:elia, EliaWeb.PreviewHost)
  defp set_host(host), do: Application.put_env(:elia, EliaWeb.PreviewHost, host: host)

  defp preview(conn, host \\ @host), do: put_req_header(conn, "x-forwarded-host", host)

  # SERVE-1, SERVE-6, SERVE-9, SERVE-11: the open project's own document.
  test "serves the open project's index.html at /", %{conn: conn, open: open} do
    conn = conn |> preview() |> get("/")

    assert conn.status == 200
    assert conn.resp_body == File.read!(Path.join(open, "index.html"))
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    # SERVE-11: the policy the app's own raw view carries is what this host is
    # for not having.
    assert get_resp_header(conn, "content-security-policy") == []
  end

  # SERVE-6: a path is a path in the open project.
  test "serves a file of the open project", %{conn: conn} do
    conn = conn |> preview() |> get("/app.css")

    assert conn.status == 200
    assert conn.resp_body == "body { color: red }"
    assert get_resp_header(conn, "content-type") == ["text/css; charset=utf-8"]
  end

  # SERVE-7: a first segment that is a project's slug names that project.
  test "serves the project a first segment names by its slug", %{
    conn: conn,
    open: open,
    parts: parts,
    parts_slug: parts_slug
  } do
    parts_response = conn |> preview() |> get("/#{parts_slug}/")
    assert parts_response.status == 200
    assert parts_response.resp_body == File.read!(Path.join(parts, "index.html"))

    open_response = conn |> preview() |> get("/#{parts_slug}/../app.css")
    assert open_response.status == 404

    # The open project's own slug serves the open project's folder too.
    conn = conn |> preview() |> get("/#{Projects.slug("preview host open")}/app.js")
    assert conn.status == 200
    assert conn.resp_body == "console.log('hi')"
    assert File.read!(Path.join(open, "app.js")) == conn.resp_body
  end

  # SERVE-7: a first segment that is no project's slug is a path in the open
  # project, not a 404 of its own.
  test "a first segment that is no slug is a path in the open project", %{conn: conn} do
    conn = conn |> preview() |> get("/sub/")

    assert conn.status == 200
    assert conn.resp_body =~ "sub"
  end

  # SERVE-8: a directory is its index.html, and no directory is ever listed.
  test "a directory is served as its index.html and nothing is listed", %{conn: conn} do
    sub = conn |> preview() |> get("/sub/")
    assert sub.status == 200
    assert sub.resp_body == "<!doctype html><title>sub</title>"

    # No index, no listing: an empty directory is a 404, not its entries.
    empty = conn |> preview() |> get("/noindex/")
    assert empty.status == 404
    refute empty.resp_body =~ "index.html"

    # The directory itself is the same document as the directory with a slash.
    without_slash = conn |> preview() |> get("/sub")
    assert without_slash.status == 200
    assert without_slash.resp_body == sub.resp_body
  end

  # SERVE-9: the content type an extension gives it, and the fallback.
  test "serves each kind of file under the type its extension gives it", %{conn: conn} do
    types = %{
      "/app.js" => "text/javascript; charset=utf-8",
      "/data.json" => "application/json",
      "/thing.unknown" => "application/octet-stream"
    }

    for {path, type} <- types do
      conn = conn |> preview() |> get(path)
      assert conn.status == 200, "#{path} was not served"
      assert get_resp_header(conn, "content-type") == [type], "#{path} had the wrong type"
    end
  end

  # SERVE-10: the refusals, all of them a 404 that says nothing else.
  test "refuses what leads out, into a protected path, through a link, or nowhere", %{
    conn: conn
  } do
    for path <- [
          "/%2e%2e/etc/passwd",
          "/sub/../../etc/passwd",
          "/.git/config",
          "/link.html",
          "/missing.html"
        ] do
      conn = conn |> preview() |> get(path)
      assert conn.status == 404, "#{path} was served"
      assert conn.resp_body == "Not found"
    end
  end

  # SERVE-3: on the preview host nothing of the app is reached.
  test "serves none of the app on the preview host", %{conn: conn} do
    for path <- ["/files/raw?path=index.html", "/c/anychat", "/settings"] do
      conn = conn |> preview() |> get(path)
      assert conn.status == 404, "#{path} reached the app"
      assert conn.resp_body == "Not found"
    end
  end

  # SERVE-4, SERVE-2: on the app's own host the preview serves nothing, with a
  # preview host configured and with none.
  test "serves nothing on the app's own host", %{conn: conn} do
    assert get(conn, "/page.html").status == 404

    # The dashboard is still the dashboard at `/`.
    assert get(conn, "/").status == 200

    set_host(nil)
    assert conn |> preview() |> get("/page.html") |> Map.fetch!(:status) == 404
  end

  # SERVE-5: a host behind a proxy that terminates TLS, and one with the wrong
  # port.
  test "reads the scheme and the host a proxy reports", %{conn: conn} do
    set_host("preview.wolk.run")

    through_tunnel =
      conn
      |> put_req_header("x-forwarded-proto", "https")
      |> preview("preview.wolk.run")
      |> get("/page.html")

    assert through_tunnel.status == 200

    wrong_port =
      conn
      |> put_req_header("x-forwarded-proto", "https")
      |> preview("preview.wolk.run:8443")
      |> get("/page.html")

    assert wrong_port.status == 404
  end

  # SERVE-12: the validators a browser revalidates by.
  test "revalidates with the etag it sent", %{conn: conn, open: open} do
    first = conn |> preview() |> get("/page.html")
    assert first.status == 200
    assert get_resp_header(first, "cache-control") == ["no-cache"]
    [etag] = get_resp_header(first, "etag")
    assert [_last_modified] = get_resp_header(first, "last-modified")

    again = conn |> preview() |> put_req_header("if-none-match", etag) |> get("/page.html")
    assert again.status == 304
    assert again.resp_body == ""

    # A file that changed is served afresh, not by the validator of the old one.
    File.write!(Path.join(open, "page.html"), "<!doctype html><title>changed</title>")
    changed = conn |> preview() |> put_req_header("if-none-match", etag) |> get("/page.html")
    assert changed.status == 200
    assert changed.resp_body =~ "changed"
  end

  # SERVE-13: the app's session has no part in it.
  test "needs no session and sets no cookie", %{conn: conn} do
    plain = conn |> preview() |> get("/page.html")
    assert get_resp_header(plain, "set-cookie") == []

    with_cookie =
      conn
      |> put_req_header("cookie", "_elia_key=a-session-that-is-not-this-request's")
      |> preview()
      |> get("/page.html")

    assert with_cookie.status == 200
    assert with_cookie.resp_body == plain.resp_body
    assert get_resp_header(with_cookie, "set-cookie") == []
  end

  # SERVE-14: a read, and only a read.
  test "answers GET and HEAD and refuses every other method", %{conn: conn, open: open} do
    head = conn |> preview() |> head("/page.html")
    assert head.status == 200
    assert head.resp_body == ""

    assert get_resp_header(head, "content-length") == [
             Integer.to_string(File.stat!(Path.join(open, "page.html")).size)
           ]

    for method <- [:post, :put, :patch, :delete] do
      conn = conn |> preview() |> dispatch(@endpoint, method, "/page.html", %{})
      assert conn.status == 405, "#{method} was answered"
      assert get_resp_header(conn, "allow") == ["GET, HEAD"]
      # Nothing was written: the file is as it was.
      assert File.read!(Path.join(open, "page.html")) == "<!doctype html><title>page</title>"
    end
  end
end
