defmodule Elia.SpecHygieneTest do
  use ExUnit.Case, async: true

  alias Elia.SpecLint

  # The corpus rules of `specs/spec-hygiene.md`: the lint decides what the text
  # can (SPEC-16), from the tree and nothing else (SPEC-17). The lint itself is
  # `test/support/spec_lint.ex`, shared with the traceability test beside this
  # one (TRACE-7).

  @root Path.expand("../..", __DIR__)

  @readme """
  # Specs

  ## Index

  | Spec | Prefix | Summary |
  | --- | --- | --- |
  | [Thing](thing.md) | `THING` | A thing |

  ## Plans
  """

  @thing """
  # Thing

  Status: Implemented

  A thing that is a thing.

  ## Requirements

  - **THING-1** It is a thing.

  ## Implementation

  `Elia.Thing`

  ## Tests

  `test/elia/thing_test.exs`
  """

  test "the specs follow the corpus rules (SPEC-16)" do
    violations = SpecLint.hygiene(@root)

    assert violations == [],
           "the specs break the corpus rules of specs/spec-hygiene.md:\n" <>
             Enum.join(violations, "\n")
  end

  test "an ID defined twice in one prefix fails the lint (SPEC-2)" do
    assert lint_tree(
             spec: """
             # Thing

             Status: Implemented

             A thing.

             ## Requirements

             - **THING-1** It is a thing.
             - **THING-1** It is another thing.

             ## Tests

             `test/elia/thing_test.exs`
             """
           ) =~ "THING-1 is defined twice"
  end

  test "a retired number reused fails the lint (SPEC-3, SPEC-4)" do
    assert lint_tree(
             spec: """
             # Thing

             Status: Implemented

             A thing.

             ## Requirements

             - ~~**THING-1** It was a thing.~~ Retired: it is gone.
             - **THING-1** It is a thing.

             ## Tests

             `test/elia/thing_test.exs`
             """
           ) =~ "reuses the number of a retired requirement"
  end

  test "a retirement without a reason fails the lint (SPEC-5)" do
    assert lint_tree(
             spec: """
             # Thing

             Status: Implemented

             A thing.

             ## Requirements

             - ~~**THING-1** It was a thing.~~

             ## Tests

             `test/elia/thing_test.exs`
             """
           ) =~ "THING-1 is retired without a reason"
  end

  test "a retirement with a reason passes the lint (SPEC-5)" do
    assert lint_tree(
             spec:
               thing(
                 requirements: """
                 - ~~**THING-1** It was a thing.~~ Superseded by THING-2.
                 - **THING-2** It is a thing.
                 """
               )
           ) == ""
  end

  test "prose on the Status: line fails the lint (SPEC-6)" do
    assert lint_tree(spec: thing(status: "Status: Implemented (phases 1 to 3)")) =~
             "Status: must be exactly one of"
  end

  test "a Status: word outside the four fails the lint (SPEC-6)" do
    assert lint_tree(spec: thing(status: "Status: Done")) =~ "Status: must be exactly one of"
  end

  test "a retired spec whose index row does not say so fails the lint (SPEC-7)" do
    assert lint_tree(
             spec:
               thing(
                 status: "Status: Retired",
                 requirements: "- ~~**THING-1** It was a thing.~~ Retired: it is gone."
               )
           ) =~ "which is Retired, and does not say so"
  end

  test "a spec missing from the index fails the lint (SPEC-8)" do
    assert lint_tree(readme: "# Specs\n\n## Index\n\n| Spec | Prefix | Summary |\n") =~
             "has no row in the index"
  end

  test "a plan missing from the plans list fails the lint (SPEC-8)" do
    assert lint_tree(plans: %{"plan.md" => "# Plan\n"}) =~ "is not in the plans list"
  end

  test "an index row whose file is gone fails the lint (SPEC-9)" do
    assert lint_tree(readme: String.replace(@readme, "(thing.md)", "(gone.md)")) =~
             "links to gone.md, which is not there"
  end

  test "an index prefix that differs from the file's IDs fails the lint (SPEC-9)" do
    assert lint_tree(readme: String.replace(@readme, "`THING`", "`OTHER`")) =~
             "numbers its requirements THING"
  end

  test "a ## section outside the shape fails the lint (SPEC-10)" do
    assert lint_tree(spec: thing() <> "\n## Data\n\nNothing is stored.\n") =~
             "## Data is not a section a spec uses"
  end

  test "a requirement defined under Out of scope fails the lint (SPEC-14)" do
    assert lint_tree(
             spec:
               thing(
                 extra: """
                 ## Out of scope

                 - **THING-2** It is not a thing.
                 """
               )
           ) =~ "THING-2 is defined under Out of scope"
  end

  test "a citation of an ID no spec defines fails the lint (SPEC-15)" do
    assert lint_tree(
             spec:
               thing(
                 extra: """
                 ## Out of scope

                 Another thing (THING-9) is not covered here.
                 """
               )
           ) =~ "cites THING-9, which no spec defines"
  end

  test "a fixture tree with no app and no workspace is enough (SPEC-17)" do
    # Nothing but Markdown is read: the lint takes a directory and returns the
    # violations in it, which is what these fixtures lint.
    assert lint_tree() == ""
  end

  defp thing(options \\ []) do
    """
    # Thing

    #{Keyword.get(options, :status, "Status: Implemented")}

    A thing that is a thing.

    ## Requirements

    #{Keyword.get(options, :requirements, "- **THING-1** It is a thing.")}

    ## Tests

    `test/elia/thing_test.exs`
    #{Keyword.get(options, :extra, "")}
    """
  end

  defp lint_tree(options \\ []) do
    dir = Path.join(System.tmp_dir!(), "spec-hygiene-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "specs/plans"))
    File.write!(Path.join(dir, "specs/README.md"), Keyword.get(options, :readme, @readme))
    File.write!(Path.join(dir, "specs/thing.md"), Keyword.get(options, :spec, @thing))

    for {name, body} <- Keyword.get(options, :plans, %{}) do
      File.write!(Path.join(dir, "specs/plans/#{name}"), body)
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    SpecLint.hygiene(dir) |> Enum.join("\n")
  end
end
