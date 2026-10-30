defmodule EliaWeb.CrashingPipeline do
  @moduledoc """
  Test pipeline: the real `Plug.Debugger` around `EliaWeb.Recovery` and a plug
  that crashes the way `Phoenix.Router` does, re-raising with the conn as it
  was after the endpoint's plugs ran.
  """

  use Plug.Builder
  use Plug.Debugger, otp_app: :elia

  plug EliaWeb.Recovery
  plug :crash

  def crash(conn, _opts) do
    Plug.Conn.WrapperError.reraise(conn, :error, RuntimeError.exception("kaboom"), [])
  end
end
