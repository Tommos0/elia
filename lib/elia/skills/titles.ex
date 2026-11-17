defmodule Elia.Skills.Titles do
  @moduledoc """
  Chat titles (spec: `specs/chat-titles.md`). The built-in skill `titles` gives
  a chat `set_title`, so the model names the chat from the request in front of
  it; a chat it never names keeps the first-message title the chat list derives
  (STORE-7, TITLE-1).
  """

  @behaviour Elia.Skill

  @impl true
  def name, do: "titles"

  @impl true
  def description, do: "Name this chat for the chat list, with the set_title tool."

  @impl true
  def instructions do
    """
    The chat list shows this chat under a title. Without one it is the first \
    user message cut short, which for a long request is an arbitrary prefix of \
    it. Call `set_title` with a few words naming the chat, early in your first \
    turn — alongside the first real tool call, in the same step, so it costs no \
    extra round trip — and call it again only if the chat turns to something \
    else. Don't ask the user about it. A sub-task starts with the title its \
    spawn gave it and may rename itself like any chat.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "set_title",
        description:
          "Set the name this chat's row in the chat list and its page title show " <>
            "(at most 60 characters: a longer one is cut). Call it once early in your " <>
            "first turn, with a few words naming what the chat is about, and again only " <>
            "if the chat turns to something else.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "title" => %{
              "type" => "string",
              "description" => "A few words naming this chat, e.g. \"Chat titles\""
            }
          },
          "required" => ["title"]
        },
        # TITLE-5: naming a chat has no effect on the machine, so it never needs
        # approval and is not a tool the approval popover offers (APPR-13).
        approval: :never,
        run: fn input, ctx -> set_title(input, ctx) end
      }
    ]
  end

  # TITLE-4, TITLE-6: the session shapes the title and refuses a blank one
  # (TITLE-2); a sub-task may name itself like any chat (TITLE-3). A refusal is
  # an error result for the model.
  defp set_title(input, ctx) do
    case Elia.Agent.set_title(ctx[:session_id], input["title"]) do
      {:ok, title} -> {:ok, "This chat is now titled \"#{title}\"."}
      {:error, message} -> {:error, message}
    end
  end
end
