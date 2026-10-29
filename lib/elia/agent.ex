defmodule Elia.Agent do
  @moduledoc "Public API for agent sessions."

  alias Elia.Agent.Session

  def topic(id), do: "agent:" <> id

  def subscribe(id), do: Phoenix.PubSub.subscribe(Elia.PubSub, topic(id))

  def new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  @doc "Returns the session's pid, starting it if needed."
  def ensure_started(id, opts \\ []) do
    spec = {Session, Keyword.put(opts, :id, id)}

    case DynamicSupervisor.start_child(Elia.Agent.Supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def snapshot(id), do: GenServer.call(Session.via(id), :snapshot)

  def send_message(id, text), do: GenServer.call(Session.via(id), {:send_message, text})

  def approve(id, call_id), do: GenServer.call(Session.via(id), {:decide, call_id, :approve})

  def deny(id, call_id), do: GenServer.call(Session.via(id), {:decide, call_id, :deny})

  def stop(id), do: GenServer.call(Session.via(id), :stop)
end
