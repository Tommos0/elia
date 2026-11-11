defmodule Elia.LLM.LlamaServer do
  @moduledoc """
  The local `llama-server` Elia can start, stop and report on (LOCAL-11 to
  LOCAL-23).

  One process at a time, under the application's supervisor, started through
  `Elia.Priority.spawn_argv/3` so it runs below the server's own CPU and I/O
  priority like every other process Elia spawns (PRIO-9, LOCAL-12) and killed
  the way a timed-out command is (SHELL-3, LOCAL-18). It is deliberately not
  jailed: it has to read a `.gguf` that lives outside the workspace and listen
  on a port.

  Configuration (`config :elia, Elia.LLM.LlamaServer, ...`). Every field may be
  saved in Settings instead, which wins (LOCAL-14, LOCAL-28):

    * `:binary` - `llama-server`; else `LLAMA_SERVER_BIN`, else the one on PATH
    * `:models_dir` - else `LLAMA_MODELS_DIR`; where `.gguf` files are offered
    * `:model` - the `.gguf` to load
    * `:host`, `:port` - where it listens (default `127.0.0.1:8080`)
    * `:context`, `:threads` - `-c` and `-t`, sent only when set
    * `:jinja` - `--jinja`, which tool calls need (default on)
    * `:api_key` - `--api-key`, sent only when set (LOCAL-2)
    * `:extra_args` - appended as given
    * `:log_lines` - how much of its output is kept (default 200)
    * `:startup_timeout` - how long `GET /health` is polled (default 60s)
  """

  use GenServer

  require Logger

  alias Elia.Settings

  @name __MODULE__
  @topic "llama_server"

  # LOCAL-14: the defaults of the moduledoc, so a configuration that names one
  # field still gets the rest.
  @defaults [
    binary: nil,
    models_dir: nil,
    model: nil,
    host: "127.0.0.1",
    port: 8080,
    context: nil,
    threads: nil,
    jinja: true,
    api_key: nil,
    extra_args: [],
    log_lines: 200,
    startup_timeout: 60_000
  ]

  @fields [
    :binary,
    :models_dir,
    :model,
    :host,
    :port,
    :context,
    :threads,
    :jinja,
    :api_key,
    :extra_args
  ]

  # LOCAL-17: the poll of `GET /health` while it starts; LOCAL-16: how long an
  # answer about an outside server is reused.
  @poll_interval 250

  ## Supervision

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @impl true
  def init(_opts), do: {:ok, empty_state()}

  defp empty_state do
    %{
      status: :stopped,
      port: nil,
      os_pid: nil,
      model: nil,
      url: nil,
      command: nil,
      output: [],
      error: nil,
      started_at: nil,
      server: nil,
      health: nil
    }
  end

  @doc "The PubSub topic the server's status is broadcast on (LOCAL-26)."
  def topic, do: @topic

  @doc "Subscribes the calling process to `{:llama_server, status}` (LOCAL-26)."
  def subscribe, do: Phoenix.PubSub.subscribe(Elia.PubSub, @topic)

  @doc "How the server is doing (LOCAL-16)."
  @spec status() :: map()
  def status, do: GenServer.call(@name, :status, 30_000)

  @doc """
  Starts the server with the effective settings (LOCAL-25), `overrides` merged
  over them. Returns as soon as it is started: the status is `:starting` until
  `GET /health` answers, which happens in the background (LOCAL-17).
  """
  @spec start_server(keyword()) :: {:ok, map()} | {:error, binary()}
  def start_server(overrides \\ []), do: GenServer.call(@name, {:start, overrides}, 30_000)

  @doc "Stops the server and its whole tree (LOCAL-18)."
  @spec stop_server() :: {:ok, map()}
  def stop_server, do: GenServer.call(@name, :stop, 30_000)

  ## Settings

  @doc """
  The settings a start would use (LOCAL-14): the stored ones (LOCAL-28) over
  the configuration, with `overrides` on top. A field left blank is not stored
  as blank — the configuration applies again.
  """
  @spec settings(keyword() | map()) :: keyword()
  def settings(overrides \\ []) do
    @defaults
    |> Keyword.merge(Application.get_env(:elia, __MODULE__, []))
    |> put_resolved()
    |> merge_stored()
    |> Keyword.merge(Keyword.new(overrides))
    |> normalize()
  end

  @doc "LOCAL-20: the `llama-server` a start would run, or `nil`."
  @spec binary() :: binary() | nil
  def binary, do: settings()[:binary]

  @doc "LOCAL-20: whether a `llama-server` was found on this machine."
  @spec available?() :: boolean()
  def available?, do: binary() != nil

  @doc "LOCAL-20: what to do where no `llama-server` was found."
  @spec unavailable_message() :: binary()
  def unavailable_message do
    "No llama-server was found. Set the binary in Settings → Local model server to " <>
      "the llama-server of your llama.cpp build (usually `build/bin/llama-server`), " <>
      "or put it on PATH. Building one: `cmake -B build && cmake --build build -j`."
  end

  @doc "LOCAL-21: the `.gguf` files in `models_dir`, as paths (none if unset)."
  @spec models() :: [binary()]
  def models do
    case settings()[:models_dir] do
      dir when is_binary(dir) ->
        case File.ls(dir) do
          {:ok, names} ->
            names
            |> Enum.filter(&String.ends_with?(&1, ".gguf"))
            |> Enum.map(&Path.join(dir, &1))
            |> Enum.sort()

          _ ->
            []
        end

      _ ->
        []
    end
  end

  @doc """
  Stores the fields of the settings section (LOCAL-28). A field that is blank
  or absent keeps the configured value.
  """
  @spec save(map() | keyword()) :: :ok | {:error, binary()}
  def save(attrs) do
    with :ok <- Settings.put(:local_server, clean(attrs)) do
      GenServer.call(@name, :settings_saved, 30_000)
      :ok
    end
  end

  @doc "Clears the stored settings, so the configuration applies again (LOCAL-28)."
  @spec reset() :: :ok | {:error, binary()}
  def reset do
    with :ok <- Settings.delete(:local_server) do
      GenServer.call(@name, :settings_saved, 30_000)
      :ok
    end
  end

  ## GenServer

  @impl true
  def handle_call(:status, _from, state) do
    state = refresh_external(state)
    {:reply, status_map(state), state}
  end

  # LOCAL-28: the fields changed, so what the page shows may have changed too —
  # including whether the server at that URL is Elia's or somebody else's.
  def handle_call(:settings_saved, _from, state) do
    state = refresh_external(%{state | url: nil})
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call({:start, overrides}, _from, state) do
    server = settings(overrides)

    result =
      if state.port do
        {:error, already_running_message(state)}
      else
        with :ok <- check_startable(server, state), do: {:ok, spawn_server(state, server)}
      end

    case result do
      {:ok, state} -> {:reply, {:ok, status_map(state)}, state}
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call(:stop, _from, state) do
    state = stop_process(state)
    {:reply, {:ok, status_map(state)}, state}
  end

  # LOCAL-17: the readiness poll, and the output the server writes while it starts.
  @impl true
  def handle_info(:poll, %{status: :starting} = state) do
    cond do
      check_health(state.url) ->
        {:noreply, ready(state)}

      timed_out?(state) ->
        {:noreply, fail(state, startup_timeout_message(state))}

      true ->
        Process.send_after(self(), :poll, @poll_interval)
        {:noreply, state}
    end
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, %{state | output: append_output(state.output, data, log_lines(state))}}
  end

  # LOCAL-16, LOCAL-18: the process is gone. Before it was ready that is a
  # failure, with what it printed as the reason; while running, its exit is
  # reported the same way rather than silently looking stopped.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | port: nil, os_pid: nil, health: nil}

    state =
      case state.status do
        :stopping ->
          %{state | status: :stopped, error: nil}

        _ ->
          fail(state, exit_message(state, status))
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # LOCAL-19: the app owns the process, so it goes down with it.
  @impl true
  def terminate(_reason, state) do
    if state.port, do: Elia.Shell.kill(state.port)
    :ok
  end

  ## Starting

  defp check_startable(server, state) do
    url = url(server)

    cond do
      server[:binary] == nil ->
        {:error, unavailable_message()}

      server[:model] in [nil, ""] ->
        {:error, "Choose a .gguf model to load."}

      not File.regular?(server[:model]) ->
        {:error, "There is no readable .gguf at #{server[:model]}."}

      not valid_port?(server[:port]) ->
        {:error, "#{server[:port]} is not a port number: choose one between 1 and 65535."}

      # LOCAL-11, LOCAL-16: somebody else's server on this port already.
      check_health(url) or external?(state) ->
        {:error,
         "A llama.cpp server already answers at #{url}. " <>
           "Stop it, or another port."}

      # LOCAL-23: a listener that isn't a llama-server is refused too.
      port_taken?(server) ->
        {:error, "Something else is already listening on port #{server[:port]}."}

      true ->
        :ok
    end
  end

  defp spawn_server(state, server) do
    {exe, args} = Elia.Priority.spawn_argv(server[:binary], argv(server))

    # LOCAL-12: not jailed — it reads a .gguf outside the workspace.
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    state = %{
      state
      | status: :starting,
        port: port,
        os_pid: os_pid,
        model: server[:model],
        url: url(server),
        command: Enum.join([server[:binary] | argv(server)], " "),
        output: [],
        error: nil,
        started_at: System.monotonic_time(:millisecond),
        server: server,
        health: nil
    }

    Logger.info("llama-server: starting #{state.command}")
    Process.send_after(self(), :poll, @poll_interval)
    broadcast(state)
    state
  end

  # LOCAL-13: what a llama-server is started with.
  defp argv(server) do
    ["-m", server[:model], "--host", server[:host], "--port", to_string(server[:port])] ++
      flag("-c", server[:context]) ++
      flag("-t", server[:threads]) ++
      if(server[:jinja], do: ["--jinja"], else: []) ++
      flag("--api-key", server[:api_key]) ++
      server[:extra_args]
  end

  defp flag(_name, value) when value in [nil, ""], do: []
  defp flag(name, value), do: [name, to_string(value)]

  ## Stopping

  # LOCAL-18: the whole tree, the way a timed-out command is killed (SHELL-3),
  # and a process that has already exited is reported as stopped. An outside
  # server is left alone (LOCAL-16).
  defp stop_process(%{port: nil} = state) do
    state = %{state | status: :stopped, error: nil, url: nil}
    broadcast(state)
    state
  end

  defp stop_process(%{port: port} = state) do
    state = %{state | status: :stopping}
    broadcast(state)

    Elia.Shell.kill(port)

    state = %{state | port: nil, os_pid: nil, status: :stopped, error: nil, health: nil}
    broadcast(state)
    state
  end

  ## Status

  # LOCAL-16: :external is an answer from a server Elia didn't start, so a
  # stopped Elia still shows the server that is up, and stopping leaves it be.
  defp refresh_external(%{port: nil} = state) do
    url = state.url || url(settings())

    cond do
      health_up?(url, state) -> %{state | status: :external, url: url}
      state.status == :external -> %{state | status: :stopped}
      true -> state
    end
  end

  defp refresh_external(state), do: state

  defp status_map(state) do
    settings = state.server || settings()

    %{
      status: state.status,
      url: state.url || url(settings),
      model: state.model || settings[:model],
      os_pid: state.os_pid,
      command: state.command || command_for(settings),
      output: state.output,
      error: state.error,
      binary: settings[:binary],
      available: settings[:binary] != nil,
      log_lines: settings[:log_lines]
    }
  end

  defp command_for(settings) do
    case settings[:binary] do
      nil -> nil
      binary -> Enum.join([binary | argv(settings)], " ")
    end
  end

  defp ready(state) do
    state = %{state | status: :running, error: nil, health: nil}
    Logger.info("llama-server: ready at #{state.url}")

    # LOCAL-22: the model it loaded is now in the picker without a wait.
    clear_catalog()
    broadcast(state)
    state
  end

  defp fail(state, message) do
    if state.port, do: Elia.Shell.kill(state.port)

    state = %{state | status: :failed, error: message, port: nil, os_pid: nil, health: nil}
    Logger.warning("llama-server: #{message}")
    broadcast(state)
    state
  end

  defp clear_catalog do
    Elia.LLM.Catalog.clear("llamacpp")
  catch
    :exit, _reason -> :ok
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Elia.PubSub, @topic, {:llama_server, status_map(state)})
  end

  defp append_output(output, data, limit) do
    (output ++ String.split(data, "\n"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-limit)
  end

  defp exit_message(state, status) do
    what =
      if state.status == :starting,
        do: "llama-server exited with status #{status} before it was ready",
        else: "llama-server exited with status #{status}"

    case List.last(state.output) do
      nil -> what
      line -> what <> ": " <> line
    end
  end

  defp startup_timeout_message(state) do
    seconds = div(settings()[:startup_timeout] || 60_000, 1000)

    "llama-server did not answer GET /health at #{state.url} within #{seconds}s" <>
      case List.last(state.output) do
        nil -> ""
        line -> ": " <> line
      end
  end

  defp already_running_message(state) do
    "A llama-server is already running (pid #{state.os_pid}, #{state.url}) — stop it first."
  end

  defp timed_out?(state) do
    limit = settings()[:startup_timeout] || 60_000
    System.monotonic_time(:millisecond) - (state.started_at || 0) > limit
  end

  defp log_lines(state), do: (state.server || settings())[:log_lines] || 200

  defp valid_port?(port), do: is_integer(port) and port in 1..65_535

  defp external?(state), do: state.status == :external

  defp url(server) do
    "http://" <> connect_host(server[:host]) <> ":" <> to_string(server[:port])
  end

  # A server bound to every interface is reached on the loopback address.
  defp connect_host(host) when host in ["0.0.0.0", "::", ""], do: "127.0.0.1"
  defp connect_host(nil), do: "127.0.0.1"
  defp connect_host(host), do: host

  # LOCAL-17: the readiness check, kept short so a server that isn't there does
  # not hold up a status call. A port that is not a port number is not asked at
  # all (LOCAL-23) rather than raising in the socket layer.
  defp check_health(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{port: port}} when is_integer(port) ->
        if valid_port?(port), do: ask_health(url), else: false

      _ ->
        false
    end
  end

  defp check_health(_url), do: false

  defp ask_health(url) do
    case Req.get(
           url: url <> "/health",
           retry: false,
           receive_timeout: 1_000,
           connect_options: [timeout: 500]
         ) do
      {:ok, %Req.Response{status: 200}} -> true
      _ -> false
    end
  end

  # LOCAL-16: the health check that decides whether something else is serving
  # this port. It is short — a closed port refuses at once — so a status call
  # stays quick, and an outside server is asked again on each one.
  defp health_up?(url, _state), do: check_health(url)

  defp port_taken?(server) do
    if valid_port?(server[:port]) do
      case :gen_tcp.connect({127, 0, 0, 1}, server[:port], [:binary, active: false], 300) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        _ ->
          false
      end
    else
      false
    end
  end

  ## Settings plumbing

  # LOCAL-14: the binary is looked up the way the terminal looks for tmux, so a
  # host without one says so in terms of the fix (LOCAL-20).
  defp put_resolved(settings) do
    settings
    |> Keyword.put(:binary, find_binary(settings[:binary] || System.get_env("LLAMA_SERVER_BIN")))
    |> Keyword.put(:models_dir, settings[:models_dir] || System.get_env("LLAMA_MODELS_DIR"))
    |> Keyword.put(:api_key, settings[:api_key] || provider_key())
  end

  # LOCAL-2: the key the server requires and the key the provider sends are the
  # same one, so starting a server with --api-key keeps working.
  defp provider_key do
    case Elia.LLM.api_key("llamacpp") do
      {_source, key} -> key
      nil -> nil
    end
  end

  defp find_binary(name) when is_binary(name) and name != "" do
    case System.find_executable(name) do
      nil -> if File.regular?(name), do: name, else: nil
      exe -> exe
    end
  end

  defp find_binary(_name), do: System.find_executable("llama-server")

  defp merge_stored(settings) do
    Enum.reduce(stored(), settings, fn {key, value}, acc ->
      if value in [nil, "", []], do: acc, else: Keyword.put(acc, key, value)
    end)
  end

  defp stored do
    case Settings.get(:local_server) do
      %{} = stored -> Map.to_list(stored)
      _ -> []
    end
  end

  defp normalize(settings) do
    settings
    |> Keyword.put(:port, to_int(settings[:port], 8080))
    |> Keyword.put(:context, to_int(settings[:context], nil))
    |> Keyword.put(:threads, to_int(settings[:threads], nil))
    |> Keyword.put(:log_lines, to_int(settings[:log_lines], 200))
    |> Keyword.put(:startup_timeout, to_int(settings[:startup_timeout], 60_000))
    |> Keyword.put(:extra_args, to_args(settings[:extra_args]))
    |> Keyword.put(:jinja, settings[:jinja] != false)
    |> Keyword.put(:binary, find_binary(settings[:binary] || System.get_env("LLAMA_SERVER_BIN")))
  end

  defp clean(attrs) do
    attrs = Map.new(attrs)

    Map.new(@fields, fn key -> {key, clean_value(key, Map.get(attrs, key))} end)
  end

  defp clean_value(:jinja, nil), do: nil
  defp clean_value(:jinja, value), do: value in [true, "true", "on", "1", 1]
  defp clean_value(:extra_args, value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp clean_value(:extra_args, value), do: to_args(value)
  defp clean_value(key, value) when key in [:port, :context, :threads], do: to_int(value, nil)
  defp clean_value(_key, value), do: trim(value)

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp to_int(_value, default), do: default

  defp to_args(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp to_args(value) when is_binary(value), do: OptionParser.split(value)
  defp to_args(_value), do: []

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(value), do: value
end
