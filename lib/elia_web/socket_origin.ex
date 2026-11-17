defmodule EliaWeb.SocketOrigin do
  @moduledoc """
  The origin a socket handshake is judged by (SOCK-1, SOCK-4).

  Elia has no auth, so what a socket is bound to is the *page* it comes from
  rather than a person: Phoenix's transport accepts a handshake only when its
  `Origin` names the host, scheme and port the request itself arrived at. This
  module is the policy that says so, and says which other origins an install
  reached at a different one — behind a proxy that terminates TLS or rewrites
  the hostname — allows instead (`specs/socket-origin.md`).
  """

  @doc """
  The origins `check_origin` accepts, from `ELIA_ALLOWED_ORIGINS` (SOCK-4).

  A comma-separated list of origins (`https://elia.example.com`), hosts
  (`//elia.example.com:8443`) or hosts with wildcards (`//*.example.com`), as
  the endpoint's `check_origin` option reads them. Empty when it is unset or
  blank, which is the ordinary install.
  """
  @spec allowed_origins() :: [String.t()]
  def allowed_origins do
    case System.get_env("ELIA_ALLOWED_ORIGINS") do
      nil ->
        []

      value ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  @doc """
  The endpoint's `check_origin` (SOCK-1, SOCK-4).

  `:conn` is the host binding: the handshake's `Origin` must name the same
  host, scheme and port the handshake itself arrived at. An install whose page
  is served from somewhere else names those origins in `ELIA_ALLOWED_ORIGINS`,
  and then one list is the whole policy — the host binding is what an install
  with nothing configured gets.

  A handshake that carries no `Origin` at all is not refused by either
  (SOCK-2): it did not come from a page. What refuses such a client is the
  session proof the terminal socket requires of its own (SOCK-3).
  """
  @spec check_origin() :: :conn | [String.t()]
  def check_origin do
    case allowed_origins() do
      [] -> :conn
      origins -> origins
    end
  end
end
