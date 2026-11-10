defmodule EliaWeb.TerminalChannel do
  @moduledoc """
  The stream between a chat's terminal and one browser client (TERM-12).

  Output goes out as `"output"` and, once per join, as `"screen"`: the screen
  the terminal has now, which is what a reconnect shows instead of an empty
  terminal (TERM-14). Both carry bytes base64-encoded in JSON — a terminal's
  bytes are not text, and JSON is what a channel speaks by default.

  Coming back the same way: `"input"` is what the user typed, byte for byte
  (TERM-13), and `"resize"` is the box their browser can draw (TERM-15). A
  client that falls too far behind is told `"overflow"` and dropped, and joins
  again for a fresh screen rather than making the session hold its backlog
  (TERM-17).
  """

  use Phoenix.Channel

  alias Elia.Terminal

  @impl true
  def join("terminal:" <> chat_id, _payload, socket) do
    with {:ok, session} <- Terminal.fetch(chat_id),
         {:ok, status} <- Terminal.status(chat_id) do
      # Subscribing sends the screen before any output (TERM-14).
      :ok = Terminal.subscribe(chat_id, self())
      ref = Process.monitor(session)

      {:ok, status, assign(socket, chat_id: chat_id, session: session, monitor: ref)}
    else
      :error ->
        {:error, %{reason: "no_terminal", message: "This chat has no terminal."}}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    case Base.decode64(data) do
      {:ok, bytes} ->
        # A terminal that has ended says so itself (TERM-3); the client needs no
        # error for a keystroke into it, and gets the status either way.
        _ = Terminal.input(socket.assigns.chat_id, bytes)
        {:reply, :ok, socket}

      :error ->
        {:reply, {:error, %{message: "input must be base64-encoded bytes"}}, socket}
    end
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    _ = Terminal.resize(socket.assigns.chat_id, cols, rows)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:terminal_screen, data}, socket) do
    push(socket, "screen", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  # TERM-17: output that the tab in front of this channel can't keep up with is
  # not queued for it. What queues up is the transport — this channel hands each
  # push straight to it — so that is where falling behind shows, and a client
  # that has fallen too far behind is told and dropped rather than the session
  # holding anything for it: it joins again and is sent the screen as it is
  # (TERM-14).
  def handle_info({:terminal_output, data}, socket) do
    if too_far_behind?(socket) do
      overflow(socket)
    else
      push(socket, "output", %{data: Base.encode64(data)})
      {:noreply, socket}
    end
  end

  # TERM-23: how the terminal is doing — running, or ended and how.
  def handle_info({:terminal_status, status}, socket) do
    push(socket, "status", status)
    {:noreply, socket}
  end

  # TERM-17: too far behind to be caught up; it rejoins for a fresh screen.
  # This is the session's own check on a subscriber that has stopped taking
  # anything at all (a wedged channel); the transport's backlog is this
  # channel's (see `handle_info/2` above), and either one ends the same way.
  def handle_info({:terminal_overflow, :dropped}, socket), do: overflow(socket)

  # The session went away — the chat was deleted, or its terminal was replaced.
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{assigns: assigns} = socket)
      when ref == assigns.monitor and pid == assigns.session do
    push(socket, "status", %{running: false, ending: false, ended: :stopped, exit_status: nil})
    {:stop, :normal, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp overflow(socket) do
    push(socket, "overflow", %{message: "The terminal outran this tab; reloading its screen."})
    {:stop, :normal, socket}
  end

  defp too_far_behind?(socket) do
    case Process.info(socket.transport_pid, :message_queue_len) do
      {:message_queue_len, length} -> length > Terminal.config(:max_pending)
      nil -> true
    end
  end
end
