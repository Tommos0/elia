defmodule EliaWeb.TerminalSocket do
  @moduledoc """
  The socket a chat's terminal streams over (TERM-12).

  It is deliberately not the LiveView socket: a terminal is a stream of bytes,
  and a LiveView's diffing is the wrong transport for one. Like the rest of the
  app there is no auth — anyone who can reach the app can open a terminal in a
  chat's workspace — and what bounds it is the jail the session runs in
  (TERM-7) and the page the handshake comes from: this server's own origin
  (SOCK-1) and a session this server issued (SOCK-3,
  `specs/socket-origin.md`).
  """

  use Phoenix.Socket

  channel "terminal:*", EliaWeb.TerminalChannel

  # SOCK-3: a handshake proves it came from a page of this server by presenting
  # that page's session proof — the CSRF token of a session this server issued.
  # It is the transport that judges the token and answers `connect_info` with
  # `session: nil` when it is missing, stale or not this session's, so a nil
  # session is the missing proof and the connection is refused. This is not a
  # login: a client that can fetch the page has the proof (SOCK-5).
  @impl true
  def connect(_params, socket, connect_info) do
    case connect_info do
      %{session: session} when is_map(session) -> {:ok, socket}
      _no_session -> :error
    end
  end

  # The app has no auth, so there is nothing for a socket id to name.
  @impl true
  def id(_socket), do: nil
end
