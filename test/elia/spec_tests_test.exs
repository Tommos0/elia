defmodule Elia.SpecTraceabilityTest do
  use ExUnit.Case, async: true

  alias Elia.SpecLint

  # The traceability rules of `specs/test-traceability.md`: every requirement is
  # accounted for by a test file that exists or by a `No test:` line saying why,
  # decided from the tree and nothing else (TRACE-7, TRACE-8).

  @root Path.expand("../..", __DIR__)

  @thing """
  # Thing

  Status: Implemented

  A thing that is a thing.

  ## Requirements

  - **THING-1** It is a thing.

  ## Tests

  - `test/elia/thing_test.exs` (THING-1).
  """

  test "the specs account for every requirement (TRACE-2, TRACE-6)" do
    violations = SpecLint.traceability(@root)

    assert violations == [],
           "the specs break the traceability rules of specs/test-traceability.md:\n" <>
             Enum.join(violations, "\n")
  end

  test "a requirement no Tests section cites fails the lint (TRACE-2)" do
    assert lint_tree(spec: thing(tests: "")) =~
             "THING-1 is not accounted for"
  end

  test "a requirement another spec's Tests section cites passes (TRACE-1, TRACE-2)" do
    assert lint_tree(
             spec: thing(tests: ""),
             specs: %{
               "other.md" => other(tests: "- `test/elia/thing_test.exs` (THING-1, OTHER-1).")
             }
           ) == ""
  end

  test "a retired requirement needs no accounting (TRACE-5)" do
    assert lint_tree(
             spec:
               thing(
                 requirements: "- ~~**THING-1** It was a thing.~~ Retired: it is gone.",
                 tests: ""
               )
           ) == ""
  end

  test "a range of IDs is expanded (TRACE-1, TRACE-2)" do
    assert lint_tree(
             spec:
               thing(
                 requirements: """
                 - **THING-1** It is a thing.
                 - **THING-2** It is another thing.
                 - **THING-3** It is a third thing.
                 """,
                 tests: "- `test/elia/thing_test.exs` (THING-1 to THING-3)."
               )
           ) == ""
  end

  test "a test file a Tests section names that is not there fails the lint (TRACE-6)" do
    assert lint_tree(test_files: []) =~ "names test/elia/thing_test.exs, which is not in the tree"
  end

  test "a No test: line accounts for a requirement (TRACE-2, TRACE-3)" do
    assert lint_tree(spec: thing(tests: "- No test: THING-1 — a reviewer decides it.")) == ""
  end

  test "a No test: line that does not say why fails the lint (TRACE-3)" do
    assert lint_tree(spec: thing(tests: "- No test: THING-1")) =~
             "does not say why"
  end

  test "a No test: line that names no requirement fails the lint (TRACE-3)" do
    assert lint_tree(spec: thing(tests: "- No test: — nothing to check.")) =~
             "names no requirement"
  end

  test "a No test: line for a requirement another spec defines fails the lint (TRACE-4)" do
    assert lint_tree(
             spec: thing(tests: "- No test: OTHER-1 — checked by hand."),
             specs: %{"other.md" => other(tests: "- No test: OTHER-1 — checked by hand.")}
           ) =~ "names OTHER-1, which specs/thing.md does not define"
  end

  test "a fixture tree with no app and no workspace is enough (TRACE-8)" do
    assert lint_tree() == ""
  end

  defp thing(options) do
    """
    # Thing

    Status: Implemented

    A thing that is a thing.

    ## Requirements

    #{Keyword.get(options, :requirements, "- **THING-1** It is a thing.")}

    ## Tests

    #{Keyword.get(options, :tests, "- `test/elia/thing_test.exs` (THING-1).")}
    """
  end

  defp other(options) do
    """
    # Other

    Status: Implemented

    Another thing.

    ## Requirements

    - **OTHER-1** It is another thing.

    ## Tests

    #{Keyword.get(options, :tests, "- `test/elia/thing_test.exs` (OTHER-1).")}
    """
  end

  defp lint_tree(options \\ []) do
    dir = Path.join(System.tmp_dir!(), "spec-trace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "specs"))
    File.write!(Path.join(dir, "specs/README.md"), "# Specs\n")
    File.write!(Path.join(dir, "specs/thing.md"), Keyword.get(options, :spec, @thing))

    for {name, body} <- Keyword.get(options, :specs, %{}) do
      File.write!(Path.join(dir, "specs/#{name}"), body)
    end

    for path <- Keyword.get(options, :test_files, ["test/elia/thing_test.exs"]) do
      File.mkdir_p!(Path.join(dir, Path.dirname(path)))
      File.write!(Path.join(dir, path), "# a test\n")
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    SpecLint.traceability(dir) |> Enum.join("\n")
  end
end
