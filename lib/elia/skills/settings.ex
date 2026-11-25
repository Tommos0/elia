defmodule Elia.Skills.Settings do
  @moduledoc """
  Reading a chat's own settings (spec: `specs/chat-settings.md`, CSET-14 to
  CSET-17). The built-in skill `settings` gives every chat one tool,
  `get_chat_settings`, so a turn can answer "which model am I, and what are my
  limits?" from the conversation instead of asking the user.

  What it reads is the chat's running session (SESS-7, SESS-41) through the
  harness — no command and no approval (APPR-7) — so it reports what applies at
  that moment, a setting changed on the settings page or by a tool mid-turn
  included (CSET-4), and it changes nothing of the chat's own.

  Each value a chat can have none of its own for is reported beside the one that
  applies, with `"own"` false: a model the chat never picked (MODEL-15, MODEL-2),
  an effort it never set (LLM-39) and a turn limit it left empty (LIMIT-1). The
  identity fields and the entries per kind of setting are CSET-14 and CSET-16.
  """

  @behaviour Elia.Skill

  alias Elia.LLM.Compaction

  @impl true
  def name, do: "settings"

  @impl true
  def description,
    do: "Read this chat's own settings — its model, limits and the rest — with get_chat_settings."

  @impl true
  def instructions do
    """
    The chat you are running in is configured: which model it talks to, its \
    reasoning effort, the tools it auto-approves, whether its commands are \
    jailed and what network they reach, its turn limits and its compaction \
    options. Call `get_chat_settings` when one of those changes what you do or \
    what you tell the user — "which model are you?", a turn that keeps pausing \
    at a limit — instead of asking the user. It reads this chat's settings and \
    nothing else: it changes none of them, and another chat's settings are that \
    chat's own (LIMIT-5, CSET-1).
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "get_chat_settings",
        description:
          "Read the settings of the chat you are running in, as JSON: its id, " <>
            "project, title and done flag, the model in use (with whether it is " <>
            "this chat's own choice or the default that applies), its reasoning " <>
            "effort, the tools it auto-approves, its jail and network settings, " <>
            "its turn limits and its compaction options. It reads them and " <>
            "changes none of them, so it never needs approval.",
        input_schema: %{"type" => "object", "properties" => %{}},
        # CSET-15, APPR-7: reading the chat's settings has no effect on the
        # machine and is not a tool the approval popover offers (APPR-13).
        approval: :never,
        run: &get_chat_settings/2
      }
    ]
  end

  # CSET-15: the tool runs in a chat, which is the settings it reports; a call
  # with no chat to read is an error result rather than a crash.
  defp get_chat_settings(_input, ctx) do
    case ctx[:session_id] do
      nil ->
        {:error, "No chat to read settings from."}

      id ->
        {:ok, id |> Elia.Agent.snapshot() |> report() |> Jason.encode!()}
    end
  end

  # CSET-14, CSET-16: the chat's identity, then one entry per kind of setting.
  defp report(snapshot) do
    settings = snapshot.settings

    %{
      "id" => snapshot.id,
      "title" => snapshot.title,
      "done" => snapshot.done,
      "project" => project(snapshot.project),
      "model" => model(settings.model),
      "effort" => applying(settings.effort, nil),
      "auto_approve" => settings.auto_approve,
      "jail" => %{"on" => settings.jail, "available" => Elia.Shell.available?()},
      "network" => network(settings.network, snapshot.project),
      "limits" => limits(settings.limits),
      "compaction" => Compaction.options(snapshot.compaction.options)
    }
  end

  # PROJ-9: the project a chat belongs to, which is also where its commands run
  # (PROJ-12).
  defp project(nil), do: nil

  defp project(project),
    do: %{"id" => project.id, "name" => project.name, "folder" => project.folder}

  # MODEL-1, CTX-7, MODEL-15, MODEL-2: the model the chat's turn would talk to,
  # with the window the context indicator knows, and whether the chat picked it
  # itself or the stored or configured default applies.
  defp model(own) do
    selection = Elia.LLM.selection(own)

    %{
      "provider" => selection.provider,
      "id" => selection.model,
      "name" => selection[:name] || selection.model,
      "context_window" => Elia.LLM.context_window(own).context_length,
      "own" => own?(own, selection)
    }
  end

  # A selection whose provider is no longer registered is ignored in favour of
  # the default (MODEL-16), so what the chat holds is not what applies.
  defp own?(nil, _selection), do: false

  defp own?(own, selection),
    do: own[:provider] == selection.provider and own[:model] == selection.model

  # NET-1, NET-36, NET-28: the mode, the entries the chat names of its own and
  # the ones its project's allowlist names, which its commands reach as well.
  defp network(setting, project) do
    %{
      "mode" => Atom.to_string(Elia.Net.mode(setting)),
      "hosts" => Elia.Net.hosts(setting),
      "project_hosts" => Elia.Projects.allowlist(project)
    }
  end

  # LIMIT-1, LIMIT-9: the limits a chat can leave empty, each with the value
  # that applies and whether it is the chat's own. An empty one is no limit of
  # the chat's, so the loop's default stands in: its 300 steps (LOOP-16), no
  # time and no token budget (LOOP-20, LIMIT-12). `pause_on_limit` is a boolean
  # the chat always holds one of, on until it is turned off (LIMIT-9).
  defp limits(limits) do
    limits = Elia.Limits.new(limits)

    %{
      "max_steps" => applying(limits.max_steps, Elia.Agent.Loop.default_max_steps()),
      "max_minutes" => applying(limits.max_minutes, nil),
      "max_tokens" => applying(limits.max_tokens, nil),
      "pause_on_limit" => limits.pause_on_limit
    }
  end

  defp applying(own, default),
    do: %{"value" => if(is_nil(own), do: default, else: own), "own" => not is_nil(own)}
end
