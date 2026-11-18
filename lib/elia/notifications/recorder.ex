defmodule Elia.Notifications.Recorder do
  @moduledoc """
  Records a notification when a chat starts to need the user (NOTIF-1).

  It follows the status every session broadcasts on the activity topic
  (`Elia.Agent.subscribe_activity/0`, the `{:chat_status, id, status}` of
  SESS-19) the way `Elia.Push.Notifier` does, and records on the same
  transitions: a tool call awaiting approval (APPR), a question awaiting an
  answer (ASK), a turn that finished (LOOP) and a turn paused at a limit
  (LIMIT). The status it saw last is kept per chat, so a status that is reported
  twice records once, and a chat that is not new to Elia in this process records
  nothing on its first sighting.

  Whether push is set up has nothing to do with it: the list is Elia's own
  (NOTIF-1). A chat whose page is in front of the user is recorded as read
  (NOTIF-4), which is the same rule that keeps a push from arriving for the chat
  the user is already reading (PUSH-13).
  """

  use GenServer

  alias Elia.Notifications

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Elia.Agent.subscribe_activity()
    {:ok, %{status: %{}}}
  end

  @impl true
  # SESS-19, SESS-35: a chat's done flag is announced on the same topic, and
  # marking a chat done is not one of the changes that record an entry
  # (NOTIF-1). It isn't recorded either, so the turn that ends after the chat
  # was marked done (DONE-6) still reads as the turn that ended.
  def handle_info({:chat_status, _chat_id, :done}, state), do: {:noreply, state}

  def handle_info({:chat_status, chat_id, status}, state) do
    if reason = reason(Map.get(state.status, chat_id), status) do
      Notifications.record(chat_id, reason, read: Elia.Push.Viewers.visible?(chat_id))
    end

    {:noreply, put_in(state.status[chat_id], status)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  NOTIF-1: why a chat's status changing from `previous` to `status` records an
  entry, or `nil` when it does not. These are the transitions
  `Elia.Push.Notifier.reason/2` sends a push for (PUSH-11, PUSH-12): the same
  event, said two ways.
  """
  @spec reason(atom() | nil, atom()) :: atom() | nil
  def reason(_previous, :awaiting_approval), do: :approval
  def reason(_previous, :awaiting_input), do: :input
  def reason(:running, :idle), do: :finished
  def reason(:running, :paused), do: :paused
  def reason(_previous, _status), do: nil
end
