defmodule EliaWeb.TerminalLive do
  @moduledoc """
  A chat's terminal page (TERM-19): the terminal itself, drawn by xterm.js from
  the channel's byte stream (TERM-12), and the controls around it — what to run
  (TERM-20), Stop (TERM-3), and the font size a phone may want (TERM-22).

  The page holds no bytes of its own: it shows how the session is doing
  (TERM-23) and hands the terminal to the hook. A session that has ended keeps
  its last screen (TERM-3, TERM-4), so the page still shows what the app was
  showing, with what ended it.
  """
  use EliaWeb, :live_view

  alias Elia.{Agent, Deploy, Store, Terminal}

  @font_sizes [10, 12, 13, 16, 20]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if Store.valid_id?(id),
      do: mount_chat(id, socket),
      else: {:ok, push_navigate(socket, to: ~p"/")}
  end

  defp mount_chat(id, socket) do
    # The same session the chat page uses, so the chat's jail setting and
    # workspace are the ones this page starts a terminal with (TERM-7, TERM-2).
    {:ok, _pid} = Agent.ensure_started(id)
    if connected?(socket), do: Terminal.subscribe_status(id)

    snapshot = Agent.snapshot(id)

    socket =
      assign(socket,
        session_id: id,
        page_title: Store.chat_title(id),
        project: snapshot.project,
        # What the workspace *is*, without creating one just by opening a page
        # (DEPLOY): the worktree is forked when a terminal actually starts.
        workspace: Deploy.existing_workspace(snapshot.project, id),
        jail: snapshot.settings.jail,
        jail_available: Elia.Shell.jailed?(),
        tmux: Terminal.available?(),
        tmux_message: Terminal.unavailable_message(),
        font_sizes: @font_sizes,
        font_size: 13,
        # TERM-20: what an empty command field runs (TERM-5), said on the page.
        default_command: Enum.join(Terminal.command_argv(), " "),
        command_field: "",
        form: to_form(%{"command" => ""}, as: :terminal),
        status: nil,
        error: nil
      )

    {:ok, refresh(socket)}
  end

  # TERM-20, TERM-25: start a terminal — the default command (TERM-5) or the one
  # the user typed.
  @impl true
  def handle_event("start", %{"terminal" => %{"command" => command}}, socket) do
    command = String.trim(command || "")

    case Terminal.start(socket.assigns.session_id,
           command: if(command == "", do: nil, else: command),
           workspace: Deploy.workspace(socket.assigns.project, socket.assigns.session_id),
           jail: socket.assigns.jail
         ) do
      {:ok, _pid} -> {:noreply, refresh(socket, command)}
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  # TERM-3: the user's Stop.
  def handle_event("stop", _params, socket) do
    case Terminal.stop(socket.assigns.session_id) do
      {:ok, status} -> {:noreply, assign(socket, status: status, error: nil)}
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  # TERM-22: a phone can trade columns for legibility. The hook owns the
  # terminal, so the size goes to it as an event rather than through a
  # re-render, which the terminal's own element is exempt from anyway.
  def handle_event("font_size", %{"font_size" => size}, socket) do
    size = parse_size(size)

    {:noreply,
     socket
     |> assign(font_size: size)
     |> push_event("font_size", %{size: size})}
  end

  # TERM-23: the session says how it is doing; the page shows it.
  @impl true
  def handle_info({:terminal_status, id, status}, %{assigns: %{session_id: id}} = socket) do
    {:noreply, assign(socket, status: status)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket, command_field \\ nil) do
    status =
      case Terminal.status(socket.assigns.session_id) do
        {:ok, status} -> status
        :error -> nil
      end

    assign(socket,
      status: status,
      command_field: command_field || socket.assigns.command_field,
      form: to_form(%{"command" => command_field || socket.assigns.command_field}, as: :terminal),
      error: nil
    )
  end

  defp parse_size(size) do
    case Integer.parse(to_string(size)) do
      {size, ""} -> if size in @font_sizes, do: size, else: 13
      _ -> 13
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex min-h-0 flex-1 flex-col" style="min-height: 0">
        <div class="border-b border-base-300 px-4 py-3 sm:px-6">
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
            <h1 class="text-lg font-semibold tracking-tight">Terminal</h1>
            <span class="truncate text-sm text-base-content/60">{@page_title}</span>
            <.link
              navigate={~p"/c/#{@session_id}"}
              id="terminal-chat-link"
              class="ml-auto text-xs text-base-content/60 transition hover:text-base-content"
            >
              Back to the chat
            </.link>
          </div>
          <p id="terminal-workspace" class="mt-1 truncate text-xs text-base-content/50">
            Runs in {(@status && @status.workspace) || @workspace}
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2 border-b border-base-300 px-4 py-2 sm:px-6">
          <span :if={@status} id="terminal-status" class="text-xs">
            <span class={[
              "rounded px-1.5 py-0.5",
              @status.running && "bg-success/15 text-success",
              !@status.running && "bg-base-200 text-base-content/60"
            ]}>
              {status_text(@status)}
            </span>
          </span>
          <span :if={!@tmux} id="terminal-unavailable" class="text-xs text-warning">
            {@tmux_message}
          </span>
          <%!-- TERM-9, ISOL-17: whether the jail is on belongs where the terminal
          is, like it is on the chat page — and a host with no jail at all is a
          different sentence from a chat that turned it off. --%>
          <span
            :if={@tmux and !@jail_available}
            id="terminal-no-jail"
            class="text-xs text-base-content/50"
          >
            This host has no jail, so the terminal runs unjailed (ISOL-12).
          </span>
          <span
            :if={@tmux and @jail_available and !@jail}
            id="terminal-jail-warning"
            class="text-xs text-warning"
          >
            Not jailed: this terminal can read the settings database and your credentials.
          </span>

          <.form
            :if={@tmux}
            for={@form}
            id="terminal-form"
            phx-submit="start"
            class="flex flex-1 flex-wrap items-center gap-2"
          >
            <.input
              field={@form[:command]}
              type="text"
              id="terminal-command"
              aria-label="Command to run"
              placeholder="Command to run (leave empty for your shell)"
              disabled={@status && @status.running}
              class="input input-sm w-full font-mono sm:w-96"
            />
            <button
              type="submit"
              id="terminal-start"
              disabled={@status && @status.running}
              class="btn btn-sm btn-primary disabled:opacity-40"
            >
              <.icon name="hero-play" class="size-4" />
              {if @status, do: "Start again", else: "Start"}
            </button>
            <button
              :if={@status && @status.running}
              type="button"
              id="terminal-stop"
              phx-click="stop"
              class="btn btn-sm"
            >
              <.icon name="hero-stop" class="size-4" /> Stop
            </button>
          </.form>
          <%!-- TERM-22: its own form, not one nested in the one above. --%>
          <.form
            :if={@tmux}
            for={to_form(%{"font_size" => @font_size}, as: :size)}
            id="terminal-font-form"
            phx-change="font_size"
            class="flex items-center gap-1.5"
          >
            <span class="text-xs text-base-content/60">Font</span>
            <select id="terminal-font-size" name="font_size" class="select select-xs">
              <option :for={size <- @font_sizes} value={size} selected={size == @font_size}>
                {size}
              </option>
            </select>
          </.form>
          <%!-- TERM-20: what an empty field would run, said rather than left to
          be guessed. --%>
          <p :if={@tmux} id="terminal-default-command" class="text-xs text-base-content/50">
            Empty runs {@default_command}
          </p>
        </div>

        <div
          :if={@error}
          id="terminal-error"
          class="border-b border-base-300 px-4 py-2 text-xs text-error sm:px-6"
        >
          {@error}
        </div>

        <%!-- TERM-21, TERM-22: the terminal fills what is left of the page, at
        the page's own width rather than the chat column's. The hook owns this
        element and its contents (`phx-update="ignore"`), so the height it is
        given is markup of its own, not a class a stale stylesheet might not
        have (HOT-8). --%>
        <div
          :if={@status}
          id="terminal-pane"
          class="flex-1 bg-base-300/30 p-2"
          style="min-height: 0"
        >
          <div
            id="terminal"
            phx-hook="Terminal"
            phx-update="ignore"
            data-chat-id={@session_id}
            data-font-size={@font_size}
            style="height: 100%; min-height: 0"
          >
          </div>
        </div>

        <div
          :if={!@status}
          id="terminal-empty"
          class="flex flex-1 items-center justify-center px-6 text-center text-sm text-base-content/50"
        >
          <p :if={@tmux}>
            Start a terminal to run a shell, or any app that has to keep running while
            you watch it, in this chat's workspace.
          </p>
          <p :if={!@tmux}>{@tmux_message}</p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # TERM-23: what ended a session, in the words the user needs — never a blank
  # terminal that looks broken.
  defp status_text(%{running: true}), do: "running"

  defp status_text(%{ending: true, ended: :stopped}), do: "stopping"
  defp status_text(%{ending: true}), do: "ending"

  defp status_text(%{ended: :exited, exit_status: status}) when is_integer(status),
    do: "exited with status #{status}"

  defp status_text(%{ended: :exited}), do: "the command exited"
  defp status_text(%{ended: :stopped}), do: "stopped"

  defp status_text(%{ended: :crashed, error: error}) when is_binary(error) and error != "",
    do: "the terminal ended: #{error}"

  defp status_text(%{ended: :crashed}), do: "the terminal ended unexpectedly"
  defp status_text(_status), do: "not running"
end
