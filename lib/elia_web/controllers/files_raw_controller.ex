defmodule EliaWeb.FilesRawController do
  @moduledoc """
  Serves the bytes a preview of the Files page is made of (EXPL-24): the file a
  `path` parameter names in the workspace the page browses — the open project's
  folder (EXPL-15) or a chat's own (EXPL-17), resolved by `EliaWeb.FilesScope` —
  with the content type its extension gives it (EXPL-22).

  It reaches exactly what the page may show (EXPL-25): a previewable regular
  file of that workspace, reached without a symlink and outside a protected path
  (`Elia.Explorer.preview_file/2`). Anything else — a path that leads out,
  a directory, a file this page shows as text, one that isn't there — is a 404
  that says nothing about the workspace, so the route is never a way to read
  what the explorer refuses.
  """

  use EliaWeb, :controller

  alias Elia.Explorer
  alias EliaWeb.FilesScope

  def show(conn, params) do
    case preview(params) do
      {:ok, preview} -> serve(conn, preview)
      {:error, _reason} -> send_resp(conn, 404, "Not found")
    end
  end

  defp preview(params) do
    with path when is_binary(path) <- params["path"] do
      Explorer.preview_file(path, FilesScope.root(params))
    else
      _ -> {:error, :not_found}
    end
  end

  # EXPL-24: the file's own bytes, its type and the validators a browser
  # revalidates by, so a page opened again doesn't fetch a large file again
  # while a file that changed since is served afresh.
  defp serve(conn, preview) do
    etag = ~s("#{preview.size}-#{preview.mtime}")

    conn =
      conn
      |> put_resp_header("content-type", preview.type)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("etag", etag)
      |> put_resp_header("last-modified", http_date(preview.mtime))
      |> put_security_policy(preview.kind)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      send_file(conn, 200, preview.file)
    end
  end

  # EXPL-24: an image is the only kind of preview that can carry script, and an
  # SVG can, so the file's own URL can't run it in this app's origin. The other
  # kinds get no policy, so the browser's own PDF and media viewers are untouched.
  defp put_security_policy(conn, :image),
    do: put_resp_header(conn, "content-security-policy", "default-src 'none'; sandbox")

  defp put_security_policy(conn, _kind), do: conn

  defp http_date(posix) do
    posix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end
end
