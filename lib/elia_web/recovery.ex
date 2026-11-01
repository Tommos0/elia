defmodule EliaWeb.Recovery do
  @moduledoc """
  Rolls the workspace back to a checkpoint when the dev app is too broken to
  ask the agent for help (spec: `specs/recovery.md`).

  The endpoint puts this plug *before* `Phoenix.CodeReloader`, so `/recover`
  answers even when the project doesn't compile. For every other
  request it registers a `before_send` hook that adds a banner linking here
  to HTML 500 pages (Phoenix's compilation error page and the debugger page).

  It sits before the code reloader and only calls modules loaded at boot, so
  its running version stays the boot-time one while the rest of the app is
  broken.

  Option `:checkpoints` (default `Elia.Checkpoint`) is the module providing
  `list/1` and `rollback/1`; tests use it to simulate failures.
  """

  @behaviour Plug

  import Plug.Conn

  @path ["recover"]
  @listed 20
  @accepted 100

  @impl true
  def init(opts), do: Keyword.put_new(opts, :checkpoints, Elia.Checkpoint)

  @impl true
  def call(conn, opts) do
    conn = put_private(conn, :elia_recovery_checkpoints, Keyword.fetch!(opts, :checkpoints))

    case conn.path_info do
      @path -> conn |> handle() |> halt()
      _ -> register_before_send(conn, &add_banner/1)
    end
  end

  defp checkpoints(conn), do: conn.private.elia_recovery_checkpoints

  ## Requests

  defp handle(conn) do
    case conn.method do
      "GET" ->
        index(conn)

      "POST" ->
        post(conn)

      _ ->
        conn
        |> put_resp_header("allow", "GET, POST")
        |> page(405, "Method not allowed", "<p>Use GET or POST.</p>")
    end
  end

  defp index(conn) do
    entries = checkpoints(conn).list(@listed)
    recommended = recommended(conn, entries)

    rows =
      for cp <- ordered(entries, recommended) do
        tag = if cp == recommended, do: " <strong>(recommended)</strong>", else: ""

        """
        <tr>
          <td><code>#{short(cp.sha)}</code></td>
          <td>#{esc(cp.at)}</td>
          <td>#{esc(cp.label)}#{tag}</td>
          <td>#{button(cp.sha, "Roll back")}</td>
        </tr>
        """
      end

    body =
      case rows do
        [] ->
          "<p>There are no checkpoints yet.</p>"

        rows ->
          """
          <p>Restores the workspace files to a checkpoint. The current state is
          snapshotted first, so you can undo it afterwards.</p>
          <table>
            <tr><th>Checkpoint</th><th>Taken</th><th>Label</th><th></th></tr>
            #{rows}
          </table>
          """
      end

    page(conn, 200, "Recover", body <> ~s(<p><a href="/">Back to the app</a></p>))
  end

  defp post(conn) do
    with true <- same_origin?(conn),
         {:ok, body, conn} <- read_body(conn, length: 4_096) do
      rollback(conn, decode(body)["checkpoint"])
    else
      false -> page(conn, 403, "Forbidden", "<p>Cross-origin request refused.</p>")
      _ -> page(conn, 400, "Bad request", "<p>Could not read the request.</p>")
    end
  end

  defp rollback(conn, sha) do
    store = checkpoints(conn)

    if is_binary(sha) and Enum.any?(store.list(@accepted), &(&1.sha == sha)) do
      case store.rollback(sha) do
        {:ok, undo} ->
          reload_skills()
          page(conn, 200, "Rolled back", rolled_back(sha, undo))

        {:error, reason} ->
          page(conn, 500, "Rollback failed", "<pre>#{esc(reason)}</pre>")
      end
    else
      page(conn, 400, "Unknown checkpoint", "<p>That checkpoint isn't in the recent list.</p>")
    end
  end

  defp rolled_back(sha, undo) do
    """
    <p>Restored the workspace to <code>#{short(sha)}</code>.</p>
    <p>The running app only changes after a deploy.</p>
    <p>#{button(undo, "Undo this rollback")}</p>
    <p><a href="/">Back to the app</a></p>
    """
  end

  defp reload_skills do
    Elia.Skills.reload()
  rescue
    _ -> :ok
  end

  defp decode(body) do
    URI.decode_query(body)
  rescue
    ArgumentError -> %{}
  end

  ## Forgery protection

  # A POST must come from a page served at this address (RECOVER-9). Behind a
  # proxy the server sees its own scheme and port, so the public ones are
  # taken from the forwarding headers.
  defp same_origin?(conn) do
    with [origin] <- get_req_header(conn, "origin"),
         %URI{scheme: scheme, host: host, port: port} = uri when scheme in ["http", "https"] <-
           URI.parse(origin),
         true <- is_binary(host) do
      scheme == public_scheme(conn) and
        Enum.any?(authorities(conn), fn {auth_host, auth_port} ->
          normalize(auth_host) == normalize(host) and
            (auth_port || URI.default_port(uri.scheme)) == port
        end)
    else
      _ -> false
    end
  end

  defp public_scheme(conn) do
    case first_value(conn, "x-forwarded-proto") do
      proto when proto in ["http", "https"] -> proto
      _ -> to_string(conn.scheme)
    end
  end

  # `{host, port | nil}` for the Host header, the first X-Forwarded-Host value
  # and the server's own view of the request.
  defp authorities(conn) do
    from_headers =
      for name <- ["host", "x-forwarded-host"],
          value = first_value(conn, name),
          %URI{host: host, port: port} when is_binary(host) <- [URI.parse("//" <> value)],
          do: {host, port}

    from_headers ++ [{conn.host, server_port(conn)}]
  end

  # The port the server saw, unless it's just the default for its scheme (a
  # TLS-terminating proxy makes that differ from the public one).
  defp server_port(conn) do
    if conn.port == URI.default_port(to_string(conn.scheme)), do: nil, else: conn.port
  end

  defp first_value(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value |> String.split(",") |> hd() |> String.trim() |> String.downcase()
      [] -> nil
    end
  end

  defp normalize(host), do: host |> String.replace(["[", "]"], "") |> String.downcase()
  ## Banner on crash pages

  defp add_banner(%Plug.Conn{status: 500} = conn) do
    with true <- html?(conn),
         [] <- get_resp_header(conn, "content-encoding"),
         body when is_binary(body) or is_list(body) <- conn.resp_body,
         html = IO.iodata_to_binary(body),
         [{start, len}] <- Regex.run(~r/<body[^>]*>/i, html, return: :index) do
      cut = start + len
      <<head::binary-size(cut), rest::binary>> = html
      %{conn | resp_body: [head, banner(conn), rest]}
    else
      _ -> conn
    end
  rescue
    _ -> conn
  catch
    :exit, _ -> conn
  end

  defp add_banner(conn), do: conn

  defp html?(conn) do
    case get_resp_header(conn, "content-type") do
      ["text/html" <> _ | _] -> true
      _ -> false
    end
  end

  defp banner(conn) do
    entries = checkpoints(conn).list(@listed)

    action =
      case recommended(conn, entries) do
        nil -> ""
        cp -> button(cp.sha, "Roll back to the last checkpoint before a change", :banner)
      end

    """
    <div id="elia-recovery-banner" style="position:fixed;top:0;left:0;right:0;z-index:2147483647;\
    background:#7f1d1d;color:#fff;padding:8px 12px;font:14px/1.4 system-ui,sans-serif;\
    display:flex;gap:12px;align-items:center;flex-wrap:wrap">
      <strong>Elia recovery</strong>
      #{action}
      <a href="/recover" style="color:#fff;text-decoration:underline">Choose a checkpoint</a>
    </div>
    """
  end

  ## Helpers

  # CKPT-9: the newest agent-turn checkpoint that rolling back would change.
  defp recommended(conn, entries) do
    store = checkpoints(conn)

    case store.current_tree() do
      {:ok, tree} -> store.recommended(entries, tree)
      _ -> nil
    end
  end

  defp ordered(entries, nil), do: entries
  defp ordered(entries, recommended), do: [recommended | List.delete(entries, recommended)]

  defp short(sha), do: sha |> String.slice(0, 12) |> esc()

  defp esc(text), do: text |> to_string() |> Plug.HTML.html_escape()

  defp button(sha, text, style \\ :page) do
    css =
      case style do
        :banner ->
          "padding:4px 10px;border:0;border-radius:4px;background:#fff;color:#7f1d1d;cursor:pointer"

        :page ->
          "padding:4px 10px;cursor:pointer"
      end

    """
    <form method="post" action="/recover" style="display:inline;margin:0">\
    <input type="hidden" name="checkpoint" value="#{esc(sha)}">\
    <button type="submit" style="#{css}">#{esc(text)}</button></form>\
    """
  end

  defp page(conn, status, title, body) do
    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>#{esc(title)} · Elia recovery</title>
      <style>
        body { font: 15px/1.5 system-ui, sans-serif; max-width: 52rem; margin: 2rem auto; padding: 0 1rem; }
        table { border-collapse: collapse; width: 100%; }
        th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid #ddd; }
      </style>
    </head>
    <body>
      <h1>#{esc(title)}</h1>
      #{body}
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end
end
