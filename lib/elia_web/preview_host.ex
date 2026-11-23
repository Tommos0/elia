defmodule EliaWeb.PreviewHost do
  @moduledoc """
  A project's build output served at a hostname of their own
  (`specs/preview-host.md`).

  The app's own origin must never serve a file that carries script: a raw view
  of an HTML document is sandboxed with its scripts off (EXPL-24), deliberately,
  so a file from a workspace can never run in this app's origin. A preview host
  is the other way round — the build output of one project, at a hostname that
  is not the app's, under no policy of the preview's own — so a project's build
  runs in a browser as it does from any web server, while the app's origin stays
  untouched (SERVE-1 - SERVE-5). What it serves is that project's `dist` folder
  and nothing beside it (SERVE-16, SERVE-17).

  It is a plug at the top of the endpoint rather than a route in the router:
  on the preview host nothing of the app may be reached, not even a static file
  (SERVE-3), so the check has to come before every other plug — and on any other
  host it does nothing at all (SERVE-4).
  """

  @behaviour Plug

  import Plug.Conn

  alias Elia.{Explorer, Projects}

  @doc """
  The host the preview is served at — `ELIA_PREVIEW_HOST` (SERVE-1) — or `nil`
  when the install has none (SERVE-2).
  """
  @spec host() :: String.t() | nil
  def host do
    case :elia |> Application.get_env(__MODULE__, []) |> Keyword.get(:host) do
      host when is_binary(host) ->
        case host |> String.trim() |> String.downcase() do
          "" -> nil
          host -> host
        end

      _other ->
        nil
    end
  end

  @doc "Whether the install serves a preview host at all (SERVE-2)."
  @spec enabled?() :: boolean()
  def enabled?, do: host() != nil

  @doc """
  The URL of `segments` — a project's slug and then its path's own segments — on
  the preview host (SERVE-15), or `nil` when there is none. A host that names a
  port is reached over plain HTTP, since that is what a port on a hostname on
  this machine or its network is; one without is reached over HTTPS, which is
  what a name behind a proxy is.
  """
  @spec url([String.t()]) :: String.t() | nil
  def url(segments) do
    case host() do
      nil ->
        nil

      host ->
        scheme = if String.contains?(host, ":"), do: "http", else: "https"
        path = Enum.map_join(segments, "/", &URI.encode/1)
        "#{scheme}://#{host}/#{path}"
    end
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case host() do
      nil ->
        conn

      host ->
        if requested_host(conn) == normalise(host, scheme(conn)),
          do: serve(conn),
          else: conn
    end
  end

  # SERVE-14: only a read is served. Every answer halts, since on this host no
  # other plug may answer — not the static files, not the router (SERVE-3).
  defp serve(conn) do
    conn =
      case conn.method do
        "GET" -> respond(conn)
        "HEAD" -> respond(conn)
        _other -> conn |> put_resp_header("allow", "GET, HEAD") |> send_resp(405, "")
      end

    halt(conn)
  end

  # SERVE-16, SERVE-17: the file a request names — under the `dist` folder of
  # the project whose slug the first segment is (PROJ-34), and nothing else of
  # that project's. The root and a first segment that is no project's slug name
  # no project at all, and are answered like any other path that is not a file.
  defp respond(conn) do
    case target(conn.request_path) do
      nil ->
        send_resp(conn, 404, "Not found")

      {root, rel} ->
        case Explorer.served_file(rel, root) do
          {:ok, file} -> send_served(conn, file)
          {:error, _reason} -> send_resp(conn, 404, "Not found")
        end
    end
  end

  defp target(request_path) do
    case request_path |> URI.decode() |> String.split("/", trim: true) do
      [first | rest] ->
        case project_by_slug(first) do
          nil -> nil
          project -> {Path.join(project.folder, "dist"), Enum.join(rest, "/")}
        end

      [] ->
        nil
    end
  end

  defp project_by_slug(segment) do
    Enum.find(Projects.list(), &(Projects.slug(&1.name) == segment))
  end

  # SERVE-9, SERVE-11, SERVE-12: the file's own bytes under its type, with the
  # validators a browser revalidates by and no policy of the preview's own — a
  # page here runs its own scripts, which is the whole point of this host.
  defp send_served(conn, file) do
    etag = etag(file)

    conn =
      conn
      |> put_resp_header("content-type", file.type)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("etag", etag)
      |> put_resp_header("last-modified", http_date(file.mtime))

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      respond_with_file(conn, file)
    end
  end

  # A HEAD is answered with the headers a GET would send and no body: Bandit
  # strips the body of a HEAD itself, so the `content-length` is the file's.
  defp respond_with_file(%{method: "HEAD"} = conn, file) do
    conn
    |> put_resp_header("content-length", Integer.to_string(file.size))
    |> send_resp(200, "")
  end

  defp respond_with_file(conn, file), do: send_file(conn, 200, file.file)

  defp etag(file), do: ~s("#{file.size}-#{file.mtime}")

  # SERVE-5: the request's host, read the way RECOVER-13 reads a request's
  # origin — any of the `Host` header, the first `X-Forwarded-Host` value or the
  # server's own view of the request, with a missing port meaning the default
  # port of the scheme (the first `X-Forwarded-Proto` value, else the one the
  # request arrived with).
  defp requested_host(conn) do
    [
      first_header(conn, "host"),
      first_header(conn, "x-forwarded-host"),
      "#{conn.host}:#{conn.port}"
    ]
    |> Enum.find_value(&normalise(&1, scheme(conn)))
  end

  defp first_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> nil
    end
  end

  defp scheme(conn) do
    case first_header(conn, "x-forwarded-proto") do
      nil -> conn.scheme |> Atom.to_string()
      proto -> String.downcase(proto)
    end
  end

  # "host" and "host:port" as "host:port", a missing port being the scheme's
  # default. An IPv6 literal in brackets is left as it is written.
  defp normalise(nil, _scheme), do: nil

  defp normalise(host, scheme) when is_binary(host) do
    case host |> String.trim() |> String.downcase() do
      "" ->
        nil

      host ->
        case String.split(host, ":", parts: 2) do
          ["[" <> _ = host, port] -> host <> ":" <> port
          [name, ""] -> name <> ":" <> default_port(scheme)
          [name, port] -> name <> ":" <> port
          [name] -> name <> ":" <> default_port(scheme)
        end
    end
  end

  defp default_port("https"), do: "443"
  defp default_port(_scheme), do: "80"

  defp http_date(posix) do
    posix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end
end
