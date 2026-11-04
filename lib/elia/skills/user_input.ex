defmodule Elia.Skills.UserInput do
  @moduledoc """
  Asking the user a question, with options they can click (ASK).

  The tool does not run when the model calls it: the loop puts the question to
  the user and waits for the answer, which reaches this tool as `ctx[:answer]`
  (LOOP-21, ASK-2). The result hands their answer back verbatim (ASK-5), with
  which the model goes on in the same turn.
  """

  @behaviour Elia.Skill

  @impl true
  def name, do: "user-input"

  @impl true
  def description, do: "Ask the user a question and wait for their answer."

  @impl true
  def instructions do
    """
    Sometimes only the user can settle something: a decision between two ways of
    doing a job, a value you cannot look up, a choice that is theirs to make. \
    Call `ask_user` instead of asking in a reply — the turn waits for the answer
    and goes on with it, so you neither guess nor end your turn.

    - Put the question in `question`. When you can name the choices, give them
      as `options`: each one becomes a button the user can click, which is
      faster and less ambiguous than prose. Keep them short, and to at most six.
    - The user can always answer in their own words instead, so an option list
      is not a limit — name the choices you would pick from yourself.
    - Ask when the answer changes what you do and you cannot settle it yourself
      (read the file, run the test, check the docs). Don't ask about things you
      can find out, don't ask the same question twice, and don't ask for
      permission to carry on.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "ask_user",
        description:
          "Ask the user a question and wait for their answer, which comes back as this " <>
            "call's result. Give `options` when you can name the choices: each one becomes " <>
            "a button the user can click. They can always answer in their own words " <>
            "instead, so an option list is not a limit. Use it when the answer changes " <>
            "what you do and you cannot settle it yourself.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "question" => %{
              "type" => "string",
              "description" => "the question to ask"
            },
            "options" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "maxItems" => 6,
              "description" => "up to six short choices, each shown to the user as a button"
            }
          },
          "required" => ["question"]
        },
        asks_user: true,
        run: &answer/2
      }
    ]
  end

  # ASK-5: the answer, verbatim. Reaching here without one is a bug — the loop
  # only runs this tool once it has the answer (LOOP-21) — so it is reported to
  # the model rather than invented.
  defp answer(_input, ctx) do
    case Map.get(ctx, :answer) do
      answer when is_binary(answer) -> {:ok, "The user answered: #{quoted(answer)}"}
      _other -> {:error, "No answer: the question was not put to the user."}
    end
  end

  defp quoted(answer), do: "\"" <> answer <> "\""
end
