defmodule Elia.SpecsTest do
  use ExUnit.Case, async: true

  alias Elia.Specs

  @alpha """
  # Alpha

  Status: Draft

  Why this feature exists, in a paragraph that is not a requirement.

  ## Requirements

  - **ALPHA-1** The first requirement, which the spec writes across
    two lines and with `code` and **emphasis** in it.
  - **ALPHA-2** The second one.

    Its second paragraph stays with it.

  - ~~**ALPHA-3** A retired one~~ Retired: it was replaced (ALPHA-2).
  - **ALPHA-4** One holding <brackets>, an & and a "quote".

  ## Out of scope

  - A bullet here is prose, not a requirement.
  """

  # A workspace is any directory, and its corpus is its own `specs/` (CITE-4).
  defp corpus(files) do
    root = Path.join(System.tmp_dir!(), "elia_specs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "specs"))
    for {name, content} <- files, do: File.write!(Path.join([root, "specs", name]), content)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # CITE-1, CITE-2: the corpus is every `specs/*.md` entry, and each one's text is
  # the spec's own — its line wrapping collapsed, the entry's own markers left
  # out, and a retirement's reason kept (SPEC-5).
  test "reads a workspace's corpus, with each requirement's own text" do
    root =
      corpus(%{
        "alpha.md" => @alpha,
        "beta.md" => "# Beta\n\n## Requirements\n\n- **BETA-1** Something else.\n"
      })

    assert Specs.requirements(root) == %{
             "ALPHA-1" =>
               "The first requirement, which the spec writes across two lines and with " <>
                 "`code` and **emphasis** in it.",
             "ALPHA-2" => "The second one. Its second paragraph stays with it.",
             "ALPHA-3" => "A retired one Retired: it was replaced (ALPHA-2).",
             "ALPHA-4" => ~s(One holding <brackets>, an & and a "quote".),
             "BETA-1" => "Something else."
           }

    assert Specs.text(root, "BETA-1") == "Something else."
    # CITE-1: an ID the corpus does not define has nothing to show.
    assert Specs.text(root, "GAMMA-1") == nil
  end

  # CITE-4: what the corpus holds as it is read — a spec that is edited, added or
  # removed is followed.
  test "follows the corpus as it changes" do
    root = corpus(%{"alpha.md" => @alpha})
    assert Specs.text(root, "ALPHA-2") =~ "The second one"

    File.write!(Path.join([root, "specs", "alpha.md"]), "# Alpha\n\n- **ALPHA-2** Rewritten.\n")
    File.write!(Path.join([root, "specs", "beta.md"]), "# Beta\n\n- **BETA-1** New.\n")

    assert Specs.text(root, "ALPHA-2") == "Rewritten."
    assert Specs.text(root, "ALPHA-1") == nil
    assert Specs.text(root, "BETA-1") == "New."

    File.rm!(Path.join([root, "specs", "beta.md"]))
    assert Specs.text(root, "BETA-1") == nil
  end

  # CITE-4: a modification time has second granularity, so an edit that leaves a
  # file's size alone is only seen because the read that took it is not trusted
  # until it lands in a later second.
  test "sees an edit that keeps the file's size" do
    root = corpus(%{"alpha.md" => "# Alpha\n\n- **ALPHA-1** Aa.\n"})
    assert Specs.text(root, "ALPHA-1") == "Aa."

    File.write!(Path.join([root, "specs", "alpha.md"]), "# Alpha\n\n- **ALPHA-1** Bb.\n")
    assert Specs.text(root, "ALPHA-1") == "Bb."
  end

  # CITE-4: a workspace with no corpus has nothing to show, and a `specs` that is
  # not a directory is not an error either.
  test "a workspace with no specs has nothing to show" do
    root = Path.join(System.tmp_dir!(), "elia_specs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert Specs.requirements(root) == %{}
    assert Specs.text(root, "ALPHA-1") == nil

    File.write!(Path.join(root, "specs"), "not a directory\n")
    assert Specs.requirements(root) == %{}
  end

  # CITE-1, CITE-2, CITE-4: the tree's own corpus, read whole — every requirement
  # of every spec, with the spec's own text and nothing of the entry's markup.
  test "reads the tree's own corpus" do
    requirements = Specs.requirements(Path.expand("../..", __DIR__))

    assert Map.has_key?(requirements, "SPEC-1")
    assert Map.has_key?(requirements, "CITE-1")
    assert map_size(requirements) > 500

    for {id, text} <- requirements do
      assert String.match?(id, ~r/^[A-Z]+-\d+$/), id
      assert text != "", id
      assert text == String.trim(text), id
      refute text =~ "\n", id
    end
  end
end
