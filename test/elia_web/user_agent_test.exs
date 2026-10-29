defmodule EliaWeb.UserAgentTest do
  use ExUnit.Case, async: true

  alias EliaWeb.UserAgent

  # CLIENT-8
  test "detects common browsers and systems" do
    cases = [
      {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
       "Chrome 130", "macOS", false},
      {"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0",
       "Edge 130", "Windows", false},
      {"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 OPR/114.0.0.0",
       "Opera 114", "Windows", false},
      {"Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0", "Firefox 131",
       "Linux", false},
      {"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
       "Safari 18", "iOS", true},
      {"Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36",
       "Chrome 130", "Android", true}
    ]

    for {ua, browser, os, mobile?} <- cases do
      assert UserAgent.parse(ua) == %{browser: browser, os: os, mobile?: mobile?}, ua
    end
  end

  # CLIENT-8
  test "falls back for unknown or missing user agents" do
    unknown = %{browser: "Unknown browser", os: "Unknown OS", mobile?: false}
    assert UserAgent.parse("curl/8.5.0") == unknown
    assert UserAgent.parse("") == unknown
    assert UserAgent.parse(nil) == unknown
  end
end
