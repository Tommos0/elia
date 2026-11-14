defmodule Elia.LLM.LlamaServerStub do
  @moduledoc """
  A stand-in `llama-server` for tests of `Elia.LLM.LlamaServer` (LOCAL-11 to
  LOCAL-23), so no real model is loaded.

  `install!/0` writes an Elixir script to a temporary directory and returns its
  path — a path a start can be pointed at with `binary:`. It takes the real
  `llama-server` arguments, prints what it was given (so a test can see the
  command line the process received) and then behaves as `--stub <mode>` says:

    * `healthy` (the default) — really listens on `--port` and answers
      `GET /health`, `/v1/models` and `/props`, so a start becomes `:running`
    * `slow` — waits two seconds first, so `:starting` can be observed
    * `exit` — prints a line and exits with status 3, before it is ready
    * `silent` — prints a line and never listens, so the startup poll times out

  Modes other than `healthy` are passed through `extra_args`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @script """
  #!/usr/bin/env elixir
  defmodule EliaLlamaServerStub do
    def main(args) do
      IO.puts("stub: argv " <> Enum.join(args, " "))

      case mode(args) do
        "exit" ->
          IO.puts("stub: cannot load that model")
          System.halt(3)

        "silent" ->
          IO.puts("stub: pretending to work")
          Process.sleep(:infinity)

        mode ->
          IO.puts("stub: mode " <> mode)
          if mode == "slow", do: Process.sleep(2_000)
          serve(port(args))
      end
    end

    defp mode(args) do
      case Enum.find_index(args, &(&1 == "--stub")) do
        nil -> "healthy"
        index -> Enum.at(args, index + 1)
      end
    end

    defp port(args) do
      case Enum.find_index(args, &(&1 == "--port")) do
        nil -> 8080
        index -> args |> Enum.at(index + 1) |> String.to_integer()
      end
    end

    defp serve(port) do
      {:ok, listen} =
        :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      IO.puts("stub: listening on " <> Integer.to_string(port))
      accept(listen)
    end

    defp accept(listen) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          answer(socket)
          accept(listen)

        _ ->
          :ok
      end
    end

    defp answer(socket) do
      request =
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> data
          _ -> ""
        end

      {status, body} = response(request)

      :gen_tcp.send(
        socket,
        "HTTP/1.1 " <> status <> "\\r\\ncontent-type: application/json\\r\\n" <>
          "content-length: " <> Integer.to_string(byte_size(body)) <> "\\r\\nconnection: close\\r\\n\\r\\n" <>
          body
      )

      :gen_tcp.close(socket)
    end

    defp response(request) do
      cond do
        String.contains?(request, "/health") ->
          {"200 OK", ~s({"status":"ok"})}

        String.contains?(request, "/v1/models") ->
          {"200 OK", ~s({"object":"list","data":[{"id":"stub-model","object":"model"}]})}

        String.contains?(request, "/props") ->
          {"200 OK",
           ~s({"model_path":"/models/stub.gguf","default_generation_settings":{"n_ctx":4096}})}

        true ->
          {"404 Not Found", ~s({"error":"no such route"})}
      end
    end
  end

  EliaLlamaServerStub.main(System.argv())
  """

  @doc "Writes the stub and returns the path to point a start at."
  @spec install!() :: binary()
  def install! do
    dir = Path.join(System.tmp_dir!(), "elia-llama-stub")
    path = Path.join(dir, "llama-server")

    File.mkdir_p!(dir)
    File.write!(path, @script)
    File.chmod!(path, 0o755)

    path
  end

  @doc """
  Starts the stub on `port` (a free one when none is given) as a port, as a
  `llama-server` started outside Elia is, and registers an `on_exit` that kills
  it. Returns `{port, os_pid}`.

  Kill a stub started this way with `stop!/1`, never with
  `Elia.Shell.kill(port_ref)`: a port is closed when the process that opened it
  ends, and closing a port does not kill the program it started. A kill from
  `on_exit` therefore finds no port, does nothing, and leaves the stub running —
  where it holds a piped run's pipe open, so `mix test | tail` waits for an EOF
  that never comes.
  """
  @spec start!(non_neg_integer() | nil, [binary()]) :: {non_neg_integer(), non_neg_integer()}
  def start!(port \\ nil, args \\ ["--stub", "healthy"]) do
    port = port || free_port()

    port_ref =
      Port.open({:spawn_executable, install!()}, [
        :binary,
        :exit_status,
        :hide,
        args: ["--port", to_string(port) | args]
      ])

    {:os_pid, os_pid} = Port.info(port_ref, :os_pid)
    on_exit(fn -> stop!(os_pid) end)

    true = wait_until(fn -> listening?(port) end, 10_000)
    {port, os_pid}
  end

  @doc """
  Kills a stub `start!/2` started, by pid: by the time an `on_exit` callback
  runs the port it was started on is closed and cannot be asked for one.
  """
  @spec stop!(non_neg_integer()) :: :ok
  def stop!(os_pid) do
    # The kill `Elia.Shell.kill/1` gives a live port (SHELL-3): the group first,
    # then the pid itself, in case the group is already gone.
    System.cmd("kill", ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
    System.cmd("kill", ["-KILL", "#{os_pid}"], stderr_to_stdout: true)
    :ok
  end

  @doc "A port nothing is listening on, for a server to be started on."
  @spec free_port() :: non_neg_integer()
  def free_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end

  @doc "Whether something is listening on `port` (LOCAL-18: it is free after a stop)."
  @spec listening?(non_neg_integer()) :: boolean()
  def listening?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 300) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  @doc "Waits until `fun` is true, up to `timeout` — for a stub that has to boot."
  @spec wait_until((-> boolean()), timeout()) :: boolean()
  def wait_until(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(50)
        do_wait_until(fun, deadline)
    end
  end
end
