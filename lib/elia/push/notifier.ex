defmodule Elia.Push.Notifier do
  @moduledoc """
  Sends a notification when a chat starts to need the user (PUSH-11, PUSH-12).

  It follows the status every session broadcasts on the activity topic
  (`Elia.Agent`, the `{:chat_status, id, status}` of SESS-19) and notifies on the
  changes that mean "come back": a tool call awaiting approval (APPR), a
  question awaiting an answer (ASK), a turn that finished (LOOP) and a turn
  paused at a limit (LIMIT). The status it saw last is kept per chat, so a
  status that is reported twice notifies once, and a chat that is not new to
  Elia in this process does not notify on its first sighting.

  A chat the user is looking at is skipped (PUSH-13), and so is a send when
  nothing subscribed, which is the usual state.
  """

  use GenServer

  alias Elia.Push

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Elia.Agent.subscribe_activity()
    {:ok, %{status: %{}}}
  end

  @impl true
  def handle_info({:chat_status, chat_id, status}, state) do
    if reason = reason(Map.get(state.status, chat_id), status), do: notify(chat_id, reason)
    {:noreply, put_in(state.status[chat_id], status)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  PUSH-11, PUSH-12: why a chat's status changing from `previous` to `status`
  notifies, or `nil` when it does not.
  """
  @spec reason(atom() | nil, atom()) :: atom() | nil
  def reason(_previous, :awaiting_approval), do: :approval
  def reason(_previous, :awaiting_input), do: :input
  def reason(:running, :idle), do: :finished
  def reason(:running, :paused), do: :paused
  def reason(_previous, _status), do: nil

  # ── internals ──────────────────────────────────────────────────────────────

  defp notify(chat_id, reason) do
    if Elia.Push.Subscriptions.count() > 0 and not Push.Viewers.visible?(chat_id) do
      Push.notify(Push.chat_payload(chat_id, reason))
    end

    :ok
  end
end
