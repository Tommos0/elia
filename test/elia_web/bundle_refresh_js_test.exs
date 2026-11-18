defmodule EliaWeb.BundleRefreshJsTest do
  # There is no JS runner, so this only guards the wiring and the constants the
  # spec states. Behaviour is checked by hand (see specs/bundle-refresh.md).
  use ExUnit.Case, async: true

  @js File.read!("assets/js/bundle_refresh.js")
  @app File.read!("assets/js/app.js")
  @budget File.read!("assets/js/reload_budget.js")

  test "app.js starts bundleRefresh after connecting" do
    assert @app =~ ~s|import {bundleRefresh} from "./bundle_refresh"|

    assert @app =~
             ~r/liveSocket\.connect\(\)\nautoReconnect\(liveSocket\)\n(\/\/[^\n]*\n)*bundleRefresh\(liveSocket\)/
  end

  # BUNDLE-4: the check runs on load, when the socket opens or opens again, when
  # the tab is shown again or restored from the back/forward cache, and every 60
  # seconds while the tab is visible.
  test "checks on load, on a socket open, when shown and every 60 seconds" do
    assert @js =~ "CHECK_INTERVAL_MS = 60000"
    assert @js =~ "setInterval(check, CHECK_INTERVAL_MS)"
    assert @js =~ "onOpen(check)"
    assert @js =~ ~s|document.addEventListener("visibilitychange", check)|
    assert @js =~ ~s|window.addEventListener("pageshow", e => e.persisted && check())|
    assert @js =~ ~r/^\s{2}check\(\)$/m
  end

  # BUNDLE-4: a hidden tab makes no request.
  test "a hidden tab does not check" do
    assert @js =~ ~s|document.visibilityState !== "visible"|
  end

  # BUNDLE-5: a page that sees another bundle loads itself again.
  test "another bundle reloads the page" do
    assert @js =~ "window.location.reload()"
  end

  # BUNDLE-6: reloads are limited to 3 per minute per tab, counted in the budget
  # auto reconnect counts in as well (CONN-5).
  test "reloads share the tab's budget" do
    assert @js =~ ~s|import {reloadAllowed} from "./reload_budget"|
    assert @js =~ "reloadAllowed()"
    assert @budget =~ "MAX_RELOADS = 3"
    assert @budget =~ "RELOAD_WINDOW_MS = 60000"
    assert @budget =~ "sessionStorage"
  end

  # BUNDLE-7: a check that fails changes nothing.
  test "a failed check is ignored" do
    assert @js =~ "served === null || served === loaded"
    assert @js =~ "response.ok"
  end
end
