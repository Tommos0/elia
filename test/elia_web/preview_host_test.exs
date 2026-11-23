defmodule EliaWeb.PreviewHostTest do
  @moduledoc """
  A project's build output at a hostname of their own (`specs/preview-host.md`),
  over the endpoint: what is served, what is refused, and what is never reached
  there.

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
    plain = Path.join(Workspace.root(), "preview_host_plain")

    # SERVE-16: what a project serves is its `dist` folder, so what the preview
    # serves goes there — and a file beside it does not.
    dist = Path.join(open, "dist")
    File.rm_rf!(open)
    File.rm_rf!(parts)
    File.rm_rf!(plain)
    File.mkdir_p!(Path.join(dist, "sub"))
    File.mkdir_p!(Path.join(dist, "noindex"))
    File.mkdir_p!(Path.join(dist, ".git"))
    File.mkdir_p!(Path.join(parts, "dist"))
    File.mkdir_p!(plain)

    File.write!(
      Path.join(dist, "index.html"),
      "<!doctype html><title>open</title><p>the open project</p>"
    )

    File.write!(Path.join(dist, "sub/index.html"), "<!doctype html><title>sub</title>")
    File.write!(Path.join(dist, "page.html"), "<!doctype html><title>page</title>")
    File.write!(Path.join(dist, "app.css"), "body { color: red }")
    File.write!(Path.join(dist, "app.js"), "console.log('hi')")
    File.write!(Path.join(dist, "data.json"), ~s({"ok":true}))
    File.write!(Path.join(dist, "thing.unknown"), "bytes")
    File.write!(Path.join(dist, ".git/config"), "[core]")
    File.ln_s!("/etc/passwd", Path.join(dist, "link.html"))
    File.write!(Path.join(parts, "dist/index.html"), "<!doctype html><title>parts</title>")

    # Beside the build, so served by nothing (SERVE-16, SERVE-17).
    File.write!(Path.join(open, ".env"), "SECRET=not-for-the-internet")
    File.write!(Path.join(open, "source.txt"), "a source file")

    {:ok, open_project} = Projects.create("preview host open", open)
    {:ok, parts_project} = Projects.create("Parts preview", parts)
    # SERVE-18: a project with no `dist` folder at all.
    {:ok, plain_project} = Projects.create("preview host plain", plain)
    :ok = Projects.set_default(open_project.id)
    :ok = set_host(@host)

    on_exit(fn ->
      Settings.delete(:default_project)
      Projects.delete(open_project.id)
      Projects.delete(parts_project.id)
      Projects.delete(plain_project.id)
      set_host(nil)
      File.rm_rf!(open)
      File.rm_rf!(parts)
      File.rm_rf!(plain)
    end)

    %{
      open: open,
      dist: dist,
      parts: parts,
      plain: plain,
      slug: Projects.slug(open_project.name),
      parts_slug: Projects.slug(parts_project.name),
      plain_slug: Projects.slug(plain_project.name)
    }
  end

  defp set_host(nil), do: Application.delete_env(:elia, EliaWeb.PreviewHost)
  defp set_host(host), do: Application.put_env(:elia, EliaWeb.PreviewHost, host: host)

  defp preview(conn, host \\ @host), do: put_req_header(conn, "x-forwarded-host", host)

  # A path on the preview host: the project's slug, then the path in the `dist`
  # folder that project serves (SERVE-16).
  defp at(slug, path), do: "/#{slug}#{path}"

  # SERVE-1, SERVE-9, SERVE-11, SERVE-16: a project's own document, at its slug.
  test "serves the dist folder's index.html at the project's slug", %{
    conn: conn,
    slug: slug,
    dist: dist
  } do
    conn = conn |> preview() |> get(at(slug, "/"))

    assert conn.status == 200
    assert conn.resp_body == File.read!(Path.join(dist, "index.html"))
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    # SERVE-11: the policy the app's own raw view carries is what this host is
    # for not having.
    assert get_resp_header(conn, "content-security-policy") == []
  end

  # SERVE-16: a path is a path under the project's `dist` folder.
  test "serves a file under the slug's dist folder", %{conn: conn, slug: slug} do
    conn = conn |> preview() |> get(at(slug, "/app.css"))

    assert conn.status == 200
    assert conn.resp_body == "body { color: red }"
    assert get_resp_header(conn, "content-type") == ["text/css; charset=utf-8"]
  end

  # SERVE-16, SERVE-17: a first segment names a project by its slug, and the
  # rest of the path is a path in that project's `dist` folder — nothing beside
  # it is served, not even the file the build sits next to.
  test "serves the project a first segment names by its slug", %{
    conn: conn,
    open: open,
    slug: slug,
    parts: parts,
    parts_slug: parts_slug
  } do
    parts_response = conn |> preview() |> get("/#{parts_slug}/")
    assert parts_response.status == 200
    assert parts_response.resp_body == File.read!(Path.join(parts, "dist/index.html"))

    # The fixture's own slug serves its `dist` folder too.
    open_response = conn |> preview() |> get(at(slug, "/app.js"))
    assert open_response.status == 200
    assert open_response.resp_body == "console.log('hi')"

    # A file beside the build, and one reached by leading out of it, are not
    # served — the folder is the `dist` folder and nothing above it.
    for path <- [at(slug, "/.env"), at(slug, "/source.txt"), at(slug, "/../source.txt")] do
      refused = conn |> preview() |> get(path)
      assert refused.status == 404, "#{path} was served"
    end

    # The file is there, beside the build, and still not served.
    assert File.exists?(Path.join(open, ".env"))
  end

  # SERVE-17: the root and a first segment that is no project's slug are a 404,
  # even with a project open — the fixture sets one.
  test "serves nothing at the root and nothing for a segment that is no slug", %{conn: conn} do
    for path <- ["/", "/sub/", "/app.css", "/no-such-project/", "/no-such-project/app.css"] do
      conn = conn |> preview() |> get(path)
      assert conn.status == 404, "#{path} was served"
      assert conn.resp_body == "Not found"
    end
  end

  # SERVE-18: a project with no `dist` folder serves nothing at all.
  test "a project with no dist folder serves nothing", %{conn: conn, plain_slug: plain_slug} do
    for path <- ["/#{plain_slug}/", "/#{plain_slug}/index.html"] do
      conn = conn |> preview() |> get(path)
      assert conn.status == 404, "#{path} was served"
    end
  end

  # SERVE-8: a directory is its index.html, and no directory is ever listed.
  test "a directory is served as its index.html and nothing is listed", %{conn: conn, slug: slug} do
    sub = conn |> preview() |> get(at(slug, "/sub/"))
    assert sub.status == 200
    assert sub.resp_body == "<!doctype html><title>sub</title>"

    # No index, no listing: an empty directory is a 404, not its entries.
    empty = conn |> preview() |> get(at(slug, "/noindex/"))
    assert empty.status == 404
    refute empty.resp_body =~ "index.html"

    # The directory itself is the same document as the directory with a slash.
    without_slash = conn |> preview() |> get(at(slug, "/sub"))
    assert without_slash.status == 200
    assert without_slash.resp_body == sub.resp_body
  end

  # SERVE-9: the content type an extension gives it, and the fallback.
  test "serves each kind of file under the type its extension gives it", %{
    conn: conn,
    slug: slug
  } do
    types = %{
      "/app.js" => "text/javascript; charset=utf-8",
      "/data.json" => "application/json",
      "/thing.unknown" => "application/octet-stream"
    }

    for {path, type} <- types do
      conn = conn |> preview() |> get(at(slug, path))
      assert conn.status == 200, "#{path} was not served"
      assert get_resp_header(conn, "content-type") == [type], "#{path} had the wrong type"
    end
  end

  # SERVE-10: the refusals, all of them a 404 that says nothing else.
  test "refuses what leads out, into a protected path, through a link, or nowhere", %{
    conn: conn,
    slug: slug
  } do
    for path <- [
          "/%2e%2e/etc/passwd",
          "/sub/../../etc/passwd",
          "/.git/config",
          "/link.html",
          "/missing.html"
        ] do
      conn = conn |> preview() |> get(at(slug, path))
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
  test "serves nothing on the app's own host", %{conn: conn, slug: slug} do
    assert get(conn, at(slug, "/page.html")).status == 404

    # The dashboard is still the dashboard at `/`.
    assert get(conn, "/").status == 200

    set_host(nil)
    assert conn |> preview() |> get(at(slug, "/page.html")) |> Map.fetch!(:status) == 404
  end

  # SERVE-5: a host behind a proxy that terminates TLS, and one with the wrong
  # port.
  test "reads the scheme and the host a proxy reports", %{conn: conn, slug: slug} do
    set_host("preview.wolk.run")

    through_tunnel =
      conn
      |> put_req_header("x-forwarded-proto", "https")
      |> preview("preview.wolk.run")
      |> get(at(slug, "/page.html"))

    assert through_tunnel.status == 200

    wrong_port =
      conn
      |> put_req_header("x-forwarded-proto", "https")
      |> preview("preview.wolk.run:8443")
      |> get(at(slug, "/page.html"))

    assert wrong_port.status == 404
  end

  # SERVE-12: the validators a browser revalidates by.
  test "revalidates with the etag it sent", %{conn: conn, slug: slug, dist: dist} do
    first = conn |> preview() |> get(at(slug, "/page.html"))
    assert first.status == 200
    assert get_resp_header(first, "cache-control") == ["no-cache"]
    [etag] = get_resp_header(first, "etag")
    assert [_last_modified] = get_resp_header(first, "last-modified")

    again =
      conn |> preview() |> put_req_header("if-none-match", etag) |> get(at(slug, "/page.html"))

    assert again.status == 304
    assert again.resp_body == ""

    # A file that changed is served afresh, not by the validator of the old one.
    File.write!(Path.join(dist, "page.html"), "<!doctype html><title>changed</title>")

    changed =
      conn |> preview() |> put_req_header("if-none-match", etag) |> get(at(slug, "/page.html"))

    assert changed.status == 200
    assert changed.resp_body =~ "changed"
  end

  # SERVE-13: the app's session has no part in it.
  test "needs no session and sets no cookie", %{conn: conn, slug: slug} do
    plain = conn |> preview() |> get(at(slug, "/page.html"))
    assert get_resp_header(plain, "set-cookie") == []

    with_cookie =
      conn
      |> put_req_header("cookie", "_elia_key=a-session-that-is-not-this-request's")
      |> preview()
      |> get(at(slug, "/page.html"))

    assert with_cookie.status == 200
    assert with_cookie.resp_body == plain.resp_body
    assert get_resp_header(with_cookie, "set-cookie") == []
  end

  # SERVE-14: a read, and only a read.
  test "answers GET and HEAD and refuses every other method", %{
    conn: conn,
    slug: slug,
    dist: dist
  } do
    head = conn |> preview() |> head(at(slug, "/page.html"))
    assert head.status == 200
    assert head.resp_body == ""

    assert get_resp_header(head, "content-length") == [
             Integer.to_string(File.stat!(Path.join(dist, "page.html")).size)
           ]

    for method <- [:post, :put, :patch, :delete] do
      conn = conn |> preview() |> dispatch(@endpoint, method, at(slug, "/page.html"), %{})
      assert conn.status == 405, "#{method} was answered"
      assert get_resp_header(conn, "allow") == ["GET, HEAD"]
      # Nothing was written: the file is as it was.
      assert File.read!(Path.join(dist, "page.html")) == "<!doctype html><title>page</title>"
    end
  end
end
