defmodule EliaWeb.BrowserJsLogger do
  @moduledoc """
  Records what the page in a real browser logs, so a test fails when its page
  produced JavaScript errors (BROWSER-8).

  `PhoenixTest.Playwright` hands every console message and uncaught page error
  here (configured in `config/test.exs`). Errors are kept for the test case to
  assert on afterwards; anything below `:error` is logged as usual, so the
  console stays visible in the test output.
  """

  @behaviour PlaywrightEx.JsLogger

  use Agent

  require Logger

  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @doc "Forgets what has been recorded, so a test only sees its own errors."
  def clear, do: Agent.update(__MODULE__, fn _ -> [] end)

  @doc "Returns the errors recorded so far, and forgets them."
  def take, do: Agent.get_and_update(__MODULE__, fn errors -> {Enum.reverse(errors), []} end)

  @impl true
  def log(:error, text, msg), do: record("error: " <> text <> source(msg))

  def log(level, text, msg), do: Logger.log(level, text <> source(msg))

  # The logger runs in the Playwright listener, not in the test process, and
  # may be called before the test case has started the agent.
  defp record(entry) do
    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, &[entry | &1])
    else
      Logger.error(entry)
    end
  end

  defp source(%{params: %{location: location}}) when is_map(location) do
    case location do
      %{url: ""} -> ""
      %{url: url, line_number: line} when is_integer(line) -> " (#{url}:#{line})"
      %{url: url} -> " (#{url})"
      _ -> ""
    end
  end

  defp source(_msg), do: ""
end
