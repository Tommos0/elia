defmodule EliaWeb.SettingsLive do
  use EliaWeb, :live_view

  alias Elia.{Deploy, LLM}

  @impl true
  def mount(_params, _session, socket) do
    providers = LLM.providers()

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
        # CONF-19: the deploy state (DEPLOY-14), and "reload" | "restart" while
        # a deploy runs
        deployment: Deploy.status(),
        deploying: nil
      )
      |> assign(forms: Map.new(providers, &{&1.key, empty_form(&1.key)}))
      |> refresh_keys()

    {:ok, if(connected?(socket), do: load_balances(socket), else: socket)}
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
                <.key_status key={@keys[info.key]} provider={info.key} />
              </div>

              <.form
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
                  <.balance_line
                    :if={@keys[info.key]}
                    provider={info.key}
                    supported={LLM.balance_supported?(info.key)}
                    balance={@balances[info.key]}
                  />
                  <span :if={!@keys[info.key]} id={"balance-#{info.key}"}>
                    Add a key to see credits.
                  </span>
                  <button
                    :if={@keys[info.key] && LLM.balance_supported?(info.key)}
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
    </Layouts.app>
    """
  end

  attr :key, :any, required: true
  attr :provider, :string, required: true

  defp key_status(assigns) do
    ~H"""
    <span
      id={"key-status-#{@provider}"}
      class={[
        "flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium",
        match?({:stored, _}, @key) && "bg-success/15 text-success",
        match?({:env, _}, @key) && "bg-info/15 text-info",
        @key == nil && "bg-base-300 text-base-content/60"
      ]}
    >
      <%= case @key do %>
        <% {:stored, key} -> %>
          <.icon name="hero-key" class="size-3.5" /> Saved
          <span class="font-mono opacity-70">{mask(key)}</span>
        <% {:env, key} -> %>
          <.icon name="hero-command-line" class="size-3.5" /> From environment
          <span class="font-mono opacity-70">{mask(key)}</span>
        <% nil -> %>
          Not set
      <% end %>
    </span>
    """
  end

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
  defp deploy_ready?({:ok, _commits}), do: true
  defp deploy_ready?({:error, _reason}), do: false

  # CONF-19: what the deployment section says about the live tree.
  defp deploy_status({:ok, 0}), do: "live is up to date with master: nothing to deploy."
  defp deploy_status({:ok, 1}), do: "1 commit on master is not deployed yet."
  defp deploy_status({:ok, commits}), do: "#{commits} commits on master are not deployed yet."
  defp deploy_status({:error, reason}), do: reason

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

  # CONF-19, CONF-20, DEPLOY-6, DEPLOY-7: deploy in the background, so the page
  # stays responsive while the tests and the deploy run.
  def handle_event("deploy", %{"mode" => mode}, socket) when mode in ~w(reload restart) do
    if socket.assigns.deploying do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(deploying: mode)
       |> start_async({:deploy, mode}, fn -> deploy(mode) end)}
    end
  end

  defp deploy("reload"), do: Deploy.hot_reload()
  defp deploy("restart"), do: Deploy.restart()

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

  # CONF-20, DEPLOY-5..DEPLOY-7: report what the deploy did, and how the live
  # tree stands now. `start_async` wraps the result in `{:ok, result}`.
  def handle_async({:deploy, _mode}, result, socket) do
    socket = assign(socket, deploying: nil, deployment: Deploy.status())

    {:noreply,
     case result do
       {:ok, {:ok, message}} ->
         put_flash(socket, :info, message)

       {:ok, {:tests_failed, output}} ->
         put_flash(
           socket,
           :error,
           "Tests failed; nothing was merged or loaded.\n\n" <>
             Elia.Shell.truncate(output, 4_000)
         )

       {:ok, {:error, reason}} ->
         put_flash(socket, :error, reason)

       {:exit, reason} ->
         put_flash(socket, :error, "The deploy failed: #{Exception.format_exit(reason)}")
     end}
  end

  defp put_result(socket, key, result) do
    assign(socket, results: Map.put(socket.assigns.results, key, result))
  end
end
