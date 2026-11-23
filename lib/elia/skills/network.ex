defmodule Elia.Skills.Network do
  @moduledoc """
  Asking for a host to be allowed (NET-30 - NET-39).

  The user decides which list the host goes into: the entries the chat names of
  its own, which are that chat's alone, or its project's, which every chat of the
  project reaches (NET-28, NET-36). The tool does not run when the model calls
  it: the loop puts the request to the user and waits, so the answer reaches this
  tool as `ctx[:answer]` (LOOP-21, ASK-2, NET-31) — and a host is only allowed
  one the user approved (NET-33).
  """

  @behaviour Elia.Skill

  # NET-32, NET-33: the card's own button that fills the project's list; an
  # answer that names no list is read as allowing the host for this chat.
  @for_project "project"

  @impl true
  def name, do: "network"

  @impl true
  def description, do: "Ask the user to allow a host for this chat or for its project."

  @impl true
  def instructions do
    """
    What a command or a terminal may reach is the chat's network setting, and \
    the hosts it reaches are the ones this chat names of its own together with \
    its project's allowlist — a new chat's list and a new project's both start \
    empty, so a command reaches nothing until a host is allowed. When a command \
    cannot reach a host it needs, ask for it with `request_network_host` \
    instead of giving up, instead of looking for another way out, and instead \
    of reaching for a chat without a limit: the turn waits, and you go on with \
    the user's answer.

    - Name one host per call — `api.example.com`, `*.example.com` or \
      `api.example.com:443` — and say in `reason` what you need it for and \
      which command wanted it. The user has to be able to decide from the card.
    - The card offers the host for this chat or for its project, and the user \
      decides which: an entry this chat names of its own is that chat's alone \
      (NET-36), while a project's entry is reached by every chat of it \
      (NET-28). Say in `reason` which of the two the work needs.
    - A host only this chat's work needs belongs in its own list; the project's \
      is for hosts its other chats need too. Ask only for a host the work \
      needs, and ask again only if the answer left room for it: a host the user \
      didn't allow is not one to work around.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "request_network_host",
        description:
          "Ask the user to allow a host for this chat or for its project's network " <>
            "allowlist and wait for their decision, which comes back as this call's " <>
            "result. Use it when a command cannot reach a host the work needs: name one " <>
            "host and say what you need it for, and which chat it is for. Nothing reaches " <>
            "the host until the user allows it.",
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
              "description" =>
                "what you need the host for, which command wanted it, and whether the " <>
                  "chat's own list or its project's is enough"
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

  # NET-33: the answer allows the host for the chat, allows it for the project,
  # or it does not.
  defp decide(host, answer, ctx) do
    case decision(answer) do
      :chat -> allow_chat(host, ctx)
      :project -> allow_project(host, ctx)
      :deny -> {:ok, refused(host, answer)}
    end
  end

  # NET-33, NET-36: the entries the chat names of its own, which are that chat's
  # alone. The setting is read from the chat, not from the answer's context: what
  # a command was limited by holds its project's entries too (NET-28).
  defp allow_chat(host, ctx) do
    id = Map.get(ctx, :session_id)
    setting = is_binary(id) && Elia.Agent.network_setting(id)

    cond do
      not is_map(setting) ->
        {:error,
         "This chat has no running session, so #{host} was not allowed: nothing " <>
           "reaches it, and nothing was added to anything."}

      true ->
        case Elia.Agent.set_network(id, Elia.Net.add_host(setting, host)) do
          :ok -> {:ok, allowed_chat(host, setting, ctx)}
          {:error, message} -> {:error, message}
        end
    end
  end

  defp allow_project(host, ctx) do
    project = Map.get(ctx, :project) || Elia.Projects.harness()

    case Elia.Projects.add_allowlist(project, [host]) do
      {:ok, project} -> {:ok, allowed_project(host, project, ctx)}
      {:error, entry} -> {:error, "#{inspect(entry)} is not a host this allowlist can hold."}
    end
  end

  # NET-33: the result says which list the host is in and that the command may be
  # run again — this chat's own, which no other chat reaches; NET-34: and that a
  # chat whose mode is not allowlist is still limited by its own mode.
  defp allowed_chat(host, setting, ctx) do
    entries = setting |> Elia.Net.add_host(host) |> Elia.Net.hosts() |> Enum.join(", ")

    "The user allowed #{host} for this chat: it is now in this chat's own allowlist " <>
      "(#{entries}), which no other chat reaches, so run the command again. " <>
      mode_note(Map.get(ctx, :network))
  end

  # NET-33: the project's list, which every chat of it reaches (NET-28).
  defp allowed_project(host, project, ctx) do
    entries = Enum.join(Elia.Projects.allowlist(project), ", ")

    "The user allowed #{host} for #{project.name}: it is now in that project's " <>
      "allowlist (#{entries}), which every chat of it reaches, so run the command " <>
      "again. " <> mode_note(Map.get(ctx, :network))
  end

  defp refused(host, answer) do
    "The user did not allow #{host} (they answered #{quoted(answer)}). " <>
      "Their answer is not one to work around: don't retry the same host, and say " <>
      "what the command could not do without it."
  end

  defp mode_note(%{mode: :unrestricted}),
    do: "This chat reaches the whole network in any case."

  defp mode_note(%{mode: mode}) when mode != :allowlist,
    do:
      "This chat's own network setting is \"#{mode}\", though: it reaches nothing until that changes."

  defp mode_note(_setting), do: ""

  # NET-32, NET-33, NET-39: which list the answer fills. The card's own buttons
  # name it (`Allow for chat`, `Allow for project`), and so does an answer the
  # user typed in their own words: one that names the project fills it, one that
  # names this chat fills the chat's own list, an answer that allows the host
  # without naming either is read as allowing it for this chat — the project's
  # list is never filled by a word the user did not choose — and anything else
  # allows nothing.
  defp decision(answer) do
    text = answer |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    cond do
      denies?(text) -> :deny
      allows?(text) and String.contains?(text, @for_project) -> :project
      allows?(text) -> :chat
      true -> :deny
    end
  end

  defp denies?(text) do
    String.contains?(text, "deny") or String.contains?(text, "don't") or
      String.contains?(text, "do not") or String.starts_with?(text, "no")
  end

  defp allows?(text) do
    String.contains?(text, "allow") or text in ["yes", "y", "ok", "okay", "sure"]
  end

  defp quoted(answer), do: "\"" <> answer <> "\""
end
