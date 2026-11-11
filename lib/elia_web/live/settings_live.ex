defmodule EliaWeb.SettingsLive do
  use EliaWeb, :live_view

  alias Elia.{Deploy, LLM, Push}
  alias Elia.LLM.LlamaServer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # CONF-20, DEPLOY-16: subscribe before the deploy state is read below, so
      # a deploy that starts or ends between the two can't slip past: the read
      # sees it, or the broadcast that follows does.
      Deploy.Runner.subscribe()
      # LOCAL-26: the local server's status is broadcast, so every start, ready,
      # failure and stop reaches this page without polling.
      LlamaServer.subscribe()
    end

    providers = LLM.providers()
    # CONF-20, DEPLOY-16: the deploy in flight and the last one's result live in
    # the runner, not in this page, so a page that mounts while a deploy runs or
    # after one finished shows both.
    deploy = Deploy.Runner.state()

    socket =
      socket
      |> assign(
        page_title: "Settings",
        providers: providers,
        settings_path: Elia.Settings.path(),
        # key => {:ok | :error, message}
        results: %{},
        # key => :check | :save | :check_current while a request is in flight
        pending: %{},
        # key => :loading | {:ok, balance} | {:error, message}
        balances: %{},
        # CONF-19: the deploy state (DEPLOY-14, DEPLOY-17), and "reload" |
        # "restart" while a deploy runs
        deployment: Deploy.status(),
        deploying: deploy.running && to_string(deploy.running.mode),
        # CONF-20: the last deploy's result, still shown for a page that arrives
        # after it ended
        deploy_result: deploy.last && deploy_result(deploy.last.result)
      )
      # PUSH-2: the key the section's hook subscribes with; PUSH-7: how many
      # devices are subscribed; PUSH-8: how the last test notification went;
      # PUSH-22: whether this page has reached the server yet, which only the
      # server can say and which decides what the section says before its own
      # script has run.
      |> assign(
        push_key: Push.public_key(),
        push_count: Push.Subscriptions.count(),
        push_status: nil,
        push_connected: connected?(socket)
      )
      |> assign(forms: Map.new(providers, &{&1.key, empty_form(&1.key)}))
      # LOCAL-24: the base URL a keyless provider talks to, and whether it is a
      # saved one; the local server's own section (LOCAL-25 to LOCAL-28).
      |> assign(
        base_urls: Map.new(providers, &{&1.key, LLM.base_url(&1.key)}),
        stored_base_urls: Map.new(providers, &{&1.key, stored_base_url?(&1.key)}),
        base_forms: Map.new(providers, &{&1.key, base_url_form(&1.key)})
      )
      |> assign_server()
      |> refresh_keys()

    if connected?(socket) do
      {:ok, load_balances(socket)}
    else
      {:ok, socket}
    end
  end

  defp load_balances(socket) do
    Enum.reduce(socket.assigns.providers, socket, &load_balance(&2, &1.key))
  end

  # Starts a background balance lookup when the provider has a key and
  # reports credits, unless one is already running.
  defp load_balance(socket, key) do
    if socket.assigns.keys[key] && LLM.balance_supported?(key) &&
         socket.assigns.balances[key] != :loading do
      socket
      |> assign(balances: Map.put(socket.assigns.balances, key, :loading))
      |> start_async({:balance, key}, fn -> LLM.balance(key) end)
    else
      socket
    end
  end

  defp empty_form(key), do: to_form(%{"api_key" => ""}, as: key)

  defp refresh_keys(socket) do
    assign(socket, keys: Map.new(socket.assigns.providers, &{&1.key, LLM.api_key(&1.key)}))
  end

  # LOCAL-24: a keyless provider's card holds a base URL instead of a key.
  defp base_url_form(key, url \\ nil) do
    to_form(%{"base_url" => url || LLM.base_url(key) || ""}, as: key)
  end

  defp stored_base_url?(key), do: is_binary(Elia.Settings.get({:base_url, key}))

  defp refresh_base_urls(socket) do
    providers = socket.assigns.providers

    assign(socket,
      base_urls: Map.new(providers, &{&1.key, LLM.base_url(&1.key)}),
      stored_base_urls: Map.new(providers, &{&1.key, stored_base_url?(&1.key)}),
      base_forms: Map.new(providers, &{&1.key, base_url_form(&1.key)})
    )
  end

  # LOCAL-25 to LOCAL-28: the local model server's section.
  defp assign_server(socket) do
    assign(socket,
      server: LlamaServer.status(),
      server_settings: LlamaServer.settings(),
      server_form: server_form(),
      server_models: LlamaServer.models(),
      server_result: nil
    )
  end

  defp refresh_server(socket) do
    assign(socket,
      server: LlamaServer.status(),
      server_settings: LlamaServer.settings(),
      server_form: server_form(),
      server_models: LlamaServer.models()
    )
  end

  defp server_form(overrides \\ %{}) do
    settings = LlamaServer.settings()

    %{
      "binary" => settings[:binary] || "",
      "models_dir" => settings[:models_dir] || "",
      "model" => settings[:model] || "",
      "host" => settings[:host] || "",
      "port" => text(settings[:port]),
      "context" => text(settings[:context]),
      "threads" => text(settings[:threads]),
      "extra_args" => Enum.join(settings[:extra_args] || [], " "),
      "jinja" => settings[:jinja] == true
    }
    |> Map.merge(overrides)
    |> to_form(as: :server)
  end

  defp text(nil), do: ""
  defp text(value), do: to_string(value)

  defp server_attrs(params) do
    %{
      binary: params["binary"],
      models_dir: params["models_dir"],
      model: params["model"],
      host: params["host"],
      port: params["port"],
      context: params["context"],
      threads: params["threads"],
      extra_args: params["extra_args"],
      jinja: params["jinja"]
    }
  end

  defp put_server_result(socket, result), do: assign(socket, server_result: result)

  # LOCAL-17: a start returns at once with the status `:starting`; what happens
  # next arrives over the subscription (LOCAL-26).
  defp start_local_server(socket) do
    case LlamaServer.start_server() do
      {:ok, _status} ->
        socket
        |> refresh_server()
        |> put_server_result({:ok, "Starting the server…"})

      {:error, message} ->
        socket
        |> refresh_server()
        |> put_server_result({:error, message})
    end
  end

  defp run_base_url(socket, key, action, fun) do
    if Map.has_key?(socket.assigns.pending, key) or LLM.provider_info(key) == nil do
      socket
    else
      socket
      |> assign(pending: Map.put(socket.assigns.pending, key, action))
      |> assign(results: Map.delete(socket.assigns.results, key))
      |> start_async({:base_url, key, action}, fun)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl px-4 py-10 sm:px-6">
          <h1 class="text-2xl font-semibold tracking-tight">Settings</h1>
          <p class="mt-1 text-sm text-base-content/60">
            API keys for the model providers Elia can use. Pick a model from the chat composer.
          </p>

          <section
            id="appearance"
            class="mt-8 flex items-center justify-between gap-3 rounded-2xl border border-base-300 p-5"
          >
            <div>
              <h2 class="font-medium">Appearance</h2>
              <p class="text-xs text-base-content/50">Follow the system, or pick light or dark.</p>
            </div>
            <Layouts.theme_toggle />
          </section>

          <div class="mt-4 space-y-4">
            <section
              :for={info <- @providers}
              id={"provider-#{info.key}"}
              class="rounded-2xl border border-base-300 p-5 transition duration-200 hover:border-base-content/20 hover:shadow-sm"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="flex items-center gap-3">
                  <div class="grid size-10 place-items-center rounded-xl bg-base-200 text-base-content/70">
                    <.icon name={provider_icon(info.key)} class="size-5" />
                  </div>
                  <div>
                    <h2 class="font-medium">{info.name}</h2>
                    <p class="text-xs text-base-content/50">{provider_blurb(info.key)}</p>
                  </div>
                </div>
                <.key_status key={@keys[info.key]} provider={info.key} keyless={info.keyless} />
              </div>

              <div :if={info.keyless} class="mt-5">
                <.form
                  for={@base_forms[info.key]}
                  id={"base-url-form-#{info.key}"}
                  phx-submit="submit_base_url"
                  class="flex flex-col gap-2 sm:flex-row sm:items-start"
                >
                  <input type="hidden" name="provider" value={info.key} />
                  <div class="flex-1">
                    <.input
                      field={@base_forms[info.key][:base_url]}
                      type="text"
                      autocomplete="off"
                      placeholder="http://127.0.0.1:8080"
                      class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-sm outline-none transition placeholder:font-sans focus:border-primary focus:bg-base-100"
                    />
                  </div>
                  <div class="flex gap-2">
                    <button
                      type="submit"
                      name="action"
                      value="check"
                      id={"check-#{info.key}"}
                      disabled={@pending[info.key] != nil}
                      class="flex h-11 items-center gap-1.5 rounded-xl border border-base-300 px-4 text-sm font-medium transition hover:bg-base-200 disabled:opacity-50"
                    >
                      <.spinner :if={@pending[info.key] == :check} />
                      <.icon
                        :if={@pending[info.key] != :check}
                        name="hero-shield-check"
                        class="size-4"
                      /> Check
                    </button>
                    <button
                      type="submit"
                      name="action"
                      value="save"
                      id={"save-#{info.key}"}
                      disabled={@pending[info.key] != nil}
                      class="flex h-11 items-center gap-1.5 rounded-xl bg-primary px-4 text-sm font-medium text-primary-content transition hover:brightness-110 disabled:opacity-50"
                    >
                      <.spinner :if={@pending[info.key] == :save} /> Save
                    </button>
                  </div>
                </.form>
                <button
                  :if={@stored_base_urls[info.key]}
                  type="button"
                  id={"remove-url-#{info.key}"}
                  phx-click="remove_base_url"
                  phx-value-provider={info.key}
                  class="mt-2 flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium text-error transition hover:bg-error/10"
                >
                  <.icon name="hero-trash" class="size-3.5" /> Remove saved URL
                </button>
              </div>

              <.form
                :if={!info.keyless}
                for={@forms[info.key]}
                id={"key-form-#{info.key}"}
                phx-submit="submit"
                class="mt-5 flex flex-col gap-2 sm:flex-row sm:items-start"
              >
                <input type="hidden" name="provider" value={info.key} />
                <div class="flex-1">
                  <.input
                    field={@forms[info.key][:api_key]}
                    type="password"
                    autocomplete="off"
                    placeholder={key_placeholder(info.key)}
                    class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-sm outline-none transition placeholder:font-sans focus:border-primary focus:bg-base-100"
                  />
                </div>
                <div class="flex gap-2">
                  <button
                    type="submit"
                    name="action"
                    value="check"
                    id={"check-#{info.key}"}
                    disabled={@pending[info.key] != nil}
                    class="flex h-11 items-center gap-1.5 rounded-xl border border-base-300 px-4 text-sm font-medium transition hover:bg-base-200 disabled:opacity-50"
                  >
                    <.spinner :if={@pending[info.key] == :check} />
                    <.icon :if={@pending[info.key] != :check} name="hero-shield-check" class="size-4" />
                    Check
                  </button>
                  <button
                    type="submit"
                    name="action"
                    value="save"
                    id={"save-#{info.key}"}
                    disabled={@pending[info.key] != nil}
                    class="flex h-11 items-center gap-1.5 rounded-xl bg-primary px-4 text-sm font-medium text-primary-content transition hover:brightness-110 disabled:opacity-50"
                  >
                    <.spinner :if={@pending[info.key] == :save} /> Save
                  </button>
                </div>
              </.form>

              <div
                :if={result = @results[info.key]}
                id={"result-#{info.key}"}
                class={[
                  "mt-3 flex items-start gap-2 rounded-lg px-3 py-2 text-xs",
                  elem(result, 0) == :ok && "bg-success/10 text-success",
                  elem(result, 0) == :error && "bg-error/10 text-error"
                ]}
              >
                <.icon
                  name={
                    if elem(result, 0) == :ok,
                      do: "hero-check-circle",
                      else: "hero-exclamation-triangle"
                  }
                  class="mt-px size-4 shrink-0"
                />
                <span class="break-words">{elem(result, 1)}</span>
              </div>

              <div class="mt-4 flex flex-wrap items-center justify-between gap-2 border-t border-base-300 pt-4">
                <div class="flex items-center gap-2 text-xs text-base-content/70">
                  <.icon name="hero-banknotes" class="size-4 shrink-0" />
                  <span :if={info.keyless} id={"balance-#{info.key}"}>
                    Nothing to bill: it runs on this machine.
                  </span>
                  <.balance_line
                    :if={!info.keyless && @keys[info.key]}
                    provider={info.key}
                    supported={LLM.balance_supported?(info.key)}
                    balance={@balances[info.key]}
                  />
                  <span :if={!info.keyless && !@keys[info.key]} id={"balance-#{info.key}"}>
                    Add a key to see credits.
                  </span>
                  <button
                    :if={!info.keyless && @keys[info.key] && LLM.balance_supported?(info.key)}
                    type="button"
                    id={"refresh-balance-#{info.key}"}
                    phx-click="refresh_balance"
                    phx-value-provider={info.key}
                    disabled={@balances[info.key] == :loading}
                    class="rounded-md p-1 transition hover:bg-base-200 disabled:opacity-50"
                    aria-label="Refresh balance"
                  >
                    <.icon name="hero-arrow-path" class="size-3.5" />
                  </button>
                </div>
                <a
                  :if={info.billing_url}
                  id={"topup-#{info.key}"}
                  href={info.billing_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium text-primary transition hover:bg-primary/10"
                >
                  <.icon name="hero-plus-circle" class="size-4" /> Add credits
                </a>
              </div>

              <div
                :if={@keys[info.key]}
                class="mt-2 flex items-center justify-end gap-2"
              >
                <button
                  type="button"
                  id={"check-current-#{info.key}"}
                  phx-click="check_current"
                  phx-value-provider={info.key}
                  disabled={@pending[info.key] != nil}
                  class="flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium transition hover:bg-base-200 disabled:opacity-50"
                >
                  <.spinner :if={@pending[info.key] == :check_current} /> Check current key
                </button>
                <button
                  :if={match?({:stored, _}, @keys[info.key])}
                  type="button"
                  id={"remove-#{info.key}"}
                  phx-click="remove"
                  phx-value-provider={info.key}
                  data-confirm={"Remove the saved #{info.name} key?"}
                  class="flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium text-error transition hover:bg-error/10"
                >
                  <.icon name="hero-trash" class="size-3.5" /> Remove
                </button>
              </div>
            </section>
          </div>

          <%!-- LOCAL-25 to LOCAL-28: the llama-server Elia can start for you,
          from a .gguf on this machine. --%>
          <section
            id="local-server"
            class="mt-4 rounded-2xl border border-base-300 p-5 transition duration-200 hover:border-base-content/20 hover:shadow-sm"
          >
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="flex items-center gap-3">
                <div class="grid size-10 place-items-center rounded-xl bg-base-200 text-base-content/70">
                  <.icon name="hero-cpu-chip" class="size-5" />
                </div>
                <div>
                  <h2 class="font-medium">Local model server</h2>
                  <p class="text-xs text-base-content/50">
                    A llama-server Elia starts for you from a .gguf on this machine.
                  </p>
                </div>
              </div>
              <.status_badge status={@server.status} />
            </div>

            <.form
              for={@server_form}
              id="local-server-form"
              phx-submit="save_local_server"
              class="contents"
            >
              <div class="mt-5 grid gap-3 sm:grid-cols-2">
                <div class="sm:col-span-2">
                  <.input
                    field={@server_form[:binary]}
                    type="text"
                    label="llama-server binary"
                    placeholder="/path/to/llama.cpp/build/bin/llama-server"
                    class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-xs outline-none transition focus:border-primary focus:bg-base-100"
                  />
                </div>
                <div class="sm:col-span-2">
                  <.input
                    field={@server_form[:model]}
                    type="text"
                    label="Model (.gguf)"
                    list="local-server-models"
                    placeholder="/path/to/model.gguf"
                    class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-xs outline-none transition focus:border-primary focus:bg-base-100"
                  />
                  <datalist id="local-server-models">
                    <option :for={path <- @server_models} value={path} />
                  </datalist>
                  <p :if={@server_models == []} class="mt-1 text-xs text-base-content/50">
                    No .gguf files found — set a models directory to pick one from a list.
                  </p>
                </div>
                <div class="sm:col-span-2">
                  <.input
                    field={@server_form[:models_dir]}
                    type="text"
                    label="Models directory"
                    placeholder="/path/to/models"
                    class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-xs outline-none transition focus:border-primary focus:bg-base-100"
                  />
                </div>
                <.input
                  field={@server_form[:host]}
                  type="text"
                  label="Host"
                  class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-xs outline-none transition focus:border-primary focus:bg-base-100"
                />
                <.input
                  field={@server_form[:port]}
                  type="text"
                  inputmode="numeric"
                  label="Port"
                  class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-xs outline-none transition focus:border-primary focus:bg-base-100"
                />
                <.input
                  field={@server_form[:context]}
                  type="text"
                  inputmode="numeric"
                  label="Context (-c)"
                  class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-xs outline-none transition focus:border-primary focus:bg-base-100"
                />
                <.input
                  field={@server_form[:threads]}
                  type="text"
                  inputmode="numeric"
                  label="Threads (-t)"
                  class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-xs outline-none transition focus:border-primary focus:bg-base-100"
                />
                <div class="sm:col-span-2">
                  <.input
                    field={@server_form[:extra_args]}
                    type="text"
                    label="Extra arguments"
                    placeholder="--flash-attn"
                    class="w-full rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 font-mono text-xs outline-none transition focus:border-primary focus:bg-base-100"
                  />
                </div>
                <label class="flex items-center gap-2 text-xs text-base-content/70 sm:col-span-2">
                  <.input
                    field={@server_form[:jinja]}
                    type="checkbox"
                    label="Apply the chat template (--jinja, needed for tool calls)"
                  />
                </label>

                <div class="flex flex-wrap items-center gap-2 sm:col-span-2">
                  <button
                    type="submit"
                    name="action"
                    value="save"
                    id="save-local-server"
                    class="flex h-10 items-center gap-1.5 rounded-xl border border-base-300 px-4 text-sm font-medium transition hover:bg-base-200"
                  >
                    <.icon name="hero-check" class="size-4" /> Save
                  </button>
                  <button
                    type="submit"
                    name="action"
                    value="start"
                    id="start-local-server"
                    disabled={@server.status in [:starting, :running]}
                    class="flex h-10 items-center gap-1.5 rounded-xl bg-primary px-4 text-sm font-medium text-primary-content transition hover:brightness-110 disabled:opacity-50"
                  >
                    <.icon name="hero-play" class="size-4" /> Start
                  </button>
                  <button
                    type="button"
                    id="stop-local-server"
                    phx-click="stop_local_server"
                    disabled={@server.status not in [:starting, :running]}
                    class="flex h-10 items-center gap-1.5 rounded-xl border border-base-300 px-4 text-sm font-medium transition hover:bg-base-200 disabled:opacity-50"
                  >
                    <.icon name="hero-stop" class="size-4" /> Stop
                  </button>
                  <button
                    type="button"
                    id="reset-local-server"
                    phx-click="reset_local_server"
                    class="flex h-10 items-center gap-1.5 rounded-xl border border-base-300 px-4 text-sm font-medium transition hover:bg-base-200"
                  >
                    <.icon name="hero-arrow-uturn-left" class="size-4" /> Reset
                  </button>
                </div>
              </div>
            </.form>

            <div
              :if={result = @server_result}
              id="local-server-result"
              class={[
                "mt-3 flex items-start gap-2 rounded-lg px-3 py-2 text-xs",
                elem(result, 0) == :ok && "bg-success/10 text-success",
                elem(result, 0) == :error && "bg-error/10 text-error"
              ]}
            >
              <.icon
                name={
                  if elem(result, 0) == :ok,
                    do: "hero-check-circle",
                    else: "hero-exclamation-triangle"
                }
                class="mt-px size-4 shrink-0"
              />
              <span class="break-words">{elem(result, 1)}</span>
            </div>

            <div id="local-server-status" class="mt-4 rounded-xl bg-base-200/50 p-3 text-xs">
              <div class="flex flex-wrap items-center gap-2">
                <.status_badge id="local-server-badge" status={@server.status} />
                <span class="font-mono">{@server.url}</span>
                <span :if={@server.os_pid} class="text-base-content/60">
                  pid {@server.os_pid}
                </span>
              </div>
              <p :if={@server.model} class="mt-1 break-all text-base-content/70">
                {@server.model}
              </p>
              <p :if={@server.command} class="mt-1 break-all font-mono text-base-content/50">
                $ {@server.command}
              </p>
              <p :if={@server.error} class="mt-2 text-error">{@server.error}</p>
              <pre
                :if={@server.output != []}
                id="local-server-log"
                class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-all font-mono text-[11px] text-base-content/60"
              ><%= Enum.join(@server.output, "\n") %></pre>
            </div>
          </section>

          <%!-- CONF-19, CONF-20, DEPLOY-5..DEPLOY-7: deployment means bringing
          the trunk `master` to `live` and loading it here. --%>
          <section
            id="deployment"
            class="mt-4 rounded-2xl border border-base-300 p-5 transition duration-200 hover:border-base-content/20 hover:shadow-sm"
          >
            <div class="flex items-center gap-3">
              <div class="grid size-10 place-items-center rounded-xl bg-base-200 text-base-content/70">
                <.icon name="hero-rocket-launch" class="size-5" />
              </div>
              <div>
                <h2 class="font-medium">Deployment</h2>
                <p class="text-xs text-base-content/50">
                  Bring the app up to date: merging <code class="font-mono">master</code>
                  into <code class="font-mono">live</code>, then loading it into the running server.
                </p>
              </div>
            </div>

            <p
              id="deploy-status"
              class={[
                "mt-4 flex items-start gap-2 rounded-lg px-3 py-2 text-xs",
                deploy_ready?(@deployment) && "bg-base-200 text-base-content/70",
                !deploy_ready?(@deployment) && "bg-warning/10 text-warning"
              ]}
            >
              <.icon
                name={
                  if deploy_ready?(@deployment),
                    do: "hero-check-circle",
                    else: "hero-exclamation-triangle"
                }
                class="mt-px size-4 shrink-0"
              />
              <span class="break-words">{deploy_status(@deployment)}</span>
            </p>

            <div :if={deploy_ready?(@deployment)} class="mt-4 flex flex-wrap gap-2">
              <button
                type="button"
                id="deploy-reload"
                phx-click="deploy"
                phx-value-mode="reload"
                disabled={@deploying != nil}
                title="Run the tests, merge master into live and reload the running app, keeping its state"
                class="flex h-10 items-center gap-1.5 rounded-xl border border-base-300 px-4 text-sm font-medium transition hover:bg-base-200 disabled:opacity-50"
              >
                <.spinner :if={@deploying == "reload"} />
                <.icon :if={@deploying != "reload"} name="hero-arrow-path" class="size-4" />
                Hot reload
              </button>
              <button
                type="button"
                id="deploy-restart"
                phx-click="deploy"
                phx-value-mode="restart"
                disabled={@deploying != nil}
                title="Run the tests, merge master into live and restart the server on the deployed code"
                class="flex h-10 items-center gap-1.5 rounded-xl bg-primary px-4 text-sm font-medium text-primary-content transition hover:brightness-110 disabled:opacity-50"
              >
                <.spinner :if={@deploying == "restart"} />
                <.icon
                  :if={@deploying != "restart"}
                  name="hero-arrow-path-rounded-square"
                  class="size-4"
                /> Restart
              </button>
            </div>

            <%!-- CONF-20, DEPLOY-16: the last deploy's result stays here, so a
            page that arrives after the deploy ended still reports what it did. --%>
            <p
              :if={@deploy_result}
              id="deploy-result"
              class={[
                "mt-3 flex items-start gap-2 whitespace-pre-line break-words rounded-lg px-3 py-2 text-xs",
                @deploy_result.kind == :ok && "bg-success/10 text-success",
                @deploy_result.kind != :ok && "bg-error/10 text-error"
              ]}
            >
              <.icon
                name={
                  if @deploy_result.kind == :ok,
                    do: "hero-check-circle",
                    else: "hero-exclamation-triangle"
                }
                class="mt-px size-4 shrink-0"
              />
              <span>{@deploy_result.text}</span>
            </p>
          </section>

          <%!-- PUSH-2, PUSH-5..PUSH-8: Web Push on this device. The hook does the
          subscribing (PUSH-3, PUSH-4), because only the page can ask for
          permission and make a subscription; the section says why when it
          cannot (PUSH-5, PUSH-6), and offers what the server does (PUSH-7,
          PUSH-8). --%>
          <section
            id="push-section"
            phx-hook=".PushSettings"
            data-vapid-public-key={@push_key}
            class="mt-4 rounded-2xl border border-base-300 p-5 transition duration-200 hover:border-base-content/20 hover:shadow-sm"
          >
            <div class="flex items-center gap-3">
              <div class="grid size-10 place-items-center rounded-xl bg-base-200 text-base-content/70">
                <.icon name="hero-bell-alert" class="size-5" />
              </div>
              <div>
                <h2 class="font-medium">Push notifications</h2>
                <p class="text-xs text-base-content/50">
                  Be told when a chat needs you — an approval, a question, a turn that
                  finished — even with Elia closed.
                </p>
              </div>
            </div>

            <%!-- PUSH-19, PUSH-22: what the section is doing. Before the page has
            reached the server nothing has been read, and only the server can
            say so — the hook (PUSH-20) replaces this with what it found, and
            takes the `push-checking` marker with it, so a section whose markup
            is rendered again reads the browser again. --%>
            <p id="push-reason" class="push-checking mt-4 text-xs text-base-content/50">
              {push_checking_text(@push_connected)}
            </p>

            <div id="push-controls" class="mt-4 flex flex-col gap-3">
              <%!-- PUSH-5, PUSH-23: a reason takes the switch's place, and
              nothing else. The count, the test notification and "remove all"
              are about the server, so they stay reachable where this browser
              cannot push: a device that is gone can still be removed from here
              (PUSH-7), and a send can still be tried (PUSH-8). --%>
              <div
                id="push-switch-row"
                class="hidden items-center justify-between gap-3 rounded-xl bg-base-200/50 px-4 py-3"
              >
                <span class="text-sm">Notifications on this device</span>
                <button
                  type="button"
                  id="push-toggle"
                  aria-pressed="false"
                  class="h-10 shrink-0 rounded-xl border border-base-300 px-4 text-sm font-medium transition hover:bg-base-200 disabled:opacity-50"
                >
                  Turn on
                </button>
              </div>

              <div class="flex flex-wrap items-center gap-2">
                <button
                  type="button"
                  id="push-send-test"
                  phx-click="push-send-test"
                  class="flex h-10 items-center gap-1.5 rounded-xl bg-primary px-4 text-sm font-medium text-primary-content transition hover:brightness-110"
                >
                  <.icon name="hero-paper-airplane" class="size-4" /> Send a test notification
                </button>
                <button
                  type="button"
                  id="push-remove-all"
                  phx-click="push-remove-all"
                  disabled={@push_count == 0}
                  class="flex h-10 items-center gap-1.5 rounded-xl border border-base-300 px-4 text-sm font-medium transition hover:bg-base-200 disabled:opacity-50"
                >
                  <.icon name="hero-trash" class="size-4" /> Remove all devices
                </button>
              </div>

              <p id="push-count" class="text-xs text-base-content/50">
                {push_count_text(@push_count)}
              </p>

              <p
                :if={@push_status}
                id="push-status"
                class={[
                  "flex items-start gap-2 break-words rounded-lg px-3 py-2 text-xs",
                  @push_status.kind == :ok && "bg-success/10 text-success",
                  @push_status.kind != :ok && "bg-error/10 text-error"
                ]}
              >
                <.icon
                  name={
                    if @push_status.kind == :ok,
                      do: "hero-check-circle",
                      else: "hero-exclamation-triangle"
                  }
                  class="mt-px size-4 shrink-0"
                />
                <span>{@push_status.text}</span>
              </p>
            </div>
          </section>

          <p
            id="settings-path"
            class="mt-8 flex items-center gap-2 text-xs text-base-content/50"
          >
            <.icon name="hero-circle-stack" class="size-4 shrink-0" />
            <span>
              Stored in <code class="font-mono text-base-content/70">{@settings_path}</code>
              (readable only by you).
            </span>
          </p>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".PushSettings">
        // PUSH-3..PUSH-6: subscribing is the page's job — only the page can ask
        // for permission and make a subscription — so this hook owns the switch
        // and tells the server about the subscription it made, and says why
        // there can be no switch at all. PUSH-19: the worker the app registered
        // (PWA-5) is what a subscription rides on, so when it never starts the
        // section says that instead of waiting for ever.
        const workerWait = 4000
        // PUSH-20: how often a section that has not settled is looked at again.
        // The look itself is one class lookup; the browser is read again only
        // when the section is showing neither the switch nor a reason.
        const recheckEvery = 2000

        export default {
          mounted() {
            this.subscribed = false

            // PUSH-20: the switch is looked up on every use rather than kept,
            // and the click is heard on the section itself, so a section the
            // server renders again is still the one this hook drives.
            this.el.addEventListener("click", event => {
              if (event.target.closest("#push-toggle")) this.toggleSubscription()
            })

            // PUSH-21: a page that comes back in front of the user reads the
            // browser again, since its answer may have changed while it was
            // away — permission withdrawn, a subscription made or dropped.
            this.onVisibility = () => {
              if (document.visibilityState === "visible") this.refresh()
            }
            document.addEventListener("visibilitychange", this.onVisibility)

            this.timer = setInterval(() => this.recheck(), recheckEvery)
            this.refresh()
          },

          destroyed() {
            document.removeEventListener("visibilitychange", this.onVisibility)
            clearInterval(this.timer)
          },

          // PUSH-20: whether the section still has to be read. The marker the
          // server renders is what the section says before anything has been
          // read, and it comes back with the markup whenever the server renders
          // the section again — as a reconnect does after the app has been in
          // the background, which is where the answer this hook put there goes.
          recheck() {
            const reason = this.el.querySelector("#push-reason")
            if (reason && reason.classList.contains("push-checking")) this.refresh()
          },

          // PUSH-5, PUSH-6: why this browser cannot push at all, or null when it
          // can. These are cheap, permanent answers about the browser itself.
          blocker() {
            if (!window.isSecureContext) {
              return "Notifications need a secure origin: open Elia over HTTPS, or on localhost."
            }
            if (!("serviceWorker" in navigator)) {
              return "This browser has no service worker, so it cannot receive notifications."
            }
            if (!("PushManager" in window) || !("Notification" in window)) {
              return "This browser cannot show notifications."
            }
            return null
          },

          async refresh() {
            try {
              const blocker = this.blocker()
              if (blocker) return this.show(blocker, false)

              // PUSH-19: the worker comes before the permission question. A page
              // whose worker never started cannot subscribe whatever permission
              // it has, and "blocked" would point at the wrong thing — as when an
              // auth proxy answers /sw.js with its login page.
              const registration = await this.activeWorker()
              if (!registration) return this.show(this.workerReason(), false)

              if (Notification.permission === "denied") {
                return this.show(
                  "Notifications are blocked for this site. Allow them for it in the browser's settings, then reload.",
                  false
                )
              }

              const subscription = await registration.pushManager.getSubscription()
              this.show(null, !!subscription)
            } catch (error) {
              // PUSH-20: a browser that cannot be read at all is an answer too,
              // and the one a phone — which has no console — can show.
              this.show(`This browser could not be read: ${error}`, false)
            }
          },

          // PUSH-19: why there is nothing to offer when the worker never became
          // active. PWA-5 leaves a failed registration's error on `window`; with
          // no error, the worker was still starting after a few seconds.
          workerReason() {
            const error = window.eliaServiceWorkerError
            const because = error ? ` (${error})` : ""
            return (
              `Notifications need this app's service worker, and it has not started${because}. ` +
              "If the app is behind a login page, let /sw.js through it, then reload."
            )
          },

          // PUSH-19: the worker the page registered (PWA-5), or null when it is
          // not active. A failed registration leaves its error on `window`, and
          // an older worker may still be in charge, so then the registration is
          // read as it stands rather than waited on; one still starting gets a
          // few seconds. Either way the section reads the browser again by
          // itself when a worker does turn up, so nothing waits for ever and no
          // reload is needed.
          async activeWorker() {
            const registration = window.eliaServiceWorkerError
              ? await this.registeredNow()
              : await this.waitForWorker()

            if (!registration) this.readAgainWhenReady()

            return registration
          },

          async registeredNow() {
            try {
              const registration = await navigator.serviceWorker.getRegistration()
              return registration && registration.active ? registration : null
            } catch (_error) {
              return null
            }
          },

          waitForWorker() {
            return new Promise(resolve => {
              let settled = false

              const settle = registration => {
                if (settled) return
                settled = true
                clearTimeout(timer)
                clearInterval(poll)
                resolve(registration)
              }

              const timer = setTimeout(() => settle(null), workerWait)
              const poll = setInterval(() => {
                if (window.eliaServiceWorkerError) settle(null)
              }, 200)

              navigator.serviceWorker.ready.then(registration => settle(registration))
            })
          },

          readAgainWhenReady() {
            if (this.watching) return
            this.watching = true

            navigator.serviceWorker.ready.then(() => {
              this.watching = false
              this.refresh()
            })
          },

          show(reason, subscribed) {
            const reasonLine = this.el.querySelector("#push-reason")
            const switchRow = this.el.querySelector("#push-switch-row")
            const toggle = this.el.querySelector("#push-toggle")

            // PUSH-20: the marker goes with the first answer. A section the
            // server renders again gets it back, and reads the browser again.
            reasonLine.classList.remove("push-checking")
            reasonLine.textContent = reason || ""
            reasonLine.classList.toggle("hidden", !reason)

            // PUSH-23: the reason takes the switch's place, and nothing else —
            // the count, the test and "remove all" stay where they are.
            switchRow.classList.toggle("hidden", !!reason)
            switchRow.classList.toggle("flex", !reason)

            this.subscribed = subscribed

            if (toggle) {
              toggle.textContent = subscribed ? "Turn off" : "Turn on"
              toggle.setAttribute("aria-pressed", subscribed ? "true" : "false")
            }
          },

          async toggleSubscription() {
            const toggle = this.el.querySelector("#push-toggle")
            if (toggle) toggle.disabled = true

            try {
              if (this.subscribed) await this.unsubscribe()
              else await this.subscribe()
            } catch (error) {
              console.warn("push:", error)
              this.show(`Notifications could not be changed: ${error}`, this.subscribed)
            } finally {
              if (toggle) toggle.disabled = false
            }
          },

          async subscribe() {
            const permission = await Notification.requestPermission()
            if (permission !== "granted") {
              return this.show("Notifications were not allowed for this site.", false)
            }

            const registration = await navigator.serviceWorker.ready
            const subscription = await registration.pushManager.subscribe({
              userVisibleOnly: true,
              applicationServerKey: decodeKey(this.el.dataset.vapidPublicKey)
            })

            // PUSH-3: the server keeps it, so a chat that needs the user can
            // reach this device.
            this.pushEvent("push-subscribe", {subscription: subscription.toJSON()})
            this.show(null, true)
          },

          async unsubscribe() {
            const registration = await navigator.serviceWorker.ready
            const subscription = await registration.pushManager.getSubscription()

            if (subscription) {
              const endpoint = subscription.endpoint
              await subscription.unsubscribe()
              // PUSH-4: this device's entry goes with the subscription.
              this.pushEvent("push-unsubscribe", {endpoint: endpoint})
            }

            this.show(null, false)
          }
        }

        // The app's VAPID public key is URL-safe base64; the Push API wants the
        // bytes it stands for.
        function decodeKey(base64) {
          const padding = "=".repeat((4 - (base64.length % 4)) % 4)
          const normalized = (base64 + padding).replace(/-/g, "+").replace(/_/g, "/")
          const raw = atob(normalized)
          return Uint8Array.from(raw, character => character.charCodeAt(0))
        }
      </script>
    </Layouts.app>
    """
  end

  attr :key, :any, required: true
  attr :provider, :string, required: true
  attr :keyless, :boolean, default: false

  defp key_status(assigns) do
    ~H"""
    <span
      id={"key-status-#{@provider}"}
      class={[
        "flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium",
        match?({:stored, _}, @key) && "bg-success/15 text-success",
        match?({:env, _}, @key) && "bg-info/15 text-info",
        (@key == nil or @keyless) && "bg-base-300 text-base-content/60"
      ]}
    >
      <%= cond do %>
        <% @keyless -> %>
          <.icon name="hero-cpu-chip" class="size-3.5" /> No key needed
        <% match?({:stored, _}, @key) -> %>
          <% key = elem(@key, 1) %>
          <.icon name="hero-key" class="size-3.5" /> Saved
          <span class="font-mono opacity-70">{mask(key)}</span>
        <% match?({:env, _}, @key) -> %>
          <% key = elem(@key, 1) %>
          <.icon name="hero-command-line" class="size-3.5" /> From environment
          <span class="font-mono opacity-70">{mask(key)}</span>
        <% true -> %>
          Not set
      <% end %>
    </span>
    """
  end

  # LOCAL-16, LOCAL-26: what state the local server is in, as the page shows it.
  attr :status, :atom, required: true
  attr :id, :string, default: nil

  defp status_badge(assigns) do
    assigns = assign(assigns, :label, status_label(assigns.status))

    ~H"""
    <span
      id={@id}
      class={[
        "flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium",
        status_class(@status)
      ]}
    >
      {@label}
    </span>
    """
  end

  defp status_label(:running), do: "Running"
  defp status_label(:starting), do: "Starting…"
  defp status_label(:stopping), do: "Stopping…"
  defp status_label(:external), do: "Running (started outside Elia)"
  defp status_label(:failed), do: "Failed"
  defp status_label(_status), do: "Stopped"

  defp status_class(:running), do: "bg-success/15 text-success"
  defp status_class(:external), do: "bg-info/15 text-info"
  defp status_class(:starting), do: "bg-info/15 text-info"
  defp status_class(:failed), do: "bg-error/15 text-error"
  defp status_class(_status), do: "bg-base-300 text-base-content/60"

  attr :provider, :string, required: true
  attr :supported, :boolean, required: true
  attr :balance, :any, default: nil

  defp balance_line(assigns) do
    ~H"""
    <span id={"balance-#{@provider}"}>
      <%= cond do %>
        <% !@supported -> %>
          Balance isn't available through the API; see the billing page.
        <% @balance in [nil, :loading] -> %>
          Loading…
        <% match?({:error, _}, @balance) -> %>
          <span class="text-error">Couldn't load credits: {elem(@balance, 1)}</span>
        <% true -> %>
          {format_balance(elem(@balance, 1))}
      <% end %>
    </span>
    """
  end

  @doc false
  def format_balance(%{scope: :account} = balance) do
    "#{usd(balance.remaining)} remaining (#{usd(balance.used)} used of #{usd(balance.total)})"
  end

  def format_balance(%{scope: :key} = balance) do
    limit =
      if balance.total && balance.remaining,
        do: " · #{usd(balance.remaining)} left of #{usd(balance.total)} key limit",
        else: ""

    "#{usd(balance.used)} used" <> limit
  end

  defp usd(amount), do: "$" <> :erlang.float_to_binary(amount / 1, decimals: 2)

  defp spinner(assigns) do
    ~H"""
    <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
    """
  end

  # CONF-19: whether the live tree is set up for deployment (DEPLOY-14) — the
  # deploy buttons only make sense when it is.
  defp deploy_ready?({:ok, _status}), do: true
  defp deploy_ready?({:error, _reason}), do: false

  # CONF-19, DEPLOY-17: `live` is merged but the running app never got it — the
  # deploy was interrupted after the merge. Say so, rather than "nothing to do".
  defp deploy_status({:ok, %{behind?: true} = status}) do
    "live has #{short(status.live)} merged, but the running app is still on " <>
      "#{short(status.loaded)}: a deploy merged and never loaded. Hot reload brings " <>
      "the app up to date — no new tests or merge needed."
  end

  # CONF-19: what the deployment section says about the live tree.
  defp deploy_status({:ok, %{pending: 0}}),
    do: "live is up to date with master: nothing to deploy."

  defp deploy_status({:ok, %{pending: 1}}), do: "1 commit on master is not deployed yet."

  defp deploy_status({:ok, %{pending: commits}}),
    do: "#{commits} commits on master are not deployed yet."

  defp deploy_status({:error, reason}), do: reason

  defp short(sha), do: String.slice(sha, 0, 12)

  defp mask(key), do: "••••" <> String.slice(key, -4, 4)

  defp provider_blurb("anthropic"), do: "Claude models via the Anthropic API"
  defp provider_blurb("openrouter"), do: "Hundreds of models from many vendors via OpenRouter"
  defp provider_blurb(_key), do: ""

  defp key_placeholder("anthropic"), do: "sk-ant-…"
  defp key_placeholder("openrouter"), do: "sk-or-…"
  defp key_placeholder(_key), do: "API key"

  ## Events

  @impl true
  def handle_event("submit", %{"provider" => key} = params, socket) do
    api_key = get_in(params, [key, "api_key"]) || ""
    action = if params["action"] == "save", do: :save, else: :check

    socket =
      socket
      |> assign(
        forms: Map.put(socket.assigns.forms, key, to_form(%{"api_key" => api_key}, as: key))
      )
      |> run(key, action, fn ->
        if action == :save, do: LLM.save_key(key, api_key), else: LLM.check_key(key, api_key)
      end)

    {:noreply, socket}
  end

  def handle_event("check_current", %{"provider" => key}, socket) do
    case LLM.api_key(key) do
      {_source, api_key} ->
        {:noreply, run(socket, key, :check_current, fn -> LLM.check_key(key, api_key) end)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("refresh_balance", %{"provider" => key}, socket) do
    {:noreply, load_balance(socket, key)}
  end

  def handle_event("remove", %{"provider" => key}, socket) do
    socket =
      case LLM.delete_key(key) do
        :ok ->
          put_result(socket, key, {:ok, "Saved key removed."})

        {:error, reason} ->
          put_result(socket, key, {:error, "Could not remove: #{inspect(reason)}"})
      end

    {:noreply,
     socket
     |> refresh_keys()
     |> assign(balances: Map.delete(socket.assigns.balances, key))
     |> load_balance(key)}
  end

  # LOCAL-24: a keyless provider's card checks and saves a base URL instead of
  # a key, since it has none (LOCAL-2).
  def handle_event("submit_base_url", %{"provider" => key} = params, socket) do
    url = get_in(params, [key, "base_url"]) || ""
    action = if params["action"] == "save", do: :save, else: :check

    socket =
      socket
      |> assign(base_forms: Map.put(socket.assigns.base_forms, key, base_url_form(key, url)))
      |> run_base_url(key, action, fn ->
        if action == :save, do: LLM.save_base_url(key, url), else: LLM.check_base_url(key, url)
      end)

    {:noreply, socket}
  end

  def handle_event("remove_base_url", %{"provider" => key}, socket) do
    socket =
      case LLM.delete_base_url(key) do
        :ok ->
          put_result(socket, key, {:ok, "Saved base URL removed."})

        {:error, reason} ->
          put_result(socket, key, {:error, "Could not remove: #{inspect(reason)}"})
      end

    {:noreply, refresh_base_urls(socket)}
  end

  # LOCAL-25, LOCAL-28: the fields are stored; "Start" stores them and then
  # starts the server with them.
  def handle_event("save_local_server", %{"server" => params} = event, socket) do
    action = if event["action"] == "start", do: :start, else: :save

    case LlamaServer.save(server_attrs(params)) do
      :ok when action == :start ->
        {:noreply, start_local_server(socket)}

      :ok ->
        {:noreply,
         socket
         |> assign(server_settings: LlamaServer.settings())
         |> put_server_result({:ok, "Saved."})}

      {:error, reason} ->
        {:noreply, put_server_result(socket, {:error, "Could not save: #{inspect(reason)}"})}
    end
  end

  def handle_event("stop_local_server", _params, socket) do
    {:ok, _status} = LlamaServer.stop_server()

    {:noreply, socket |> refresh_server() |> put_server_result({:ok, "Server stopped."})}
  end

  def handle_event("reset_local_server", _params, socket) do
    socket =
      case LlamaServer.reset() do
        :ok ->
          put_server_result(socket, {:ok, "Reset: the configured settings apply again."})

        {:error, reason} ->
          put_server_result(socket, {:error, "Could not reset: #{inspect(reason)}"})
      end

    {:noreply, refresh_server(socket)}
  end

  # CONF-19, CONF-20, DEPLOY-6, DEPLOY-7, DEPLOY-15: ask the runner for a deploy.
  # It runs in its own process, so navigating away, closing the tab or this page
  # reloading itself (DEPLOY-12) doesn't abort it.
  def handle_event("deploy", %{"mode" => mode}, socket) when mode in ~w(reload restart) do
    socket =
      case Deploy.Runner.start(deploy_mode(mode)) do
        :ok ->
          socket
          |> assign(deploying: mode, deploy_result: nil)
          |> assign(deployment: Deploy.status())

        # CONF-20, DEPLOY-16: a click while a deploy runs is ignored, and the
        # page shows the deploy that is already running.
        {:error, :busy} ->
          refresh_deploy(socket)
      end

    {:noreply, socket}
  end

  # PUSH-3: the page subscribed and reports the subscription it made, so that
  # device can be sent to. An unusable one is refused rather than stored.
  def handle_event("push-subscribe", %{"subscription" => subscription}, socket) do
    case Push.Subscriptions.save(subscription) do
      :ok ->
        {:noreply,
         assign(socket,
           push_count: Push.Subscriptions.count(),
           push_status: %{kind: :ok, text: "This device is subscribed."}
         )}

      {:error, :invalid_subscription} ->
        {:noreply,
         assign(socket,
           push_status: %{
             kind: :error,
             text: "That subscription is not a usable one, so it was not stored."
           }
         )}
    end
  end

  # PUSH-4: the page unsubscribed, so that endpoint goes with it.
  def handle_event("push-unsubscribe", %{"endpoint" => endpoint}, socket) do
    :ok = Push.Subscriptions.remove(endpoint)

    {:noreply,
     assign(socket,
       push_count: Push.Subscriptions.count(),
       push_status: %{kind: :ok, text: "This device is no longer subscribed."}
     )}
  end

  # PUSH-8: ask the push service now, off this process, and report what it said.
  def handle_event("push-send-test", _params, socket) do
    {:noreply, start_async(socket, :push_test, fn -> Push.test_notification() end)}
  end

  # PUSH-7: every subscription goes, including the ones whose device is gone.
  def handle_event("push-remove-all", _params, socket) do
    :ok = Push.Subscriptions.clear()

    {:noreply,
     assign(socket,
       push_count: 0,
       push_status: %{kind: :ok, text: "Every subscribed device was removed."}
     )}
  end

  defp deploy_mode("reload"), do: :reload
  defp deploy_mode("restart"), do: :restart

  # PUSH-22: what the section says before its own script has run. A page that
  # has not reached the server cannot have read anything, and saying which of
  # the two it is doing is how a phone, which has no console, tells a page that
  # never connected from a reading that failed.
  defp push_checking_text(true), do: "Checking this browser…"

  defp push_checking_text(false),
    do: "This page has not reached the server yet, so nothing has been read."

  # PUSH-7: how many devices are subscribed.
  defp push_count_text(0), do: "No device is subscribed yet."
  defp push_count_text(1), do: "1 device is subscribed."
  defp push_count_text(count), do: "#{count} devices are subscribed."

  # PUSH-8: what the test notification did, as the section reports it.
  defp push_result({:ok, %{sent: sent, gone: gone, failed: failed}}) do
    parts =
      ["Accepted by the push service for #{subscriptions(sent)}."] ++
        if(gone > 0, do: ["#{subscriptions(gone)} had gone and were removed."], else: []) ++
        if(failed > 0, do: ["#{subscriptions(failed)} failed."], else: [])

    %{kind: if(gone > 0 or failed > 0, do: :error, else: :ok), text: Enum.join(parts, " ")}
  end

  defp push_result({:error, :no_subscriptions}) do
    %{kind: :error, text: "No device is subscribed yet, so there was nowhere to send it."}
  end

  defp subscriptions(1), do: "1 subscription"
  defp subscriptions(count), do: "#{count} subscriptions"

  # CONF-20, DEPLOY-16: what the runner holds right now.
  defp refresh_deploy(socket) do
    deploy = Deploy.Runner.state()

    assign(socket,
      deploying: deploy.running && to_string(deploy.running.mode),
      deploy_result: deploy.last && deploy_result(deploy.last.result),
      deployment: Deploy.status()
    )
  end

  defp run(socket, key, action, fun) do
    if Map.has_key?(socket.assigns.pending, key) or LLM.provider_info(key) == nil do
      socket
    else
      socket
      |> assign(pending: Map.put(socket.assigns.pending, key, action))
      |> assign(results: Map.delete(socket.assigns.results, key))
      |> start_async({:key, key, action}, fun)
    end
  end

  # PUSH-8: what the test notification did.
  def handle_async(:push_test, {:ok, result}, socket) do
    {:noreply, assign(socket, push_status: push_result(result))}
  end

  def handle_async(:push_test, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       push_status: %{kind: :error, text: "Sending it failed: #{inspect(reason)}"}
     )}
  end

  @impl true
  def handle_async({:balance, key}, result, socket) do
    balance =
      case result do
        {:ok, {:ok, balance}} -> {:ok, balance}
        {:ok, {:error, message}} -> {:error, message}
        {:ok, :unsupported} -> {:error, "Not supported"}
        {:exit, reason} -> {:error, Exception.format_exit(reason)}
      end

    {:noreply, assign(socket, balances: Map.put(socket.assigns.balances, key, balance))}
  end

  def handle_async({:key, key, action}, result, socket) do
    socket = assign(socket, pending: Map.delete(socket.assigns.pending, key))

    socket =
      case {result, action} do
        {{:ok, :ok}, :save} ->
          socket
          |> assign(forms: Map.put(socket.assigns.forms, key, empty_form(key)))
          |> put_result(key, {:ok, "Key verified and saved."})

        {{:ok, :ok}, _check} ->
          put_result(socket, key, {:ok, "Key is valid."})

        {{:ok, {:error, message}}, _action} ->
          put_result(socket, key, {:error, message})

        {{:exit, reason}, _action} ->
          put_result(socket, key, {:error, "Check failed: #{Exception.format_exit(reason)}"})
      end

    socket = refresh_keys(socket)

    socket =
      if action == :save and match?({:ok, :ok}, result),
        do:
          socket
          |> assign(balances: Map.delete(socket.assigns.balances, key))
          |> load_balance(key),
        else: socket

    {:noreply, socket}
  end

  def handle_async({:base_url, key, action}, result, socket) do
    socket = assign(socket, pending: Map.delete(socket.assigns.pending, key))

    socket =
      case {result, action} do
        {{:ok, :ok}, :save} ->
          put_result(socket, key, {:ok, "A server answers there; the URL is saved."})

        {{:ok, :ok}, _check} ->
          put_result(socket, key, {:ok, "A server answers there."})

        {{:ok, {:error, message}}, _action} ->
          put_result(socket, key, {:error, message})

        {{:exit, reason}, _action} ->
          put_result(socket, key, {:error, "Check failed: #{Exception.format_exit(reason)}"})
      end

    {:noreply, refresh_base_urls(socket)}
  end

  # CONF-20, DEPLOY-16: the deploy's events come from the runner, so they reach
  # this page even when another page started the deploy — and a page that mounts
  # while one runs or after one finished reads the same state in mount/3.
  @impl true
  def handle_info({:deploy_started, %{mode: mode}}, socket) do
    {:noreply, assign(socket, deploying: to_string(mode))}
  end

  def handle_info({:deploy_finished, %{result: result}}, socket) do
    {:noreply, refresh_deploy(assign(socket, deploy_result: deploy_result(result)))}
  end

  # LOCAL-26: the local server's own state changes reach this page the moment
  # they happen — a start, ready, a failure, a stop.
  def handle_info({:llama_server, status}, socket) do
    {:noreply, assign(socket, server: status)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # CONF-20, DEPLOY-5..DEPLOY-7, DEPLOY-17: report what the deploy did, and how
  # the live tree stands now.
  defp deploy_result({:ok, message}), do: %{kind: :ok, text: message}

  defp deploy_result({:tests_failed, output}),
    do: %{
      kind: :error,
      text: "Tests failed; nothing was loaded.\n\n" <> Elia.Shell.truncate(output, 4_000)
    }

  defp deploy_result({:error, reason}), do: %{kind: :error, text: reason}

  defp deploy_result({:exit, reason}),
    do: %{kind: :error, text: "The deploy failed: #{Exception.format_exit(reason)}"}

  defp put_result(socket, key, result) do
    assign(socket, results: Map.put(socket.assigns.results, key, result))
  end
end
