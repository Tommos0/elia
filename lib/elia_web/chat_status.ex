defmodule EliaWeb.ChatStatus do
  @moduledoc """
  The one status indicator a listed chat shows (UI-46, UI-47, UI-58, UI-59,
  UI-72): the chat page's sidebar, the dashboard (DASH-3, DASH-5, DASH-7) and a
  task chat's own header (UI-48) all read it, so a chat shows one status however
  it is drawn. A sub-task chat has no status of its own to add: its status is
  its chat's (STORE-17, SUBTASK-34), which is why there is nothing here about
  tasks — the parent's card that once read a task status is retired (UI-44,
  UI-50).

  `status/2` answers for a listed chat (`Elia.Store.list/1`) together with what
  the registry says about it (`Elia.Agent.awaiting_approval/0`, `paused/0`,
  `running/0`, SESS-19) and the record a restart left behind (STORE-31). A chat
  marked done (DONE-2, STORE-35) reads `done` in place of `idle`. `for_chat/2`
  is the same answer for a caller that holds the markers a page keeps, which is
  what the row and the header use.
  """
  use EliaWeb, :html

  @doc """
  UI-46, UI-47, UI-58, UI-59, UI-72, UI-76: the status a listed chat shows.
  `state` is a map with `:awaiting`, `:input`, `:paused`, `:running` and
  `:interrupted`.
  """
  @spec status(map(), map()) :: String.t()
  def status(chat, state) do
    cond do
      # UI-47, UI-58: waiting for the user comes first, so a chat that needs
      # them is never shown as idle.
      Map.get(state, :awaiting, false) -> "awaiting_approval"
      # UI-76: waiting for an answer (ASK-3) is waiting for the user too.
      Map.get(state, :input, false) -> "awaiting_input"
      Map.get(state, :paused, false) -> "paused"
      # UI-72: a turn a restart cut short (STORE-31).
      Map.get(state, :interrupted, false) -> "interrupted"
      # UI-59: an ordinary chat's loop activity.
      Map.get(state, :running, false) -> "working"
      # DONE-2, UI-80: a chat marked done shows it in place of idle.
      Map.get(chat, :done, false) -> "done"
      true -> "idle"
    end
  end

  @doc """
  UI-46, UI-48, SUBTASK-34: the status of one chat, where the caller
  holds the markers a page keeps about every chat with a session rather than the
  booleans `status/2` takes: `marks` is `EliaWeb.ChatList`'s state or a map of
  the same shape, with a list of chat ids under `:awaiting`, `:input`, `:paused`
  and `:running`, and the chats a restart cut short under `:interrupted`
  (UI-72, STORE-31). The row (UI-46) and a task chat's header (UI-48) both read
  this one — the parent's card that did is retired (UI-44).
  """
  @spec for_chat(map(), map()) :: String.t()
  def for_chat(chat, marks) do
    status(chat, %{
      awaiting: marked?(marks, :awaiting, chat.id),
      input: marked?(marks, :input, chat.id),
      paused: marked?(marks, :paused, chat.id),
      running: marked?(marks, :running, chat.id),
      interrupted: marked?(marks, :interrupted, chat.id)
    })
  end

  defp marked?(marks, key, id), do: id in Map.get(marks, key, [])

  attr :id, :string, required: true
  attr :status, :string, required: true

  @doc "UI-46, UI-47, UI-58, UI-59, UI-72, UI-76: a chat's status as an icon."
  def status_icon(assigns) do
    {icon, class} = icon_spec(assigns.status)
    assigns = assign(assigns, icon: icon, class: class)

    ~H"""
    <span
      id={@id}
      data-status={@status}
      title={title(@status)}
      class="inline-flex shrink-0 items-center"
    >
      <.icon :if={@icon} name={@icon} class={["size-3.5", @class]} />
      <span :if={!@icon} class={["block size-1.5 rounded-full bg-current", @class]}></span>
    </span>
    """
  end

  @doc "UI-46, UI-59: the icon and colour for a status."
  def icon_spec("working"), do: {"hero-arrow-path", "text-info motion-safe:animate-spin"}
  def icon_spec("awaiting_approval"), do: {"hero-hand-raised", "text-warning"}
  def icon_spec("awaiting_input"), do: {"hero-chat-bubble-left-right", "text-warning"}
  def icon_spec("paused"), do: {"hero-pause-circle", "text-warning"}
  def icon_spec("done"), do: {"hero-check-circle", "text-success"}
  # UI-72: a turn a restart cut short (INTR-2).
  def icon_spec("interrupted"), do: {"hero-exclamation-triangle", "text-warning"}
  def icon_spec("idle"), do: {nil, "text-base-content/30"}
  # UI-50 retired: the task statuses a chat used to be drawn with are gone with
  # the vocabulary, so anything else is an unknown status rather than a task's.
  def icon_spec(_other), do: {"hero-exclamation-triangle", "text-base-content/50"}

  @doc "UI-46, UI-47, UI-58, UI-59, UI-72, UI-76: the status in words, as its `title`."
  def title("working"), do: "Working"
  def title("idle"), do: "Idle"
  def title("awaiting_approval"), do: "Needs approval"
  def title("awaiting_input"), do: "Needs your answer"
  def title("paused"), do: "Paused"
  def title("interrupted"), do: "Interrupted: the app restarted during the turn"
  def title("done"), do: "Done"
  def title(status), do: status
end
