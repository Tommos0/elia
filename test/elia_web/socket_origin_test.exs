defmodule EliaWeb.SocketOriginTest do
  @moduledoc """
  Who may open a socket (SOCK-1 - SOCK-5, `specs/socket-origin.md`): a handshake
  is bound to a page this server served, and the terminal's must also present a
  session this server issued.

  The handshakes here go through the endpoint, so they are answered by Phoenix's
  own transport — the origin check and the session proof it derives — rather
  than by a socket built by hand, and a refusal is the 403 a browser would see.
  A test that connects a socket with `Phoenix.ChannelTest.socket/1` bypasses
  that layer by design, which is why the join path is tested separately
  (`test/elia_web/terminal_channel_test.exs`).
  """
  use EliaWeb.ConnCase, async: true

  alias EliaWeb.SocketOrigin

  # The session cookie the browser pipeline sets (`@session_options` in
  # `EliaWeb.Endpoint`), which is what a handshake presents.
  @session_cookie "_elia_key"

  @terminal "/terminal/websocket"
  @live "/live/websocket"

  describe "SOCK-1: the origin must be the request's own" do
    test "a handshake from another page's origin is refused", %{conn: conn} do
      assert handshake(conn, @terminal, origin: "http://elsewhere.test").status == 403
    end

    test "the LiveView socket is bound the same way", %{conn: conn} do
      assert handshake(conn, @live, origin: "https://elsewhere.test").status == 403
    end

    # Both transports of both sockets: the long poll handshake is the same
    # request judged by the same policy, and it answers with its own JSON
    # rather than the websocket transport's empty 403.
    test "the long poll transport is bound too", %{conn: conn} do
      for path <- ["/terminal/longpoll", "/live/longpoll"] do
        conn = handshake(conn, path, origin: "http://elsewhere.test")

        assert conn.status == 200
        assert refused_longpoll?(conn)
      end
    end

    test "another scheme, host or port is another origin", %{conn: conn} do
      assert handshake(conn, @terminal, origin: "https://#{conn.host}:#{conn.port}").status == 403

      assert handshake(conn, @terminal, origin: "http://#{conn.host}:#{conn.port + 1}").status ==
               403

      assert handshake(conn, @terminal, origin: "http://elsewhere.test:#{conn.port}").status ==
               403
    end

    # The binding is the *endpoint's* policy rather than a default it happens to
    # have: `config/runtime.exs` sets it from `EliaWeb.SocketOrigin` in every
    # environment, which is what this asserts — the dev environment used to turn
    # the check off in `config/dev.exs`.
    test "the endpoint's own policy is this binding" do
      assert EliaWeb.Endpoint.config(:check_origin) == SocketOrigin.check_origin()
      assert EliaWeb.Endpoint.config(:check_origin) == :conn
    end
  end

  describe "SOCK-2: a handshake that is not a page" do
    # SOCK-2, SOCK-3: a client that presents no Origin is not refused for that
    # — it is not a page — and what a handshake with no proof meets is SOCK-3.
    test "with no Origin, the terminal still wants a proof", %{conn: conn} do
      assert handshake(conn, @terminal, origin: nil).status == 403
    end

    test "with no Origin, the LiveView socket connects", %{conn: conn} do
      assert upgraded?(handshake(conn, @live, origin: nil))
    end

    test "with no Origin, the page's own proof is what a handshake needs", %{conn: conn} do
      page = get(conn, ~p"/")

      assert upgraded?(handshake(page, @terminal, origin: nil, proof: proof(page)))
    end
  end

  describe "SOCK-3: the terminal socket wants a session this server issued" do
    test "a handshake with no session at all is refused", %{conn: conn} do
      assert handshake(conn, @terminal).status == 403
    end

    test "a session with no token of its own is refused", %{conn: conn} do
      page = get(conn, ~p"/")
      proof = proof(page)

      assert handshake(page, @terminal, proof: %{proof | token: ""}).status == 403
    end

    # A token is that session's: what the page handed one browser does not open
    # the socket for the session the page handed another. The second page is
    # loaded in a process of its own, so it is a session of its own — Plug's
    # CSRF state is per-process as well as per-session, and two loads in one
    # process would carry one state.
    test "a token from another session is refused", %{conn: conn} do
      first = get(conn, ~p"/")
      second = Task.async(fn -> get(Phoenix.ConnTest.build_conn(), ~p"/") end) |> Task.await()

      refute proof(first).cookie == proof(second).cookie
      refute proof(first).token == proof(second).token

      # The first page's session, the second page's token.
      mixed = %{proof(second) | cookie: proof(first).cookie}

      assert handshake(first, @terminal, proof: mixed).status == 403
    end

    test "the LiveView socket needs no such proof of its own", %{conn: conn} do
      # SOCK-3 is the terminal's; SOCK-1 is what bounds `/live`, and a
      # handshake at its own origin is not refused for having no session.
      assert upgraded?(handshake(conn, @live))
    end
  end

  describe "SOCK-4: an install reached at another origin" do
    test "names its origins, and none configured is the host binding" do
      with_allowed_origins(nil, fn ->
        assert SocketOrigin.allowed_origins() == []
        assert SocketOrigin.check_origin() == :conn
      end)

      with_allowed_origins("https://elia.example.com, //elia.example.com:8443,", fn ->
        assert SocketOrigin.allowed_origins() == [
                 "https://elia.example.com",
                 "//elia.example.com:8443"
               ]

        assert SocketOrigin.check_origin() == [
                 "https://elia.example.com",
                 "//elia.example.com:8443"
               ]
      end)
    end

    test "a blank setting is no setting" do
      with_allowed_origins("  ", fn ->
        assert SocketOrigin.allowed_origins() == []
        assert SocketOrigin.check_origin() == :conn
      end)
    end

    # An origin outside the setting is still refused: the list is the policy,
    # not an addition to the host binding.
    test "a named origin does not widen what an unconfigured install accepts", %{conn: conn} do
      assert handshake(conn, @terminal, origin: "http://elsewhere.test").status == 403
    end
  end

  describe "SOCK-5: the app's own pages are unaffected" do
    # The whole of it, as a browser does it: the page this server served, the
    # cookie and the CSRF token it answered with, and the handshake the page's
    # own hook sends (assets/js/terminal.js).
    test "the page's own handshake is upgraded", %{conn: conn} do
      page = get(conn, ~p"/")
      assert page.status == 200

      assert upgraded?(handshake(page, @terminal, proof: proof(page)))
    end

    # What the page carries is the ordinary case, in the query string the
    # browser's socket client uses.
    test "the proof is the session cookie and the token the page rendered", %{conn: conn} do
      page = get(conn, ~p"/")
      proof = proof(page)

      assert String.starts_with?(proof.cookie, @session_cookie <> "=")
      assert String.length(proof.token) > 0
    end
  end

  ## Helpers

  # SOCK-4's setting is the environment's, so a test that sets it puts it back
  # the way it found it — the node's environment is shared.
  defp with_allowed_origins(value, fun) do
    previous = System.get_env("ELIA_ALLOWED_ORIGINS")

    on_exit(fn ->
      if previous do
        System.put_env("ELIA_ALLOWED_ORIGINS", previous)
      else
        System.delete_env("ELIA_ALLOWED_ORIGINS")
      end
    end)

    if value do
      System.put_env("ELIA_ALLOWED_ORIGINS", value)
    else
      System.delete_env("ELIA_ALLOWED_ORIGINS")
    end

    fun.()
  end

  # A page the browser pipeline served (SOCK-5): its session cookie and the
  # CSRF token in its markup, which is what the terminal page's hook sends with
  # its handshake.
  defp proof(page) do
    cookie = page.resp_cookies |> Map.fetch!(@session_cookie) |> Map.fetch!(:value)

    %{cookie: "#{@session_cookie}=#{cookie}", token: csrf_token!(page.resp_body)}
  end

  defp csrf_token!(body) do
    case Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, body) do
      [_, token] -> token
      nil -> flunk("the page rendered no csrf-token meta tag for a handshake to carry")
    end
  end

  # A handshake as a browser sends it: a GET to the socket's own path, at the
  # page's own host, with the Origin a page there sends — and, where the socket
  # wants one, the proof the page carries (SOCK-1, SOCK-3).
  defp handshake(page, path, opts \\ []) do
    EliaWeb.Endpoint.call(handshake_conn(page, path, opts), [])
  end

  defp handshake_conn(page, path, opts) do
    origin = Keyword.get(opts, :origin, own_origin(page))
    proof = Keyword.get(opts, :proof)

    path =
      case proof do
        nil -> path
        proof -> path <> "?" <> URI.encode_query(%{"_csrf_token" => proof.token})
      end

    conn =
      :get
      |> Plug.Test.conn(path)
      |> Map.merge(Map.take(page, [:host, :port, :scheme]))
      |> with_host_header()
      |> upgrade_headers()

    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
    conn = if proof, do: put_req_header(conn, "cookie", proof.cookie), else: conn

    conn
  end

  # The Host header a real request carries. Plug keeps it in `conn.host` and
  # refuses `put_req_header("host", ...)`, but the upgrade validation reads it as
  # a header, so a handshake built here hands it over as one.
  defp with_host_header(conn), do: %{conn | req_headers: [{"host", conn.host} | conn.req_headers]}

  # What a browser's WebSocket handshake carries. Without them an accepted
  # handshake never reaches the upgrade — Phoenix's transport answers the
  # upgrade validation's own error with a 400 — so a test that is really about
  # the origin and the proof is not answered by it by accident.
  defp upgrade_headers(conn) do
    conn
    |> put_req_header("connection", "Upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-version", "13")
    |> put_req_header("sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16)))
  end

  # The long poll transport answers a refused handshake with this JSON
  # (`Phoenix.Transports.LongPoll.status_json/1`), which is its refusal.
  defp refused_longpoll?(conn) do
    Jason.decode!(IO.iodata_to_binary(conn.resp_body)) == %{"status" => 403}
  end

  # The origin a page at this host sends: the request's own scheme, host and
  # port, which is exactly what SOCK-1 binds a handshake to.
  defp own_origin(conn), do: "#{conn.scheme}://#{conn.host}:#{conn.port}"

  # An accepted handshake is the 101 the transport answered it with; a refused
  # one is a 403 (or a 400 where the request was not a handshake at all).
  defp upgraded?(conn) do
    assert conn.status == 101
    assert conn.halted
    true
  end
end
