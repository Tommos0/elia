# Skills registry

Status: Implemented

A skill pairs instructions for the model with the tools that carry them out.
The registry combines built-in skills with folder skills and builds the
system prompt from them. It can be reloaded while the app runs.

## Requirements

- **SKILL-1** A skill has a name, a description, instructions and tools. A
  built-in skill is a module implementing `Elia.Skill`; a folder skill is
  loaded from `skills/` (see [Folder skills](folder-skills.md)).
- **SKILL-2** Built-in skills come from config, in order. They are loaded
  first, followed by folder skills in alphabetical order of folder name.
- **SKILL-3** A folder skill is rejected if its name is already taken, or if
  any of its tools has the name of an already loaded tool. The error names the
  conflict; the other skills still load.
- **SKILL-4** Load errors are logged and returned per folder as
  `{relative_folder, reason}`.
- **SKILL-5** The system prompt is a base prompt followed by one section per
  skill: `## Skill: <name>`, the description, and the instructions.
- **SKILL-6** `reload_skills` rescans the skills folder. It returns the loaded
  skills with their tool names, plus an error result listing any folders that
  failed to load.
- **SKILL-7** The built-in skills are `shell` ([Shell tool](shell-tool.md)),
  `files` ([File tools](file-tools.md)) and `harness` (`reload_skills`,
  `run_tests`, `hot_reload`, `list_checkpoints`, `rollback`).
- **SKILL-8** The `harness` skill's instructions tell the model to prefer a
  folder skill over changing Elixir code, to run tests before finishing, and
  to tell the user when a change touches guarded files.
- **SKILL-9** The `harness` skill's instructions tell the model that the
  project is spec-driven: before changing Elixir code it updates or adds the
  feature's spec in `specs/` (see `specs/README.md`), keeps requirement IDs
  stable, and cites the IDs it touched in the tests it writes. Folder skills
  don't need a spec.

## Configuration

```elixir
config :elia, Elia.Skills,
  builtin: [Elia.Skills.Shell, Elia.Skills.Files, Elia.Skills.Harness]
```

## Implementation

`Elia.Skill`, `Elia.Skills`, `Elia.Skills.Harness`.

## Tests

`test/elia/self_modification_test.exs`, `test/elia/agent_test.exs`.
