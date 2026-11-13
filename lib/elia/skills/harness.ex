defmodule Elia.Skills.Harness do
  @moduledoc """
  Extending Elia with folder skills, in every project (PROJ-16, SKILL-8).

  What only applies to Elia's own code — approval, merging into
  the trunk `master` and deploying — is `Elia.Skills.SelfModification`
  (PROJ-17).
  """

  @behaviour Elia.Skill

  alias Elia.Harness

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

    In a project of your own the skill goes in that project's `skills/` folder, \
    and it applies from your next step without `reload_skills`. Folder skills \
    need no approval to write, but their tools always ask the user before running.

    Run `run_tests` before finishing, so you know the change works.
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
        name: "run_tests",
        description:
          "Run `mix test` in the workspace. `args` may hold test paths under test/ " <>
            "(optionally path:line) and the flags --failed, --stale, --trace, --seed N, " <>
            "--max-failures N, --only TAG, --exclude TAG. " <>
            "The run stops after #{Harness.timeout_config(:timeout)}s by default " <>
            "(ask for longer with `timeout_seconds`, up to " <>
            "#{Harness.timeout_config(:max_timeout)}s — a chat's first run in a fresh " <>
            "worktree compiles deps and app before its first test, so give it the time " <>
            "rather than letting it be killed halfway), and each test that sets no " <>
            "timeout of its own stops after #{Harness.timeout_config(:test_timeout)}ms " <>
            "(ask for another with `test_timeout_ms`, up to " <>
            "#{Harness.timeout_config(:max_test_timeout)}ms). A test's own " <>
            "`@tag timeout:` and `--trace` (which makes ExUnit ignore timeouts) override " <>
            "the per-test one, and the run's own timeout is what bounds those.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "args" => %{"type" => "array", "items" => %{"type" => "string"}},
            "timeout_seconds" => %{
              "type" => "integer",
              "description" =>
                "Stop the whole run after this many seconds (default " <>
                  "#{Harness.timeout_config(:timeout)}, the most " <>
                  "#{Harness.timeout_config(:max_timeout)}; a larger value runs with the " <>
                  "maximum and the result says so)"
            },
            "test_timeout_ms" => %{
              "type" => "integer",
              "description" =>
                "Give `mix test` this per-test timeout in milliseconds (default " <>
                  "#{Harness.timeout_config(:test_timeout)}, the most " <>
                  "#{Harness.timeout_config(:max_test_timeout)})"
            }
          }
        },
        run: fn input, ctx ->
          Harness.run_tests(
            input["args"] || [],
            ctx[:workspace] || Elia.Workspace.root(),
            jail: ctx[:jail],
            timeout_seconds: input["timeout_seconds"],
            test_timeout_ms: input["test_timeout_ms"]
          )
        end
      },
      %Elia.Tool{
        name: "update_ledger",
        description:
          "Append exact facts to this chat's compaction ledger (COMPACT-22). The " <>
            "ledger is sent with every request and is never elided or summarized, so " <>
            "file paths, decisions, requirement IDs and open questions survive a long " <>
            "chat. One fact per entry.",
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
