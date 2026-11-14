defmodule Elia.Skills.Harness do
  @moduledoc """
  Extending Elia with folder skills, in every project (PROJ-16, SKILL-8).

  It carries no test runner (VERIFY-11): a test run is the `shell` tool's, and
  `Elia.Harness.run_tests/3` stays for the deploy's own suite (DEPLOY-5).

  What only applies to Elia's own code — approval, merging into
  the trunk `master` and deploying — is `Elia.Skills.SelfModification`
  (PROJ-17).
  """

  @behaviour Elia.Skill

  @impl true
  def name, do: "harness"

  @impl true
  def description, do: "Extend Elia with new skills instead of changing its code."

  @impl true
  def instructions do
    """
    You can extend yourself. Prefer adding a folder skill over changing Elixir code:

    1. Create `skills/<name>/SKILL.md` with frontmatter (`name`, `description`) \
    followed by instructions for yourself. Optionally add `skills/<name>/tools.json` \
    with script-backed tools and the scripts they run. The format is documented in \
    `lib/elia/skills/folder.ex`.
    2. Call `reload_skills` and fix any reported errors. New tools are available \
    from your next step.

    Keep the compaction ledger current as you work, not at the end: call \
    `update_ledger` for each decision, file path or open question as you make it \
    (COMPACT-34). A step's reasoning is the first thing compaction drops, so a \
    conclusion that never reached the ledger is lost with it.

    In a project of your own the skill goes in that project's `skills/` folder, \
    and it applies from your next step without `reload_skills`. Folder skills \
    need no approval to write, but their tools always ask the user before running.

    Run the tests before finishing, so you know the change works: `mix test`, \
    or plain `mix precommit` for everything, through the `shell` tool — and give \
    a suite run a longer `timeout_seconds` than the shell's default, because a \
    first run in a fresh worktree compiles deps and app before its first test.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "reload_skills",
        description: "Rescan the skills folder. Returns loaded skills and any load errors.",
        input_schema: %{"type" => "object", "properties" => %{}},
        run: fn _ -> reload_skills() end
      },
      %Elia.Tool{
        name: "update_ledger",
        description:
          "Append exact facts to this chat's compaction ledger (COMPACT-22). The " <>
            "ledger is sent with every request and is never elided or summarized, so " <>
            "file paths, decisions, requirement IDs and open questions survive a long " <>
            "chat. One fact per entry. Write as you go, not at the end: append a line " <>
            "for each decision, path or open question as you make it, because a step's " <>
            "reasoning is the first thing compaction drops (COMPACT-14) and a " <>
            "conclusion that never reached the ledger goes with it.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "entries" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "the facts to append, verbatim"
            }
          },
          "required" => ["entries"]
        },
        run: &update_ledger/2
      }
    ]
  end

  defp update_ledger(input, ctx) do
    case ctx[:session_id] do
      nil ->
        {:error, "No chat to record this in."}

      id ->
        {:ok, ledger} = Elia.Agent.add_ledger(id, input["entries"] || [])
        {:ok, "The ledger now holds #{length(ledger)} entries; it is sent on every request."}
    end
  end

  defp reload_skills do
    %{skills: skills, errors: errors} = Elia.Skills.reload()

    loaded =
      Enum.map_join(skills, "\n", fn skill ->
        tools = Enum.map_join(skill.tools, ", ", & &1.name)
        "- #{skill.name}#{if tools != "", do: " (tools: #{tools})"}"
      end)

    case errors do
      [] ->
        {:ok, "Loaded skills:\n#{loaded}"}

      errors ->
        failed = Enum.map_join(errors, "\n", fn {folder, reason} -> "- #{folder}: #{reason}" end)
        {:error, "Loaded skills:\n#{loaded}\n\nFailed to load:\n#{failed}"}
    end
  end
end
