defmodule EliaWeb.FilesRawController do
  @moduledoc """
  Serves the bytes a raw view of the Files page is made of (EXPL-24): the file a
  `path` parameter names in the workspace the page browses — the open project's
  folder (EXPL-15) or a chat's own (EXPL-17), resolved by `EliaWeb.FilesScope` —
  under the content type that file's kind gives it (EXPL-22, EXPL-31).

  It reaches exactly what the page may show (EXPL-25): a file of that workspace
  the browser renders, reached without a symlink and outside a protected path
  (`Elia.Explorer.raw_file/2`). Anything else — a path that leads out, a
  directory, a binary file, one that isn't there — is a 404 that says nothing
  about the workspace, so the route is never a way to read what the explorer
  refuses.
  """

  use EliaWeb, :controller

  alias Elia.Explorer
  alias EliaWeb.FilesScope

  # EXPL-24: a kind that can carry script — an image (an SVG can), an HTML
  # document, an XML file — is served under this policy, so opening a file's own
  # URL can't run it in this app's origin, while the document's own inline styles
  # still apply. The other kinds get no policy, so the browser's own PDF and
  # media viewers are untouched.
  @scripted [:image, :html, :xml]
  @policy "default-src 'none'; style-src 'unsafe-inline'; sandbox"

  def show(conn, params) do
    case raw(params) do
      {:ok, raw} -> serve(conn, raw)
      {:error, _reason} -> send_resp(conn, 404, "Not found")
    end
  end

  defp raw(params) do
    case params["path"] do
      path when is_binary(path) -> Explorer.raw_file(path, FilesScope.root(params))
      _other -> {:error, :not_found}
    end
  end

  # EXPL-24: the file's own bytes, its type and the validators a browser
  # revalidates by, so a page opened again doesn't fetch a large file again
  # while a file that changed since is served afresh.
  defp serve(conn, raw) do
    etag = ~s("#{raw.size}-#{raw.mtime}")

    conn =
      conn
      |> put_resp_header("content-type", raw.type)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("etag", etag)
      |> put_resp_header("last-modified", http_date(raw.mtime))
      |> put_security_policy(raw.kind)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      send_file(conn, 200, raw.file)
    end
  end

  defp put_security_policy(conn, kind) when kind in @scripted,
    do: put_resp_header(conn, "content-security-policy", @policy)

  defp put_security_policy(conn, _kind), do: conn

  defp http_date(posix) do
    posix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end
end
