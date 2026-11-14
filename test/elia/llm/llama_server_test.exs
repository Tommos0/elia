defmodule Elia.LLM.LlamaServerTest do
  use ExUnit.Case, async: false

  import Elia.LLMCase

  alias Elia.LLM.{Catalog, LlamaCpp, LlamaServer, LlamaServerStub}

  setup do
    reset_settings()

    # A port nothing else is on: the external-server check asks the configured
    # port, and this host's own llama-server may be sitting on the default 8080
    # (LOCAL-16).
    configure(LlamaServer,
      binary: LlamaServerStub.install!(),
      startup_timeout: 15_000,
      port: LlamaServerStub.free_port()
    )

    configure(LlamaCpp)
    # A fresh state for each test: the server is the application's one, and a
    # previous test's failure would otherwise still be showing.
    LlamaServer.stop_server()
    on_exit(fn -> stop_server() end)
    :ok
  end

  defp stop_server do
    case LlamaServer.status().status do
      # :failed too (LOCAL-17): a start that failed leaves the status saying so
      # until something changes it, and the server is the application's one —
      # one process shared by every test in the run, not this file's. Left
      # behind, a failure from a test here is what the next page to ask sees.
      status when status in [:starting, :running, :failed] -> LlamaServer.stop_server()
      _status -> :ok
    end
  end

  # A server, a model file and a port, as the section would have them.
  defp server_opts(opts) do
    port = Keyword.get(opts, :port, LlamaServerStub.free_port())
    model = Keyword.get_lazy(opts, :model, &model_file/0)
    extra = Keyword.get(opts, :extra_args, [])

    [model: model, host: "127.0.0.1", port: port, extra_args: extra] ++
      Keyword.drop(opts, [:port, :model, :extra_args])
  end

  defp model_file do
    path = Path.join(System.tmp_dir!(), "elia-llama-stub-model.gguf")
    unless File.exists?(path), do: File.write!(path, "not really a model")
    path
  end

  defp start!(opts \\ []) do
    :ok = LlamaServer.save(Map.new(server_opts(opts)))
    LlamaServer.start_server()
  end

  # LOCAL-11: the status a start reports, once the stub has booted. The stub is
  # a real process and the wait is for its health check to answer, so the
  # deadline leaves room for a machine running the suite in partitions: three
  # seconds was enough on an idle one and not on a loaded one.
  defp await_status(status, timeout \\ 10_000) do
    LlamaServer.subscribe()
    assert_receive {:llama_server, %{status: ^status}}, timeout
  end

  # LOCAL-11, LOCAL-13, LOCAL-17
  test "starts a llama-server with the settings, and becomes running" do
    port = LlamaServerStub.free_port()

    {:ok, started} =
      start!(
        port: port,
        context: 4096,
        threads: 4,
        extra_args: "--stub healthy"
      )

    assert started.status == :starting
    assert started.url == "http://127.0.0.1:#{port}"

    # LOCAL-13: the flags a llama-server is started with.
    assert started.command =~ "-m #{started.model}"
    assert started.command =~ "--host 127.0.0.1 --port #{port}"
    assert started.command =~ "-c 4096 -t 4 --jinja"
    assert started.command =~ "--stub healthy"

    await_status(:running)

    status = LlamaServer.status()
    assert status.status == :running
    assert status.os_pid
    assert status.error == nil
    assert Enum.any?(status.output, &String.contains?(&1, "stub: listening on #{port}"))
    assert Enum.any?(status.output, &String.contains?(&1, "--port #{port}"))

    # LOCAL-18: it is really listening, and stopping frees the port.
    assert LlamaServerStub.listening?(port)
    assert {:ok, stopped} = LlamaServer.stop_server()
    assert stopped.status == :stopped
    assert LlamaServerStub.wait_until(fn -> not LlamaServerStub.listening?(port) end)
    assert LlamaServer.status().status == :stopped
  end

  # LOCAL-13: --api-key only when a key is set (LOCAL-2), --jinja only when on.
  test "sends --api-key only when a key is set, and --jinja only when asked" do
    configure(LlamaCpp, api_key: "local-secret", req_options: [])

    {:ok, started} = start!(jinja: false)
    assert started.command =~ "--api-key local-secret"
    refute started.command =~ "--jinja"
    await_status(:running)

    configure(LlamaCpp, api_key: nil)
    LlamaServer.stop_server()
    {:ok, started} = start!(jinja: true)
    refute started.command =~ "--api-key"
    assert started.command =~ "--jinja"
    await_status(:running)
  end

  # LOCAL-11, LOCAL-16: one at a time — a second start is refused.
  test "refuses to start while one is running" do
    {:ok, started} = start!()
    await_status(:running)

    assert {:error, message} = LlamaServer.start_server()
    assert message =~ "already running"
    assert message =~ "pid #{started.os_pid}"
  end

  # LOCAL-15, LOCAL-20: nothing is spawned without a binary, a model or a
  # readable model file, and the message says what to do.
  test "refuses without a binary, and says how to get one" do
    configure(LlamaServer, binary: "/nowhere/llama-server")
    :ok = LlamaServer.save(%{model: model_file(), port: LlamaServerStub.free_port()})

    assert {:error, message} = LlamaServer.start_server()
    assert message =~ "No llama-server was found"
    assert message =~ "Settings"
    assert message =~ "cmake"
    assert LlamaServer.status().status == :stopped
  end

  test "refuses without a model, and with a model file that is not there" do
    :ok = LlamaServer.save(%{model: nil, port: LlamaServerStub.free_port()})
    assert {:error, message} = LlamaServer.start_server()
    assert message =~ "Choose a .gguf model"

    :ok = LlamaServer.save(%{model: "/nowhere/model.gguf"})
    assert {:error, message} = LlamaServer.start_server()
    assert message =~ "no readable .gguf"
    assert LlamaServer.status().status == :stopped
  end

  # LOCAL-23: a port that is not a port number, and one something else holds.
  test "refuses an invalid port and a port that is taken" do
    :ok = LlamaServer.save(Map.new(server_opts(port: 70_000)))
    assert {:error, message} = LlamaServer.start_server()
    assert message =~ "not a port number"

    port = LlamaServerStub.free_port()
    {:ok, listen} = :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listen) end)

    :ok = LlamaServer.save(Map.new(server_opts(port: port)))
    assert {:error, message} = LlamaServer.start_server()
    assert message =~ "Something else is already listening on port #{port}"
    assert LlamaServer.status().status == :stopped
  end

  # LOCAL-16: a llama.cpp server Elia did not start is reported, not taken over.
  test "reports a server that was started outside Elia" do
    # A real socket this time, not a stub: nothing may intercept the health check.
    configure(LlamaCpp, req_options: [])

    port = LlamaServerStub.free_port()
    stub = LlamaServerStub.install!()

    port_ref =
      Port.open({:spawn_executable, stub}, [
        :binary,
        :exit_status,
        :hide,
        args: ["--port", to_string(port), "--stub", "healthy"]
      ])

    on_exit(fn -> Elia.Shell.kill(port_ref) end)

    assert LlamaServerStub.wait_until(fn ->
             LlamaCpp.check_base_url("http://127.0.0.1:#{port}") == :ok
           end)

    :ok = LlamaServer.save(Map.new(server_opts(port: port)))
    status = LlamaServer.status()
    assert status.status == :external
    assert status.url == "http://127.0.0.1:#{port}"

    # LOCAL-11: starting on its port is refused (something already answers).
    assert {:error, message} = LlamaServer.start_server()
    assert message =~ "already answers at http://127.0.0.1:#{port}"

    # LOCAL-18: stopping leaves it alone.
    assert {:ok, _status} = LlamaServer.stop_server()
    assert LlamaServerStub.listening?(port)
  end

  # LOCAL-17: a process that exits before it is ready is a failure, with what
  # it printed as the reason.
  test "reports a server that exits before it is ready" do
    {:ok, started} = start!(extra_args: "--stub exit")
    assert started.status == :starting

    await_status(:failed)

    status = LlamaServer.status()
    assert status.status == :failed
    assert status.error =~ "exited with status 3"
    assert status.error =~ "stub: cannot load that model"
    assert Enum.any?(status.output, &String.contains?(&1, "stub: cannot load that model"))
  end

  # LOCAL-17: a server that never answers /health times out (LOCAL-16, LOCAL-27
  # show the output).
  test "reports a server that never answers health" do
    configure(LlamaServer,
      binary: LlamaServerStub.install!(),
      startup_timeout: 1_000
    )

    {:ok, started} = start!(extra_args: "--stub silent")
    assert started.status == :starting

    await_status(:failed, 10_000)

    status = LlamaServer.status()
    assert status.error =~ "did not answer GET /health"
    assert status.error =~ "within 1s"
  end

  # LOCAL-14, LOCAL-28: a saved field wins over the configuration; a blank one
  # leaves the configured value in place; Reset clears them all.
  test "saved settings win over the configuration, and Reset clears them" do
    configure(LlamaServer, host: "127.0.0.1", port: 8080, model: "/configured/model.gguf")

    assert LlamaServer.settings()[:model] == "/configured/model.gguf"

    :ok = LlamaServer.save(%{model: "/saved/model.gguf", port: "9999", context: "2048"})
    settings = LlamaServer.settings()
    assert settings[:model] == "/saved/model.gguf"
    assert settings[:port] == 9999
    assert settings[:context] == 2048

    # A field left blank is not stored as blank: the configuration applies again.
    :ok = LlamaServer.save(%{model: "", port: "9999"})
    assert LlamaServer.settings()[:model] == "/configured/model.gguf"
    assert LlamaServer.settings()[:port] == 9999

    :ok = LlamaServer.reset()
    assert LlamaServer.settings()[:port] == 8080
    assert LlamaServer.settings()[:model] == "/configured/model.gguf"
  end

  # LOCAL-21
  test "offers the .gguf files in the models directory" do
    dir = Path.join(System.tmp_dir!(), "elia-llama-models")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "b.gguf"), "x")
    File.write!(Path.join(dir, "a.gguf"), "x")
    File.write!(Path.join(dir, "notes.txt"), "x")

    :ok = LlamaServer.save(%{models_dir: dir})
    assert LlamaServer.models() == [Path.join(dir, "a.gguf"), Path.join(dir, "b.gguf")]

    :ok = LlamaServer.save(%{models_dir: "/nowhere"})
    assert LlamaServer.models() == []
  end

  # LOCAL-22: the model it loaded is in the picker without a wait.
  test "a successful start clears the provider's cached models" do
    Req.Test.stub(LlamaCpp, fn conn -> Req.Test.json(conn, %{"data" => [%{"id" => "old"}]}) end)
    assert {:ok, [%{id: "old"}]} = Elia.LLM.models("llamacpp")
    assert {:ok, [%{id: "old"}]} = Catalog.peek("llamacpp")

    {:ok, _started} = start!()
    await_status(:running)

    assert Catalog.peek("llamacpp") == :miss
  end

  # LOCAL-19: the app owns it, so it goes down with the app.
  test "is supervised by the application" do
    assert LlamaServer in Elia.Application.children()
    assert Process.whereis(LlamaServer)

    status = LlamaServer.status()
    assert status.status in [:stopped, :external]
  end

  # LOCAL-24: the health check a base URL is tried with, and the URL a keyless
  # provider talks to (LOCAL-3).
  test "checks a base URL without saving it" do
    configure(LlamaCpp, req_options: [])

    assert {:error, "Enter a base URL"} = Elia.LLM.check_base_url("llamacpp", "")
    assert {:error, "Enter a base URL"} = Elia.LLM.check_base_url("llamacpp", nil)
    assert {:error, "Unknown provider"} = Elia.LLM.check_base_url("nope", "http://127.0.0.1:1")

    port = LlamaServerStub.free_port()
    assert {:error, message} = LlamaCpp.check_base_url("http://127.0.0.1:#{port}")
    assert message == "No llama.cpp server at http://127.0.0.1:#{port}: start one in Settings"

    assert {:error, message} = Elia.LLM.save_base_url("llamacpp", "http://127.0.0.1:#{port}")
    assert message == "No llama.cpp server at http://127.0.0.1:#{port}: start one in Settings"
    assert LlamaCpp.base_url() == "http://127.0.0.1:8080"
  end
end
