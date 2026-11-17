defmodule Elia.Skills.Done do
  @moduledoc """
  Marking a chat done (spec: `specs/chat-done.md`). The built-in skill `done`
  gives a chat `mark_done`, so the model can say that its work is finished and
  has landed — typically right after it has merged its branch into the trunk
  `master` (DONE-6). A done chat is still resumable: the user's next message
  reopens it (DONE-8, DONE-9).
  """

  @behaviour Elia.Skill

  @impl true
  def name, do: "done"

  @impl true
  def description,
    do: "Mark this chat done once its work has landed, with the mark_done tool."

  @impl true
  def instructions do
    """
    A chat can be marked done: its work is finished and has landed, so it is \
    waiting for nothing more. Mark it done as the last step of a change — \
    right after you have merged your branch into the trunk `master` and told \
    the user to deploy — rather than leaving it looking like a chat that was \
    abandoned. Call `mark_done` and don't ask the user about it. Done is \
    bookkeeping, not a stop: the chat can still be continued, and the user's \
    next message reopens it by itself, so never hold anything back for it. In a \
    sub-task this is your last act: your work is committed on your own branch \
    rather than landed on `master`, and marking this chat done is what ends the \
    task and reports your result to the chat that started it.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "mark_done",
        description:
          "Mark this chat done, or reopen it with `done: false`. Use it when the " <>
            "chat's work is finished and has landed — after merging your branch into " <>
            "the trunk `master` — so the chat list shows it as done instead of as one " <>
            "that was abandoned. The chat can still be continued: the user's next " <>
            "message reopens it. In a sub-task, use it as your last act: it ends the " <>
            "task and reports your result to the chat that started it.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "done" => %{
              "type" => "boolean",
              "description" => "true (the default) marks this chat done, false reopens it"
            }
          },
          "required" => []
        },
        # DONE-6: marking a chat done changes nothing on the machine, so it
        # never needs approval and is not a tool the approval popover offers
        # (APPR-13).
        approval: :never,
        run: fn input, ctx -> mark_done(input, ctx) end
      }
    ]
  end

  # DONE-7: the tool answers with the flag as it now is, so the model can tell
  # that nothing stopped. Nothing refuses it, a task chat included (DONE-3), and
  # a missing or non-boolean `done` is read as `true`.
  defp mark_done(input, ctx) do
    done = if is_boolean(input["done"]), do: input["done"], else: true

    case Elia.Agent.set_done(ctx[:session_id], done) do
      {:ok, true} -> {:ok, "This chat is marked done. It can still be continued."}
      {:ok, false} -> {:ok, "This chat is open again."}
    end
  end
end
