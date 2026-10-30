defmodule EliaWeb.AutoReconnectTest do
  # There is no JS runner, so this only guards the wiring and the constants the
  # spec states. Behaviour is checked by hand (see specs/auto-reconnect.md).
  use ExUnit.Case, async: true

  @js File.read!("assets/js/auto_reconnect.js")
  @app File.read!("assets/js/app.js")

  test "app.js starts autoReconnect after connecting" do
    assert @app =~ ~s|import {autoReconnect} from "./auto_reconnect"|
    assert @app =~ ~r/liveSocket\.connect\(\)\nautoReconnect\(liveSocket\)/
  end

  # CONN-2
  test "heartbeat timeout is 5 seconds" do
    assert @js =~ "HEARTBEAT_TIMEOUT_MS = 5000"
    assert @js =~ "socket.ping("
  end

  # CONN-4
  test "stall timer is 10 seconds and only reloads a visible tab" do
    assert @js =~ "STALL_MS = 10000"
    assert @js =~ "visible() && !liveSocket.isConnected()"
  end

  # CONN-5
  test "reloads are limited to 3 per minute" do
    assert @js =~ "MAX_RELOADS = 3"
    assert @js =~ "RELOAD_WINDOW_MS = 60000"
  end
end
