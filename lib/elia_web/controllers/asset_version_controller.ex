defmodule EliaWeb.AssetVersionController do
  @moduledoc """
  The bundle the server serves now (BUNDLE-3).

  A page that is already open keeps the bundle it loaded, and the reload that
  would give it a new one is a reload it can miss (see
  `specs/bundle-refresh.md`). So the page asks here, and compares the answer
  with the version it carries itself (BUNDLE-2): the plain text of
  `EliaWeb.AssetVersion.current/1`, which is what the page's meta holds as well.

  It is a route of the browser pipeline, so the answer is never served from a
  cache (PWA-9) — the one thing this endpoint must not do is answer with a
  version a deploy has already replaced.
  """

  use EliaWeb, :controller

  alias EliaWeb.AssetVersion

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, AssetVersion.current())
  end
end
