defmodule Elia.UserInputTest do
  use ExUnit.Case, async: true

  alias Elia.Skills.UserInput

  defp tool, do: Enum.find(UserInput.tools(), &(&1.name == "ask_user"))

  # ASK-1, SKILL-7
  test "the user-input skill carries ask_user, which never needs approval" do
    assert UserInput.name() == "user-input"
    assert tool().asks_user
    assert Elia.Tool.approval(tool(), %{"question" => "Which way?"}, %{}) == :never
  end

  # ASK-1, ASK-12, LOOP-8
  test "its input is a question and at most six options" do
    assert :ok = Elia.Tool.validate(tool(), %{"question" => "Which way?"})

    assert :ok =
             Elia.Tool.validate(tool(), %{"question" => "Which way?", "options" => ["a", "b"]})

    assert {:error, message} = Elia.Tool.validate(tool(), %{"options" => ["a"]})
    assert message =~ "question is required"

    assert {:error, message} = Elia.Tool.validate(tool(), %{"question" => 1})
    assert message =~ "question must be a string"

    # ASK-12: `options` has to be an array of strings, and at most six of them.
    assert {:error, message} =
             Elia.Tool.validate(tool(), %{"question" => "q", "options" => "a or b"})

    assert message =~ "options must be a array"

    assert {:error, message} =
             Elia.Tool.validate(tool(), %{"question" => "q", "options" => ["a", 2]})

    assert message =~ "every item of options must be a string"

    assert {:error, message} =
             Elia.Tool.validate(tool(), %{"question" => "q", "options" => ~w(a b c d e f g)})

    assert message =~ "options must have at most 6 items"
  end

  # ASK-5
  test "the result carries the user's answer verbatim" do
    assert {:ok, ~s(The user answered: "Use the jail.")} =
             Elia.Tool.call(tool(), %{"question" => "Which way?"}, %{answer: "Use the jail."})
  end

  # ASK-2: a call that was never put to the user is reported, not invented.
  test "a call with no answer is reported to the model" do
    assert {:error, message} = Elia.Tool.call(tool(), %{"question" => "Which way?"}, %{})
    assert message =~ "not put to the user"
  end

  # ASK-11
  test "the instructions say when to ask and how to offer choices" do
    instructions = UserInput.instructions()

    assert instructions =~ "options"
    assert instructions =~ "at most six"
    assert instructions =~ "their own words"
    assert instructions =~ "cannot settle it yourself"
    assert instructions =~ "Don't ask"
  end
end
