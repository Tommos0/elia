defmodule Elia.Notifications do
  @moduledoc """
  The notifications Elia keeps for the user (`specs/notifications.md`).

  Push tells a device that a chat needs the user and then the message is gone
  (`Elia.Push`); this is the same event kept where it can be found again: an
  entry per event (NOTIF-1, NOTIF-2), which the header's bell counts and shows
  (`EliaWeb.Notifications`), and which the user reads — by following it to its
  chat, or by saying they have seen them all.

  The entries are one list in the settings database under one key (NOTIF-12,
  newest first), so every change is one `Elia.Settings.update/3` of that key
  (CONF-29) and changes that overlap take effect in one order. A change is
  announced on a PubSub topic (`subscribe/0`), which is how an open page follows
  the list without a reload (NOTIF-10).
  """

  alias Elia.Settings

  # NOTIF-12: the one key the list lives under.
  @key "notifications"

  # NOTIF-3: how much of the list is kept.
  @limit 50

  @topic "notifications:changes"

  @doc "NOTIF-10: the topic a page subscribes to in order to follow the list."
  @spec topic() :: binary()
  def topic, do: @topic

  @doc "NOTIF-10: follow the list on this process."
  @spec subscribe() :: :ok
  def subscribe, do: Phoenix.PubSub.subscribe(Elia.PubSub, @topic)

  @doc "NOTIF-2, NOTIF-10: the stored entries, newest first."
  @spec list() :: [map()]
  def list, do: Settings.get(@key, [])

  @doc "NOTIF-5, NOTIF-10: how many entries have not been read."
  @spec unread_count() :: non_neg_integer()
  def unread_count, do: count_unread(list())

  @doc "NOTIF-5: how many of `entries` have not been read."
  @spec count_unread([map()]) :: non_neg_integer()
  def count_unread(entries), do: Enum.count(entries, &(&1.read != true))

  @doc """
  NOTIF-1, NOTIF-2: record that a chat needs the user, and return the entry.
  The entry is unread unless the caller says otherwise (NOTIF-4,
  `Elia.Notifications.Recorder`), and the list keeps the newest `50` of them
  (NOTIF-3).
  """
  @spec record(binary(), atom(), keyword()) :: map()
  def record(chat_id, reason, opts \\ []) do
    entry = %{
      id: new_id(),
      chat_id: chat_id,
      title: title(chat_id),
      reason: reason,
      at: DateTime.utc_now(),
      read: Keyword.get(opts, :read, false)
    }

    change(&Enum.take([entry | &1], @limit))
    entry
  end

  @doc "NOTIF-7: mark the entry with this id read."
  @spec mark_read(binary()) :: :ok
  def mark_read(id) do
    mark(fn entry -> entry.id == id end)
  end

  @doc "NOTIF-8: mark every entry for this chat read."
  @spec mark_chat_read(binary()) :: :ok
  def mark_chat_read(chat_id) do
    mark(fn entry -> entry.chat_id == chat_id end)
  end

  @doc "NOTIF-9: mark every entry read."
  @spec mark_all_read() :: :ok
  def mark_all_read do
    mark(fn _entry -> true end)
  end

  @doc "NOTIF-9: forget every entry."
  @spec clear() :: :ok
  def clear do
    if list() != [], do: change(fn _entries -> [] end)
    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # NOTIF-7 to NOTIF-9: marking read is one update of the stored list, so a
  # marking that overlaps a recording is applied to the list that recording left
  # (NOTIF-12) rather than to the one read before it. Nothing is written when
  # there is nothing unread to mark, which is what a chat page that opens twice
  # pays for (NOTIF-8).
  defp mark(matches) do
    if Enum.any?(list(), fn entry -> entry.read != true and matches.(entry) end) do
      change(fn entries ->
        Enum.map(entries, fn entry ->
          if entry.read != true and matches.(entry), do: %{entry | read: true}, else: entry
        end)
      end)
    end

    :ok
  end

  defp change(fun) do
    entries = Settings.update(@key, [], fun)
    Phoenix.PubSub.broadcast(Elia.PubSub, @topic, {:notifications, entries})
    entries
  end

  # NOTIF-2: the chat's title as it is at this moment (TITLE-1), with the same
  # fallback push uses when it has none — and, since a title is what the entry
  # keeps, the title an entry outlives its chat with (NOTIF-13).
  defp title(chat_id), do: Elia.Store.chat_title(chat_id) || "Elia"

  defp new_id do
    "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
