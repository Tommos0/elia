defmodule EliaWeb.PreviewController do
  @moduledoc """
  Serves the images a UI preview wrote (PREVIEW-7).

  A preview runs in a chat's own worktree (PREVIEW-1), which the live app would
  otherwise never read from. This route is how a picture taken there reaches the
  chat that asked for it, with nothing else reachable: a picture has to be a
  single file name with an image extension, inside that chat's own `tmp/preview/`
  (PREVIEW-4), reached without a symlink (`Elia.Explorer.safe_path/2`). Any
  other chat id, name, extension or path — and a file that is not there — is a
  404, never a listing and never another file of the workspace.
  """

  use EliaWeb, :controller

  alias Elia.Preview

  def show(conn, %{"chat_id" => chat_id, "file" => file}) do
    case Preview.path(chat_id, file) do
      {:ok, path} ->
        # A re-run of a preview writes the same file names (PREVIEW-4), so the
        # chat keeps its links and shows the new picture.
        conn
        |> put_resp_header("content-type", MIME.from_path(path))
        |> put_resp_header("cache-control", "no-cache")
        |> send_file(200, path)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
