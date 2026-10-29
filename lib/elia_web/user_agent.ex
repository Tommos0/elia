defmodule EliaWeb.UserAgent do
  @moduledoc """
  Rough browser and OS detection from a `User-Agent` header, for display only.
  Order matters: Edge and Opera also claim Chrome, Chrome also claims Safari,
  iOS claims macOS and Android claims Linux.
  """

  @browsers [
    {"Edge", ~r{Edg/(\d+)}},
    {"Opera", ~r{OPR/(\d+)}},
    {"Firefox", ~r{Firefox/(\d+)}},
    {"Chrome", ~r{Chrome/(\d+)}},
    {"Safari", ~r{Safari/}}
  ]

  @systems [
    {"Windows", ~r/Windows/},
    {"iOS", ~r/iPhone|iPad/},
    {"Android", ~r/Android/},
    {"macOS", ~r/Macintosh|Mac OS X/},
    {"Linux", ~r/Linux/}
  ]

  @mobile ~w(iOS Android)

  @spec parse(binary() | nil) :: %{browser: binary(), os: binary(), mobile?: boolean()}
  def parse(user_agent) do
    user_agent = user_agent || ""
    os = os(user_agent)
    %{browser: browser(user_agent), os: os, mobile?: os in @mobile}
  end

  defp browser(user_agent) do
    Enum.find_value(@browsers, "Unknown browser", fn {name, regex} ->
      case Regex.run(regex, user_agent) do
        nil -> nil
        [_, version] -> "#{name} #{version}"
        [_] -> safari_version(name, user_agent)
      end
    end)
  end

  defp safari_version(name, user_agent) do
    case Regex.run(~r{Version/(\d+)}, user_agent) do
      [_, version] -> "#{name} #{version}"
      nil -> name
    end
  end

  defp os(user_agent) do
    Enum.find_value(@systems, "Unknown OS", fn {name, regex} ->
      if Regex.match?(regex, user_agent), do: name
    end)
  end
end
