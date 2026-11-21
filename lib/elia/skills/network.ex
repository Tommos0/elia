defmodule Elia.Skills.Network do
  @moduledoc """
  Asking for a host to be allowed (NET-30 - NET-35).

  The list belongs to the chat's project (NET-28), so a host allowed here is one
  every chat of that project reaches from then on. The tool does not run when
  the model calls it: the loop puts the request to the user and waits, so the
  answer reaches this tool as `ctx[:answer]` (LOOP-21, ASK-2, NET-31) — and the
  chat is only allowed a host the user approved (NET-33).
  """

  @behaviour Elia.Skill

  # NET-33: the answer that allows a host — the card's own button — in any case,
  # ignoring surrounding space.
  @allow "allow"

  @impl true
  def name, do: "network"

  @impl true
  def description, do: "Ask the user to allow a host for the chat's project."

  @impl true
  def instructions do
    """
    What a command or a terminal may reach is the chat's network setting, and \
    the hosts it names are its project's allowlist — a new project's starts \
    empty, so a command reaches nothing until a host is allowed. When a command \
    cannot reach a host it needs, ask for it with `request_network_host` \
    instead of giving up, instead of looking for another way out, and instead \
    of reaching for a chat without a limit: the turn waits, and you go on with \
    the user's answer.

    - Name one host per call — `api.example.com`, `*.example.com` or \
      `api.example.com:443` — and say in `reason` what you need it for and \
      which command wanted it. The user has to be able to decide from the card.
    - Ask only for a host the work needs, and ask again only if the answer left \
      room for it. A host the user didn't allow is not one to work around.
    - An allowed host is the project's, so it stays allowed for its other chats \
      too: don't spend an allowance you don't need.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "request_network_host",
        description:
          "Ask the user to add a host to this chat's project's network allowlist and wait " <>
            "for their decision, which comes back as this call's result. Use it when a " <>
            "command cannot reach a host the work needs: name one host and say what you " <>
            "need it for. Nothing reaches the host until the user allows it.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "host" => %{
              "type" => "string",
              "description" =>
                "the host to allow: a name (`api.example.com`), a `*.` suffix of one " <>
                  "(`*.example.com`), or either with a port (`api.example.com:443`)"
            },
            "reason" => %{
              "type" => "string",
              "description" => "what you need the host for, and which command wanted it"
            }
          },
          "required" => ["host", "reason"]
        },
        asks_user: true,
        run: &run/2
      }
    ]
  end

  defp run(input, ctx) do
    host = input |> Map.get("host", "") |> to_string() |> String.trim()

    cond do
      not Elia.Net.Allowlist.valid?(host) ->
        {:error,
         "#{inspect(host)} is not a host this allowlist can hold: name a host " <>
           "(`api.example.com`), a `*.` suffix of one (`*.example.com`), or either with a " <>
           "port (`api.example.com:443`). Nothing was asked and nothing was allowed."}

      true ->
        case Map.get(ctx, :answer) do
          answer when is_binary(answer) -> decide(host, answer, ctx)
          _none -> {:error, "No answer: the request was not put to the user."}
        end
    end
  end

  # NET-33: the answer allows the host, or it does not. Allowing adds the host to
  # the chat's project's list if it isn't there already (PROJ-49).
  defp decide(host, answer, ctx) do
    project = Map.get(ctx, :project) || Elia.Projects.harness()

    if allows?(answer) do
      allow(host, project, ctx)
    else
      {:ok,
       "The user did not allow #{host} (they answered #{quoted(answer)}). " <>
         "Their answer is not one to work around: don't retry the same host, and say " <>
         "what the command could not do without it."}
    end
  end

  defp allow(host, project, ctx) do
    case Elia.Projects.add_allowlist(project, [host]) do
      {:ok, project} -> {:ok, allowed(host, project, ctx)}
      {:error, entry} -> {:error, "#{inspect(entry)} is not a host this allowlist can hold."}
    end
  end

  # NET-33: the result says the host is allowed and that the command may be run
  # again; NET-34: and that a chat whose mode is not allowlist is still limited
  # by its own mode, whatever its project now allows.
  defp allowed(host, project, ctx) do
    entries = Enum.join(Elia.Projects.allowlist(project), ", ")

    "The user allowed #{host}: it is now in #{project.name}'s allowlist (#{entries}), " <>
      "so run the command again. " <> mode_note(Map.get(ctx, :network))
  end

  defp mode_note(%{mode: :unrestricted}),
    do: "This chat reaches the whole network in any case."

  defp mode_note(%{mode: mode}) when mode != :allowlist,
    do:
      "This chat's own network setting is \"#{mode}\", though: it reaches nothing until that changes."

  defp mode_note(_setting), do: ""

  defp allows?(answer) do
    answer |> String.trim() |> String.downcase() |> String.trim_trailing(".") == @allow
  end

  defp quoted(answer), do: "\"" <> answer <> "\""
end
