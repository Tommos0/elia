defmodule EliaWeb.ChatStatus do
  @moduledoc """
  The one status indicator a listed chat shows (UI-46, UI-47, UI-58, UI-59,
  UI-72), shared by the chat page's sidebar and the dashboard (DASH-3, DASH-5,
  DASH-7) so that both read the same.

  `status/2` answers for a listed chat (`Elia.Store.list/1`) together with what
  the registry says about it (`Elia.Agent.awaiting_approval/0`, `paused/0`,
  `running/0`, SESS-19) and the record a restart left behind (STORE-31).
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
      # UI-46: a task chat shows its task status (STORE-17).
      is_binary(Map.get(chat, :task_status)) -> chat.task_status
      # UI-72: a turn a restart cut short (STORE-31).
      Map.get(state, :interrupted, false) -> "interrupted"
      # UI-59: an ordinary chat's loop activity.
      Map.get(state, :running, false) -> "working"
      true -> "idle"
    end
  end

  attr :id, :string, required: true
  attr :status, :string, required: true

  @doc "UI-44, UI-46, UI-47, UI-58, UI-59, UI-72, UI-76: a chat's status as an icon."
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
  def icon_spec("running"), do: {"hero-arrow-path", "text-info motion-safe:animate-spin"}
  def icon_spec("awaiting_approval"), do: {"hero-hand-raised", "text-warning"}
  def icon_spec("awaiting_input"), do: {"hero-chat-bubble-left-right", "text-warning"}
  def icon_spec("paused"), do: {"hero-pause-circle", "text-warning"}
  def icon_spec("done"), do: {"hero-check-circle", "text-success"}
  def icon_spec("blocked"), do: {"hero-pause-circle", "text-warning"}
  def icon_spec("failed"), do: {"hero-x-circle", "text-error"}
  def icon_spec("unfinished"), do: {"hero-question-mark-circle", "text-warning"}
  def icon_spec("cancelled"), do: {"hero-stop-circle", "text-base-content/60"}
  # UI-72: a turn a restart cut short (INTR-2), and the task status STORE-17
  # gives a child whose session was lost.
  def icon_spec("interrupted"), do: {"hero-exclamation-triangle", "text-warning"}
  def icon_spec("idle"), do: {nil, "text-base-content/30"}
  def icon_spec(_other), do: {"hero-exclamation-triangle", "text-base-content/50"}

  @doc "UI-46, UI-47, UI-58, UI-59, UI-72, UI-76: the status in words, as its `title`."
  def title("working"), do: "Working"
  def title("idle"), do: "Idle"
  def title("awaiting_approval"), do: "Needs approval"
  def title("awaiting_input"), do: "Needs your answer"
  def title("paused"), do: "Paused"
  def title("interrupted"), do: "Interrupted: the app restarted during the turn"
  def title(status), do: "Task #{status}"
end
