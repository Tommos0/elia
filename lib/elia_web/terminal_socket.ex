defmodule EliaWeb.TerminalSocket do
  @moduledoc """
  The socket a chat's terminal streams over (TERM-12).

  It is deliberately not the LiveView socket: a terminal is a stream of bytes,
  and a LiveView's diffing is the wrong transport for one. Like the rest of the
  app there is no auth — anyone who can reach the app can open a terminal in a
  chat's workspace — and what bounds it is the jail the session runs in
  (TERM-7).
  """

  use Phoenix.Socket

  channel "terminal:*", EliaWeb.TerminalChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  # The app has no auth, so there is nothing for a socket id to name.
  @impl true
  def id(_socket), do: nil
end
