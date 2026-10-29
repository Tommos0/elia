defmodule EliaWeb.Presence do
  @moduledoc "Presence tracker for connected client sessions (see `EliaWeb.ClientTracker`)."

  use Phoenix.Presence, otp_app: :elia, pubsub_server: Elia.PubSub
end
