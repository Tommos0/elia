defmodule EliaWeb.Recovery do
  @moduledoc """
  `/recover`: the plain page that reaches the app when a deploy has left the
  app's own UI unusable (spec: `specs/recovery.md`, RECOVER-10–RECOVER-15).

  A deploy runs the live tree's full suite before it loads it (DEPLOY-5), but the
  suite is LiveView-level — no browser (BROWSER-6) — so a broken layout, a hook
  that raises on mount or a class with no rule on a page that kept its stylesheet
  all survive it, and the Settings page, where the undo control lives (CONF-23),
  is exactly what may be broken. This page is the way out.

  It is a plug in the endpoint (RECOVER-10), before the router, in every
  environment, and it renders its own plain HTML — no layout, no CSS bundle, no
  JavaScript, no LiveView socket — so nothing it needs can be what the deploy
  broke. What it reports is the live tree's own deploy record (DEPLOY-2), read
  back through `Elia.Deploy` (RECOVER-11), and what its forms do is hand a
  rollback to `Elia.Deploy.Runner` (RECOVER-12) — the same operation the Settings
  page's own control starts (DEPLOY-26), run outside the request because a build
  and a load is minutes (DEPLOY-15, DEPLOY-16).

  A record that is missing or corrupt renders as "nothing recorded": the whole
  point of the page is that it works when other things do not.
  """

  @behaviour Plug

  import Plug.Conn

  alias Elia.Deploy
  alias Elia.Deploy.Runner

  # RECOVER-10: the one path this plug answers. Everything else goes on to the
  # router untouched.
  @path "/recover"

  # RECOVER-12: the load modes a form may ask for, by the value its `mode` field
  # holds — hot reload (DEPLOY-6) and restart (DEPLOY-7).
  @modes %{"reload" => :reload, "restart" => :restart}

  # The short sha the page shows, and the shortest prefix it accepts back
  # (RECOVER-14).
  @short 7

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if conn.request_path == @path do
      handle(conn)
    else
      conn
    end
  end

  defp handle(conn) do
    case conn.method do
      "GET" ->
        respond(conn, 200, assigns())

      "POST" ->
        post(conn)

      # RECOVER-14: any other method, before the router and before
      # `Plug.MethodOverride`/`Plug.Head` can rewrite it.
      _other ->
        respond(
          conn,
          405,
          assigns("Only GET and POST are allowed on #{@path}."),
          [{"allow", "GET, POST"}]
        )
    end
  end

  ## POST (RECOVER-12 to RECOVER-14)

  defp post(conn) do
    with :ok <- check_origin(conn),
         {:ok, revision} <- check_revision(conn),
         {:ok, mode} <- check_mode(conn) do
      case start_rollback(revision, mode) do
        :ok ->
          respond(conn, 200, assigns())

        # DEPLOY-16: the runner runs one operation at a time.
        {:error, :busy} ->
          respond(
            conn,
            409,
            assigns(
              "An operation is already running: wait for it to finish before going " <>
                "back to a revision."
            )
          )

        {:error, :unavailable} ->
          respond(
            conn,
            503,
            assigns("The deploy runner is not running, so nothing was started.")
          )
      end
    else
      {:error, status, message} -> respond(conn, status, assigns(message))
    end
  end

  # RECOVER-13: the POST is same-origin or it is refused, and nothing runs.
  defp check_origin(conn) do
    if same_origin?(conn) do
      :ok
    else
      {:error, 403,
       "This request did not come from this app: a revision only loads from a " <>
         "same-origin form."}
    end
  end

  # RECOVER-14: the revision must be one the app has run (DEPLOY-25), so there is
  # something to go back to; anything else is refused and nothing runs.
  defp check_revision(conn) do
    case known_revision(conn.params["revision"], Deploy.loaded_revisions()) do
      nil ->
        {:error, 400,
         "The revision this request names is not one the running app has run, so " <>
           "there is nothing to go back to."}

      sha ->
        {:ok, sha}
    end
  end

  defp check_mode(conn) do
    case @modes[conn.params["mode"]] do
      nil ->
        {:error, 400,
         "The load mode this request names is not one this page offers: hot reload " <>
           "or restart."}

      mode ->
        {:ok, mode}
    end
  end

  # A recorded revision, by its full sha or by a prefix of at least a short sha,
  # as the full sha — or nil when the record has no such revision.
  defp known_revision(revision, revisions)
       when is_binary(revision) and byte_size(revision) >= @short do
    Enum.find_value(revisions, fn %{sha: sha} ->
      if sha == revision or String.starts_with?(sha, revision), do: sha
    end)
  end

  defp known_revision(_revision, _revisions), do: nil

  # RECOVER-12, DEPLOY-15, DEPLOY-16: the runner owns the work, not this request
  # — a build and a load is minutes, not a request that hangs.
  defp start_rollback(revision, mode) do
    runner(fn -> Runner.rollback(revision, mode) end, {:error, :unavailable})
  end

  ## The record (RECOVER-11)

  # Everything the page reports, read through `Elia.Deploy` (DEPLOY-23,
  # DEPLOY-25) and the runner (DEPLOY-16). A record that is missing or corrupt
  # reads as "nothing recorded" rather than crashing the page, and so does a
  # runner that is not there.
  defp assigns(error \\ nil) do
    revisions = Deploy.loaded_revisions()
    current = current_revision(revisions)
    state = runner_state()
    running = state.running

    # RECOVER-11: the last operation is the runner's own result when it has one,
    # and otherwise what the record says — which is the operation still marked as
    # running in a record whose process died under it (DEPLOY-23, CONF-22). While
    # an operation runs, the record's `running` field is that one, so it is not
    # reported as the last as well.
    last = if running, do: state.last, else: Deploy.last_deploy() || state.last

    %{
      error: error,
      current: current && short(current),
      behind: behind(),
      running: running && operation(running),
      last: last && operation(last),
      revisions: Enum.map(revisions, &revision(&1, current)),
      disabled: running != nil
    }
  end

  # The revision the running app is on (DEPLOY-17): the newest the record keeps
  # when the loaded-revision file is not there to say it (DEPLOY-25).
  defp current_revision(revisions) do
    Deploy.loaded_revision() ||
      case revisions do
        [%{sha: sha} | _rest] -> sha
        [] -> nil
      end
  end

  # A deploy that merged and never reached the load (DEPLOY-15, DEPLOY-17), which
  # is what a rollback is usually started for (CONF-19).
  defp behind do
    case Deploy.status() do
      {:ok, %{behind?: true, live: live}} ->
        "The live tree is at #{short(live)}, which the running app has not loaded."

      _other ->
        nil
    end
  end

  defp runner_state do
    runner(fn -> Runner.state() end, %{running: nil, last: nil})
  end

  # The runner is Elia's own process (DEPLOY-15, DEPLOY-16); a page that has to
  # work when other things don't does not crash when it is not there.
  defp runner(fun, fallback) do
    if Process.whereis(Runner), do: fun.(), else: fallback
  rescue
    _error -> fallback
  catch
    :exit, _reason -> fallback
  end

  defp revision(revision, current) do
    %{
      short: short(revision.sha),
      sha: revision.sha,
      at: time(revision.at),
      by: by_label(revision.by),
      mode: mode_label(revision.mode),
      current?: revision.sha == current
    }
  end

  defp operation(op) do
    steps = Map.get(op, :steps) || []
    finished = Map.get(op, :finished)
    result = Map.get(op, :result)
    sha = Map.get(op, :sha)
    finished? = not is_nil(finished) or not is_nil(result)

    %{
      what: "#{kind_label(Map.get(op, :kind))} by #{mode_label(Map.get(op, :mode))}",
      started: time(Map.get(op, :started)),
      finished: finished_line(finished),
      finished?: finished?,
      sha: sha && short(sha),
      step: Map.get(op, :step) && Deploy.step_label(Map.get(op, :step)),
      stopped: stopped(Map.get(op, :step), steps, finished?),
      steps: Enum.map(steps, &step_view/1),
      result: result_text(result)
    }
  end

  defp finished_line(nil), do: "It never finished: the process it was running in ended first"
  defp finished_line(finished), do: "It finished at #{time(finished)}"

  # RECOVER-11: where the operation stopped — the step it is on, or the last one
  # it ran — so a page says where a deploy that never finished got to.
  defp stopped(step, steps, finished?) do
    label = (step && Deploy.step_label(step)) || last_step(steps)

    cond do
      is_nil(label) and finished? -> "It reported no steps."
      is_nil(label) -> "It reported no steps before it ended."
      finished? -> "Last step: #{label}."
      true -> "It stopped at: #{label}."
    end
  end

  defp last_step([]), do: nil
  defp last_step(steps), do: steps |> List.last() |> Map.get(:step) |> Deploy.step_label()

  defp step_view(step) do
    %{
      label: Deploy.step_label(step.step),
      took: duration(step.ms),
      failed: failed(step.status)
    }
  end

  defp failed({:failed, reason}), do: reason
  defp failed(_status), do: nil

  defp duration(nil), do: "an unknown time"
  defp duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp result_text(nil), do: "It never finished: it reported no result."
  defp result_text({:ok, message}), do: "It finished: #{message}"
  defp result_text({:tests_failed, output}), do: "The tests failed:\n#{output}"
  defp result_text({:error, reason}), do: "It failed: #{reason}"
  defp result_text({:exit, reason}), do: "The process running it died: #{reason}"
  # A result the record kept as something else (DEPLOY-23): never crash on it.
  defp result_text(other), do: inspect(other)

  defp kind_label(:deploy), do: "A deploy"
  defp kind_label(:rollback), do: "A rollback"
  defp kind_label(_other), do: "An operation"

  defp by_label(:deploy), do: "a deploy"
  defp by_label(:rollback), do: "a rollback"
  defp by_label(other), do: to_string(other)

  defp mode_label(:reload), do: "hot reload"
  defp mode_label(:restart), do: "restart"
  defp mode_label(other), do: to_string(other)

  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
  defp time(nil), do: "an unknown time"
  defp time(other), do: to_string(other)

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, @short)

  ## The origin rule (RECOVER-13)

  # A POST is same-origin when its `Origin` header is an http(s) origin on the
  # scheme the request arrived on and on a host and port the request may have
  # arrived on. Through a proxy that terminates TLS, `https://app.example.com`
  # therefore matches `Host: app.example.com` with `X-Forwarded-Proto: https`.
  defp same_origin?(conn) do
    case origin(conn) do
      nil ->
        false

      %URI{scheme: scheme, host: host, port: port} ->
        String.downcase(scheme) == request_scheme(conn) and
          String.downcase(host) in request_hosts(conn) and
          port in request_ports(conn)
    end
  end

  # The Origin header as a URI, or nil when it is missing, unparseable or not an
  # http(s) origin at all (`null`, a bare host, anything else).
  defp origin(conn) do
    case get_req_header(conn, "origin") do
      [value | _rest] ->
        case parse_uri(value) do
          %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
            if String.downcase(scheme) in ["http", "https"], do: uri

          _other ->
            nil
        end

      [] ->
        nil
    end
  end

  defp parse_uri(value) do
    URI.parse(value)
  rescue
    _error -> nil
  end

  # The scheme the request arrived on: the first `X-Forwarded-Proto` value when a
  # proxy put one there, else the scheme the server received.
  defp request_scheme(conn) do
    case first_value(conn, "x-forwarded-proto") do
      nil -> to_string(conn.scheme)
      scheme -> String.downcase(scheme)
    end
  end

  # The host and port the request may have arrived on: the `Host` header, the
  # first `X-Forwarded-Host` value, and the server's own view of the request. A
  # view without a port has that scheme's default.
  defp request_hosts(conn) do
    conn
    |> views()
    |> Enum.flat_map(fn
      {host, _port} when is_binary(host) -> [String.downcase(host)]
      _other -> []
    end)
  end

  defp request_ports(conn) do
    default = default_port(request_scheme(conn))
    for {_host, port} <- views(conn), do: port || default
  end

  defp views(conn) do
    [
      authority(first_value(conn, "host")),
      authority(first_value(conn, "x-forwarded-host")),
      {conn.host, conn.port}
    ]
  end

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80

  defp first_value(conn, header) do
    case get_req_header(conn, header) do
      [value | _rest] -> value |> String.split(",") |> hd() |> String.trim()
      [] -> nil
    end
  end

  # "host", "host:port" or an IPv6 host in brackets, as `{host, port | nil}`.
  defp authority(nil), do: {nil, nil}
  defp authority("[" <> _rest = value), do: bracketed(value)

  defp authority(value) do
    case String.split(value, ":") do
      [host] -> {host, nil}
      [host, port] -> {host, port(port)}
      _other -> {value, nil}
    end
  end

  defp bracketed(value) do
    case String.split(value, "]") do
      [host, port] -> {String.trim_leading(host, "["), port |> String.trim_leading(":") |> port()}
      _other -> {value, nil}
    end
  end

  defp port(value) do
    case Integer.parse(value) do
      {port, ""} -> port
      _other -> nil
    end
  end

  ## The response (RECOVER-10)

  defp respond(conn, status, assigns, headers \\ []) do
    conn
    |> merge_resp_headers(headers)
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, render(assigns))
    # RECOVER-10: nothing after this plug sees the request — it is this page's
    # own, and the router has no route for it — so a response for a page that
    # needs nothing else cannot be touched by anything else.
    |> halt()
  end

  # The page's own small stylesheet, inline (RECOVER-10): the page has no
  # dependency on `priv/static`, so nothing a deploy builds has to be there —
  # or be intact — for this page to be legible.
  @style """
  <style>
    :root { color-scheme: light dark; }
    body { font: 16px/1.5 system-ui, -apple-system, sans-serif; margin: 0; padding: 1.5rem 1rem; }
    main { max-width: 48rem; margin: 0 auto; }
    h1 { font-size: 1.5rem; margin: 0 0 0.5rem; }
    h2 { font-size: 1.125rem; margin: 2rem 0 0.5rem; }
    p, li { margin: 0.5rem 0; }
    code { font: 0.875em ui-monospace, monospace; background: rgba(127, 127, 127, 0.15); padding: 0.1em 0.3em; border-radius: 0.25rem; }
    .muted { opacity: 0.7; }
    .error { border: 1px solid #c62828; border-left-width: 0.35rem; padding: 0.75rem; border-radius: 0.375rem; }
    .failed { color: #c62828; }
    ul.revisions { list-style: none; padding: 0; }
    ul.revisions > li { border-top: 1px solid rgba(127, 127, 127, 0.25); padding: 0.75rem 0; }
    ol.steps { padding-left: 1.25rem; }
    form { display: block; margin-top: 0.5rem; }
    button { font: inherit; padding: 0.35rem 0.75rem; margin: 0.25rem 0.5rem 0 0; border: 1px solid rgba(127, 127, 127, 0.5); border-radius: 0.375rem; background: rgba(127, 127, 127, 0.12); color: inherit; cursor: pointer; }
    button:disabled { opacity: 0.5; cursor: default; }
    pre { white-space: pre-wrap; word-break: break-word; background: rgba(127, 127, 127, 0.1); padding: 0.75rem; border-radius: 0.375rem; }
  </style>
  """

  # The whole page (RECOVER-10): its own markup, built here rather than by a
  # template engine, so that this page needs no layout and no LiveView — the
  # thing it may have to render while is broken. Every value that comes from the
  # record goes through `esc/1`.
  defp render(assigns) do
    [
      "<!DOCTYPE html>\n",
      ~s(<html lang="en">\n<head>\n<meta charset="utf-8">\n),
      ~s(<meta name="viewport" content="width=device-width, initial-scale=1">\n),
      "<title>Recover</title>\n",
      refresh(assigns),
      @style,
      "</head>\n<body>\n<main>\n",
      "<h1>Recover</h1>\n",
      """
      <p class="muted">
        This page is plain HTML: no JavaScript, no stylesheet, no bundle. It answers
        when a deploy has left the rest of the app unusable, and it sends the running
        app back to a revision it has run before.
      </p>
      """,
      # RECOVER-15: the way back to the app.
      ~s(<p id="recover-back"><a href="/">Back to the app</a></p>\n),
      error(assigns),
      current(assigns),
      running(assigns),
      revisions(assigns),
      last(assigns),
      "</main>\n</body>\n</html>\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp refresh(%{running: nil}), do: ""
  defp refresh(_assigns), do: ~s(<meta http-equiv="refresh" content="5">\n)

  defp error(%{error: nil}), do: ""

  defp error(%{error: message}) do
    ~s(<p id="recover-error" class="error">#{esc(message)}</p>\n)
  end

  # RECOVER-11: what the running app is on, and — when the live tree has moved on
  # without a load (DEPLOY-15, DEPLOY-17) — that it has.
  defp current(assigns) do
    line =
      if assigns.current,
        do: "The running app is on <code>#{esc(assigns.current)}</code>.",
        else: "No revision is recorded as loaded."

    [
      "<h2>What the app is running</h2>\n",
      ~s(<p id="recover-current">#{line}</p>\n),
      behind(assigns)
    ]
  end

  defp behind(%{behind: nil}), do: ""
  defp behind(%{behind: line}), do: ~s(<p id="recover-behind">#{esc(line)}</p>\n)

  # RECOVER-12: an operation running now, and the step it is on (DEPLOY-21,
  # DEPLOY-22).
  defp running(%{running: nil}), do: ""

  defp running(%{running: running}) do
    [
      ~s(<section id="recover-running">\n),
      "<h2>#{esc(running.what)} is running</h2>\n",
      "<p>It started at #{esc(running.started)}.</p>\n",
      case running.step do
        nil -> ~s(<p id="recover-step">It has not reported a step yet.</p>\n)
        step -> ~s(<p id="recover-step">It is on: #{esc(step)}.</p>\n)
      end,
      steps(running.steps, "recover-running-steps", "recover-running-step-"),
      """
      <p>
        <a id="recover-refresh" href="/recover">Reload this page</a> to follow it: the
        page reloads itself every few seconds while the operation runs.
      </p>
      """,
      "</section>\n"
    ]
  end

  # RECOVER-11, DEPLOY-25: the revisions the app has run, newest first, each with
  # when it was loaded and by what; and RECOVER-12: a form back to each one that
  # is not the one running.
  defp revisions(assigns) do
    [
      "<section id=\"recover-revisions\">\n<h2>Revisions the app has run</h2>\n",
      entries(assigns),
      "</section>\n"
    ]
  end

  defp entries(%{revisions: []}) do
    """
    <p id="recover-no-revisions" class="muted">
      Nothing is recorded: no revision has been loaded, so there is nothing to go back to.
    </p>
    """
  end

  defp entries(assigns) do
    [
      "<ul class=\"revisions\">\n",
      Enum.map(assigns.revisions, &revision_entry(&1, assigns.disabled)),
      "</ul>\n"
    ]
  end

  defp revision_entry(revision, disabled) do
    [
      "<li id=\"recover-revision-#{esc(revision.short)}\">\n<div>\n",
      "<code>#{esc(revision.short)}</code>\n",
      if(revision.current?, do: "<span>(running now)</span>\n", else: ""),
      "<span class=\"muted\">— loaded #{esc(revision.at)} by #{esc(revision.by)}, ",
      "#{esc(revision.mode)}</span>\n</div>\n",
      if(revision.current?, do: "", else: form(revision, disabled)),
      "</li>\n"
    ]
  end

  defp form(revision, disabled) do
    [
      "<form id=\"recover-form-#{esc(revision.short)}\" method=\"post\" action=\"/recover\">\n",
      ~s(<input type="hidden" name="revision" value="#{esc(revision.sha)}">\n),
      "<button type=\"submit\" name=\"mode\" value=\"reload\" ",
      "id=\"recover-reload-#{esc(revision.short)}\"#{disabled(disabled)}>",
      "Hot reload this revision</button>\n",
      "<button type=\"submit\" name=\"mode\" value=\"restart\" ",
      "id=\"recover-restart-#{esc(revision.short)}\"#{disabled(disabled)}>",
      "Restart on this revision</button>\n",
      "</form>\n"
    ]
  end

  defp disabled(true), do: " disabled"
  defp disabled(false), do: ""

  # RECOVER-11: the last deploy or rollback, from the record (DEPLOY-23) — what
  # it was, whether it finished, where it stopped and its result.
  defp last(%{last: nil}) do
    """
    <section id="recover-last">
      <h2>Last deploy or rollback</h2>
      <p id="recover-nothing" class="muted">
        Nothing is recorded: no deploy or rollback has been recorded in this live tree.
      </p>
    </section>
    """
  end

  defp last(%{last: last}) do
    [
      "<section id=\"recover-last\">\n<h2>Last deploy or rollback</h2>\n",
      "<p id=\"recover-last-what\">#{esc(last.what)}, started #{esc(last.started)}.</p>\n",
      "<p id=\"recover-last-finished\">#{esc(last.finished)}.</p>\n",
      if(last.sha,
        do:
          "<p id=\"recover-last-revision\">It was going back to <code>#{esc(last.sha)}</code>.</p>\n",
        else: ""
      ),
      "<p id=\"recover-last-stopped\">#{esc(last.stopped)}</p>\n",
      steps(last.steps, "recover-last-steps", "recover-last-step-"),
      "<pre id=\"recover-last-result\">#{esc(last.result)}</pre>\n",
      "</section>\n"
    ]
  end

  defp steps([], _id, _prefix), do: ""

  defp steps(steps, id, prefix) do
    [
      "<ol id=\"#{id}\" class=\"steps\">\n",
      steps
      |> Enum.with_index()
      |> Enum.map(fn {step, index} ->
        [
          "<li id=\"#{prefix}#{index}\">#{esc(step.label)} — #{esc(step.took)}",
          if(step.failed,
            do: ~s( <span class="failed">failed: #{esc(step.failed)}</span>),
            else: ""
          ),
          "</li>\n"
        ]
      end),
      "</ol>\n"
    ]
  end

  # A value the record or a request gave us, as text in the page: never markup.
  defp esc(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
