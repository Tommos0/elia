defmodule EliaWeb.ClientTracker do
  @moduledoc """
  `on_mount` hook that tracks every connected LiveView in `EliaWeb.Presence`
  as a client session: one per open tab, with its IP address, user agent,
  connect time and current path. See `specs/client-sessions.md`.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias EliaWeb.Presence

  @topic "client_sessions"

  def subscribe, do: Phoenix.PubSub.subscribe(Elia.PubSub, @topic)

  @doc "Connected client sessions, newest first, as metas with an `:id`."
  def list do
    @topic
    |> Presence.list()
    |> Enum.map(fn {id, %{metas: [meta | _]}} -> Map.put(meta, :id, id) end)
    |> Enum.sort_by(& &1.connected_at, {:desc, DateTime})
  end

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      meta = %{
        ip: format_ip(get_connect_info(socket, :peer_data)),
        user_agent: get_connect_info(socket, :user_agent) || "",
        connected_at: DateTime.utc_now(),
        path: nil
      }

      # Tracking starts at the first handle_params, which knows the URL.
      socket =
        socket
        |> assign(:client_id, Elia.Agent.new_id())
        |> assign(:client_path, nil)
        |> attach_hook(:client_tracker, :handle_params, &put_path(&1, &2, &3, meta))

      {:cont, socket}
    else
      {:cont, assign(socket, :client_id, nil)}
    end
  end

  defp put_path(_params, uri, socket, meta) do
    %{client_id: id, client_path: previous} = socket.assigns
    path = URI.parse(uri).path

    cond do
      previous == nil -> Presence.track(self(), @topic, id, %{meta | path: path})
      previous != path -> Presence.update(self(), @topic, id, %{meta | path: path})
      true -> :ok
    end

    {:cont, assign(socket, :client_path, path)}
  end

  defp format_ip(%{address: address}), do: address |> :inet.ntoa() |> to_string()
  defp format_ip(_), do: "unknown"
end
