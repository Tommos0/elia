defmodule Elia.Push.Viewers do
  @moduledoc """
  Which chats have a page in front of the user right now (PUSH-13, PUSH-14).

  A chat page reports itself here when it mounts and whenever its visibility
  changes (`EliaWeb.ChatLive`), and is forgotten when it goes away, because the
  process is monitored. That is what keeps a notification from arriving for the
  chat the user is already reading — while a page that is hidden or in a
  background tab does not count as reading it (PUSH-13).
  """

  use GenServer

  alias __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "PUSH-14: the page `pid` reports whether it is visible, for `chat_id`."
  @spec set(binary(), pid(), boolean()) :: :ok
  def set(chat_id, pid, visible?) when is_binary(chat_id) and is_boolean(visible?) do
    GenServer.cast(Viewers, {:set, chat_id, pid, visible?})
  end

  @doc "PUSH-13: whether any connected page for this chat is visible."
  @spec visible?(binary()) :: boolean()
  def visible?(chat_id), do: GenServer.call(Viewers, {:visible?, chat_id})

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:set, chat_id, pid, visible?}, pages) do
    unless Map.has_key?(pages, pid), do: Process.monitor(pid)
    {:noreply, Map.put(pages, pid, %{chat: chat_id, visible: visible?})}
  end

  @impl true
  def handle_call({:visible?, chat_id}, _from, pages) do
    visible? = Enum.any?(pages, fn {_pid, page} -> page.chat == chat_id and page.visible end)
    {:reply, visible?, pages}
  end

  @impl true
  def handle_info({:DOWN, _reference, :process, pid, _reason}, pages) do
    {:noreply, Map.delete(pages, pid)}
  end

  def handle_info(_message, pages), do: {:noreply, pages}
end
