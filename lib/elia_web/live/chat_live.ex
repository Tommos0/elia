defmodule EliaWeb.ChatLive do
  use EliaWeb, :live_view

  alias Elia.Agent
  alias Elia.LLM.Message

  @impl true
  def mount(_params, _session, %{assigns: %{live_action: :new}} = socket) do
    {:ok, push_navigate(socket, to: ~p"/c/#{Agent.new_id()}")}
  end

  def mount(%{"id" => id}, _session, socket) do
    if Elia.Store.valid_id?(id),
      do: mount_chat(id, socket),
      else: {:ok, push_navigate(socket, to: ~p"/")}
  end

  defp mount_chat(id, socket) do
    {:ok, _pid} = Agent.ensure_started(id)
    if connected?(socket), do: Agent.subscribe(id)
    snapshot = Agent.snapshot(id)

    socket =
      socket
      |> assign(
        session_id: id,
        status: snapshot.status,
        tool_status: snapshot.tool_status,
        draft: "",
        draft_reasoning: "",
        form: to_form(%{"text" => ""}, as: :chat),
        page_title: Elia.Store.title(snapshot.messages),
        chats: Elia.Store.list(30)
      )
      |> load_messages(snapshot.messages)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex h-full">
        <aside class="hidden w-64 shrink-0 flex-col border-r border-base-300 bg-base-200/30 lg:flex">
          <p class="px-4 pt-4 pb-2 text-xs font-medium uppercase tracking-wider text-base-content/50">
            Chats
          </p>
          <nav id="chat-list" class="flex-1 space-y-0.5 overflow-y-auto px-2 pb-4">
            <.link
              :for={chat <- @chats}
              navigate={~p"/c/#{chat.id}"}
              id={"chat-link-#{chat.id}"}
              class={[
                "block truncate rounded-lg px-3 py-2 text-sm transition",
                chat.id == @session_id && "bg-base-300 font-medium",
                chat.id != @session_id &&
                  "text-base-content/70 hover:bg-base-200 hover:text-base-content"
              ]}
            >
              {chat.title}
            </.link>
            <p :if={@chats == []} class="px-3 py-2 text-sm text-base-content/50">No chats yet</p>
          </nav>
        </aside>
        <div class="flex min-w-0 flex-1 flex-col">
          <div id="transcript-scroll" class="flex-1 overflow-y-auto" phx-hook=".ScrollBottom">
            <div class="mx-auto max-w-3xl space-y-5 px-4 py-8 sm:px-6">
              <div id="transcript" phx-update="stream" class="space-y-5">
                <div id="transcript-empty" class="hidden only:block py-24 text-center">
                  <p class="text-2xl font-semibold tracking-tight">What should we work on?</p>
                  <p class="mt-2 text-sm text-base-content/60">
                    Elia can run shell commands on this machine. You approve every command.
                  </p>
                </div>
                <div :for={{dom_id, item} <- @streams.items} id={dom_id}>
                  <.item item={item} />
                </div>
              </div>

              <div :if={@draft_reasoning != ""} id="draft-reasoning">
                <.item item={%{kind: :reasoning, text: @draft_reasoning}} />
              </div>
              <div :if={@draft != ""} id="draft">
                <.item item={%{kind: :assistant, text: @draft}} />
              </div>
              <div
                :if={@status == :running and @draft == ""}
                id="thinking-indicator"
                class="flex items-center gap-2 text-sm text-base-content/50"
              >
                <span class="flex gap-1">
                  <span class="size-1.5 animate-bounce rounded-full bg-current [animation-delay:-0.3s]" />
                  <span class="size-1.5 animate-bounce rounded-full bg-current [animation-delay:-0.15s]" />
                  <span class="size-1.5 animate-bounce rounded-full bg-current" />
                </span>
                Working
              </div>
            </div>
          </div>

          <div class="border-t border-base-300 bg-base-100">
            <.form
              for={@form}
              id="chat-form"
              phx-submit="send"
              class="mx-auto flex max-w-3xl items-end gap-2 px-4 py-4 sm:px-6"
            >
              <textarea
                id="chat-input"
                name={@form[:text].name}
                rows="1"
                phx-hook=".SubmitOnEnter"
                placeholder={if @status == :idle, do: "Message Elia…", else: "Elia is working…"}
                disabled={@status != :idle}
                class="max-h-48 min-h-11 flex-1 resize-none rounded-xl border border-base-300 bg-base-200/50 px-4 py-2.5 text-sm outline-none transition focus:border-primary focus:bg-base-100 disabled:opacity-60"
              >{@form[:text].value}</textarea>
              <button
                :if={@status == :idle}
                type="submit"
                id="send-button"
                class="grid size-11 place-items-center rounded-xl bg-primary text-primary-content transition hover:brightness-110 active:scale-95"
              >
                <.icon name="hero-arrow-up" class="size-5" />
              </button>
              <button
                :if={@status != :idle}
                type="button"
                id="stop-button"
                phx-click="stop"
                class="grid size-11 place-items-center rounded-xl bg-base-300 transition hover:bg-error hover:text-error-content active:scale-95"
                title="Stop"
              >
                <.icon name="hero-stop-solid" class="size-5" />
              </button>
            </.form>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
        export default {
          mounted() {
            const resize = () => {
              this.el.style.height = "auto"
              this.el.style.height = this.el.scrollHeight + "px"
            }
            this.el.addEventListener("input", resize)
            this.el.addEventListener("keydown", e => {
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                e.preventDefault()
                this.el.form.requestSubmit()
              }
            })
            this.handleEvent("chat:clear", () => { this.el.value = ""; resize() })
          },
          updated() { if (!this.el.disabled) this.el.focus() }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
        export default {
          mounted() {
            this.stick = true
            this.el.addEventListener("scroll", () => {
              this.stick = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
            })
            new MutationObserver(() => {
              if (this.stick) this.el.scrollTop = this.el.scrollHeight
            }).observe(this.el, {childList: true, subtree: true, characterData: true})
            this.el.scrollTop = this.el.scrollHeight
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :item, :map, required: true

  defp item(%{item: %{kind: :user}} = assigns) do
    ~H"""
    <div class="flex justify-end">
      <div class="max-w-[85%] whitespace-pre-wrap rounded-2xl rounded-br-md bg-primary px-4 py-2.5 text-sm text-primary-content">
        {@item.text}
      </div>
    </div>
    """
  end

  defp item(%{item: %{kind: :assistant}} = assigns) do
    ~H"""
    <div class="whitespace-pre-wrap text-sm leading-relaxed">{@item.text}</div>
    """
  end

  defp item(%{item: %{kind: :reasoning}} = assigns) do
    ~H"""
    <div class="flex gap-2 text-xs italic text-base-content/50">
      <.icon name="hero-light-bulb" class="mt-px size-3.5 shrink-0" />
      <span class="whitespace-pre-wrap">{@item.text}</span>
    </div>
    """
  end

  defp item(%{item: %{kind: :tool}} = assigns) do
    ~H"""
    <div class={[
      "overflow-hidden rounded-xl border text-sm transition",
      @item.status == :awaiting_approval && "border-warning/60 shadow-sm shadow-warning/10",
      @item.status != :awaiting_approval && "border-base-300"
    ]}>
      <div class="flex items-center justify-between gap-3 bg-base-200/60 px-3 py-2">
        <div class="flex min-w-0 items-center gap-2">
          <.icon name={tool_icon(@item.name)} class="size-4 shrink-0 text-base-content/60" />
          <span class="font-medium">{@item.name}</span>
        </div>
        <.tool_badge status={@item.status} is_error={@item.is_error} />
      </div>
      <pre class="overflow-x-auto px-3 py-2 font-mono text-xs leading-relaxed"><span :if={@item.name == "shell"} class="select-none text-base-content/40">$ </span>{tool_summary(@item)}</pre>
      <details
        :if={detail = tool_detail(@item)}
        open={@item.status == :awaiting_approval}
        class="group/detail border-t border-base-300"
      >
        <summary class="flex cursor-pointer list-none items-center gap-1 px-3 py-1.5 text-xs text-base-content/60 hover:text-base-content">
          <.icon name="hero-chevron-right" class="size-3 transition group-open/detail:rotate-90" />
          Changes
        </summary>
        <div class="max-h-96 overflow-auto font-mono text-xs leading-relaxed">
          <pre
            :for={{kind, text} <- detail}
            class={[
              "whitespace-pre-wrap px-3 py-1.5",
              kind == :removed && "bg-error/10 text-error",
              kind == :added && "bg-success/10",
              kind == :content && "bg-base-200/40"
            ]}
          >{text}</pre>
        </div>
      </details>
      <div
        :if={@item.status == :awaiting_approval && guard_note(@item)}
        id={"guarded-#{@item.call_id}"}
        class="flex items-start gap-2 border-t border-warning/40 bg-warning/10 px-3 py-2 text-xs text-warning"
      >
        <.icon name="hero-shield-exclamation" class="mt-px size-4 shrink-0" />
        <span>{guard_note(@item)}</span>
      </div>
      <div
        :if={@item.status == :awaiting_approval}
        class="flex items-center justify-end gap-2 border-t border-base-300 px-3 py-2"
      >
        <span class="mr-auto text-xs text-base-content/60">Allow this?</span>
        <button
          id={"deny-#{@item.call_id}"}
          phx-click="deny"
          phx-value-id={@item.call_id}
          class="rounded-lg px-3 py-1 text-xs font-medium transition hover:bg-base-300"
        >
          Deny
        </button>
        <button
          id={"approve-#{@item.call_id}"}
          phx-click="approve"
          phx-value-id={@item.call_id}
          class="rounded-lg bg-primary px-3 py-1 text-xs font-medium text-primary-content transition hover:brightness-110 active:scale-95"
        >
          Approve
        </button>
      </div>
      <details :if={@item.output} class="group border-t border-base-300">
        <summary class="flex cursor-pointer list-none items-center gap-1 px-3 py-1.5 text-xs text-base-content/60 hover:text-base-content">
          <.icon name="hero-chevron-right" class="size-3 transition group-open:rotate-90" /> Output
        </summary>
        <pre class={[
          "max-h-96 overflow-auto bg-base-200/40 px-3 py-2 font-mono text-xs leading-relaxed",
          @item.is_error && "text-error"
        ]}>{@item.output}</pre>
      </details>
    </div>
    """
  end

  defp item(%{item: %{kind: kind}} = assigns) when kind in [:notice, :error] do
    ~H"""
    <div class={[
      "flex items-center gap-2 rounded-lg px-3 py-2 text-xs",
      @item.kind == :error && "bg-error/10 text-error",
      @item.kind == :notice && "bg-base-200 text-base-content/70"
    ]}>
      <.icon
        name={
          if @item.kind == :error, do: "hero-exclamation-triangle", else: "hero-information-circle"
        }
        class="size-4 shrink-0"
      />
      {@item.text}
    </div>
    """
  end

  attr :status, :atom, required: true
  attr :is_error, :boolean, default: false

  defp tool_badge(assigns) do
    {label, class} =
      case {assigns.status, assigns.is_error} do
        {:awaiting_approval, _} -> {"Needs approval", "bg-warning/15 text-warning"}
        {:approved, _} -> {"Approved", "bg-info/15 text-info"}
        {:running, _} -> {"Running", "bg-info/15 text-info animate-pulse"}
        {:done, true} -> {"Failed", "bg-error/15 text-error"}
        {:done, false} -> {"Done", "bg-success/15 text-success"}
        _ -> {"Pending", "bg-base-300 text-base-content/60"}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={["rounded-full px-2 py-0.5 text-[11px] font-medium", @class]}>{@label}</span>
    """
  end

  defp tool_icon("shell"), do: "hero-command-line"
  defp tool_icon(name) when name in ~w(read_file write_file edit_file), do: "hero-document-text"
  defp tool_icon(_name), do: "hero-wrench-screwdriver"

  defp tool_summary(%{name: "shell", input: %{"command" => command}}), do: command
  defp tool_summary(%{input: %{"path" => path}}), do: path
  defp tool_summary(%{input: input}) when input == %{}, do: "(no input)"
  defp tool_summary(%{input: input}), do: Jason.encode!(input, pretty: true)

  defp tool_detail(%{name: "write_file", input: %{"content" => content}}), do: [content: content]

  defp tool_detail(%{name: "edit_file", input: %{"old_string" => old, "new_string" => new}}) do
    [removed: old, added: new]
  end

  defp tool_detail(_item), do: nil

  # Flags approvals that touch the harness's own guardrails (see Elia.Guarded).
  defp guard_note(%{name: name, input: %{"path" => path}})
       when name in ["write_file", "edit_file"] and is_binary(path) do
    if Elia.Guarded.guarded?(path),
      do:
        "Guarded file: this changes the harness's guardrails. " <>
          "It won't be auto-loaded; it only takes effect after hot_reload."
  end

  defp guard_note(%{name: "hot_reload"}) do
    case Elia.Guarded.changed() do
      [] -> nil
      files -> "This loads changes to guarded files: " <> Enum.join(files, ", ")
    end
  end

  defp guard_note(_item), do: nil

  ## Events

  @impl true
  def handle_event("send", %{"chat" => %{"text" => text}}, socket) do
    text = String.trim(text)

    if text != "" and Agent.send_message(socket.assigns.session_id, text) == :ok do
      {:noreply, push_event(socket, "chat:clear", %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("approve", %{"id" => call_id}, socket) do
    Agent.approve(socket.assigns.session_id, call_id)
    {:noreply, socket}
  end

  def handle_event("deny", %{"id" => call_id}, socket) do
    Agent.deny(socket.assigns.session_id, call_id)
    {:noreply, socket}
  end

  def handle_event("stop", _params, socket) do
    Agent.stop(socket.assigns.session_id)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent, _id, event}, socket), do: {:noreply, apply_event(event, socket)}

  defp apply_event({:message, %Message{} = message}, socket) do
    socket =
      if message.role == :assistant,
        do: assign(socket, draft: "", draft_reasoning: ""),
        else: socket

    insert_message(socket, message)
  end

  defp apply_event({:delta, :text, text}, socket) do
    # Progress notes before a text block are superseded by the answer.
    assign(socket, draft: socket.assigns.draft <> text)
  end

  defp apply_event({:delta, :reasoning, text}, socket) do
    assign(socket, draft_reasoning: socket.assigns.draft_reasoning <> text)
  end

  defp apply_event({:status, status}, socket) do
    socket = assign(socket, status: status)

    socket =
      if status == :idle,
        do:
          assign(socket,
            chats: Elia.Store.list(30),
            page_title: Elia.Store.title(Elia.Store.load(socket.assigns.session_id))
          ),
        else: socket

    if status == :idle, do: assign(socket, draft: "", draft_reasoning: ""), else: socket
  end

  defp apply_event({:tool_status, call_id, status}, socket) do
    socket = assign(socket, tool_status: Map.put(socket.assigns.tool_status, call_id, status))

    case socket.assigns.calls do
      %{^call_id => call} -> put_call(socket, %{call | status: status})
      _ -> socket
    end
  end

  defp apply_event({kind, text}, socket) when kind in [:notice, :error] do
    item = %{id: "#{kind}-#{System.unique_integer([:positive])}", kind: kind, text: text}
    stream_insert(socket, :items, item)
  end

  defp apply_event({:reset, messages}, socket), do: load_messages(socket, messages)

  ## Transcript items

  defp load_messages(socket, messages) do
    socket = socket |> assign(calls: %{}, message_count: 0) |> stream(:items, [], reset: true)
    Enum.reduce(messages, socket, &insert_message(&2, &1))
  end

  defp insert_message(socket, %Message{role: :user, meta: %{harness: true}} = message) do
    index = socket.assigns.message_count

    socket
    |> assign(message_count: index + 1)
    |> stream_insert(:items, %{
      id: "m#{index}",
      kind: :notice,
      text: Message.text_content(message)
    })
  end

  defp insert_message(socket, %Message{role: :user} = message) do
    index = socket.assigns.message_count

    socket
    |> assign(message_count: index + 1)
    |> stream_insert(:items, %{id: "m#{index}", kind: :user, text: Message.text_content(message)})
  end

  defp insert_message(socket, %Message{role: :tool, content: results}) do
    socket = assign(socket, message_count: socket.assigns.message_count + 1)

    Enum.reduce(results, socket, fn result, socket ->
      case socket.assigns.calls do
        %{} = calls when is_map_key(calls, result.tool_call_id) ->
          call = calls[result.tool_call_id]

          put_call(socket, %{
            call
            | output: result.content,
              is_error: result.is_error,
              status: :done
          })

        _ ->
          socket
      end
    end)
  end

  defp insert_message(socket, %Message{role: :assistant, content: content}) do
    index = socket.assigns.message_count
    socket = assign(socket, message_count: index + 1)

    content
    |> Enum.with_index()
    |> Enum.reduce(socket, fn
      {%{type: :text, text: text}, i}, socket when text != "" ->
        stream_insert(socket, :items, %{id: "m#{index}-#{i}", kind: :assistant, text: text})

      {%{type: :reasoning, text: text}, i}, socket when text != "" ->
        stream_insert(socket, :items, %{id: "m#{index}-#{i}", kind: :reasoning, text: text})

      {%{type: :tool_call} = call, _i}, socket ->
        put_call(socket, %{
          id: "call-#{call.id}",
          kind: :tool,
          call_id: call.id,
          name: call.name,
          input: call.input,
          status: Map.get(socket.assigns.tool_status, call.id, :pending),
          output: nil,
          is_error: false
        })

      _other, socket ->
        socket
    end)
  end

  defp put_call(socket, call) do
    socket
    |> assign(calls: Map.put(socket.assigns.calls, call.call_id, call))
    |> stream_insert(:items, call)
  end
end
