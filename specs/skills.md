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
- **SKILL-5** The system prompt is a base prompt, then the project
  instructions section (SKILL-10) when there is one, then one section per
  skill: `## Skill: <name>`, the description, and the instructions.
- **SKILL-6** `reload_skills` rescans the skills folder. It returns the loaded
  skills with their tool names, plus an error result listing any folders that
  failed to load.
- **SKILL-7** The built-in skills are `shell` ([Shell tool](shell-tool.md)),
  `files` ([File tools](file-tools.md)), `harness` (`reload_skills`,
  `update_ledger`), `tasks` (`spawn_task`, `list_tasks`,
  `await_task`, [Sub-tasks](subtasks.md)), `titles` (`set_title`,
  [Chat titles](chat-titles.md)), `done` (`mark_done`,
  [Marking a chat done](chat-done.md), DONE-6), `user-input` (`ask_user`,
  [Structured user input](user-input.md), ASK-1), `chats` (`list_chats`,
  `read_chat`, `search_chats`, [Reading earlier chats](chat-history.md),
  HIST-1) and `self-modification`
  (instructions only). The last one is a chat's only when its project is Elia's
  own (PROJ-17);
  a sub-task session, and only it, also gets the built-in `task` skill, which
  carries `finish_task` (SUBTASK-1).
- **SKILL-8** The `harness` skill's instructions apply in every project: they
  tell the model to prefer a folder skill over changing code, to reload skills
  with `reload_skills`, and to run the tests before finishing. Folder skills
  are written without approval, but their tools always ask.
- **SKILL-9** The `self-modification` skill's instructions tell the model that
  Elixir changes need the user's approval and only take effect after a deploy
  (DEPLOY-8); that when its work is done it commits it and merges its own branch
  into the trunk `master` itself (DEPLOY-13), which is where its part ends — the
  user deploys, from Settings (DEPLOY-5–DEPLOY-7); and
  that the project is spec-driven: before changing Elixir code it updates or
  adds the feature's spec in `specs/` (see `specs/README.md`), keeps
  requirement IDs stable and cites the IDs it touched in the tests it writes.
- **SKILL-10** When `AGENTS.md` exists in a chat's project folder and isn't
  blank, its contents are injected into the system prompt as a section headed
  `## Project instructions (AGENTS.md)`, after the base prompt and before the
  skill sections.
- **SKILL-11** The file is read each time the system prompt is built, so an
  edit applies from the next model request. A missing, unreadable or blank
  file adds no section; an unreadable one is logged as a warning.
- **SKILL-12** The injected contents are capped at 32,000 bytes. Longer files
  are cut at a character boundary, end with a note saying they were truncated,
  and a warning is logged.
- **SKILL-13** Only the root `AGENTS.md` of that folder is injected. Files it
  points to (such as `docs/agents/*.md`) are not; the model reads them on
  demand.

- **SKILL-14** `Elia.Skills.resolve/2` turns a session's `skills` option and
  project into a skill list: a list is used as is, a function of no arguments
  is called, and `nil` means the project's skills (PROJ-21).

- **SKILL-15** The base prompt tells the model to keep the user informed while
  a turn runs several steps: it writes an occasional short, one-sentence
  progress note in a normal message, in its own voice rather than as a harness
  notice, saying what it is doing at that moment. The notes stay occasional
  rather than one per tool call. Nothing is injected into the history and no
  extra model call is made for them: the model writes the note as part of a
  response it was going to make anyway, so the notes arrive at the step
  boundaries the model chooses (LOOP-2).
- **SKILL-16** The base prompt also tells the model to say what it is about to
  do when it starts a step it expects to take a long time — a full test suite,
  a build, a large download — so the transcript is not silent while the command
  runs. A note cannot interrupt a tool that is already running, since the loop
  only moves between steps (LOOP-10), so announcing long work beforehand is how
  a long silent stretch is avoided.

## Configuration

```elixir
config :elia, Elia.Skills,
  builtin: [
    Elia.Skills.Shell,
    Elia.Skills.Files,
    Elia.Skills.Harness,
    Elia.Skills.Tasks,
    Elia.Skills.UserInput,
    Elia.Skills.SelfModification
  ]
```

## Implementation

`Elia.Skill`, `Elia.Skills` (`project_instructions/1`, `system_sections/2`,
`for_project/1`), `Elia.Skills.Harness`, `Elia.Skills.SelfModification`.

## Tests

- `test/elia/skills_test.exs` (a skill's shape, the built-ins and their order, a
  rejected folder skill, the system prompt, `AGENTS.md` and its cap, the
  resolver, the base prompt — SKILL-1 to SKILL-5, SKILL-7, SKILL-10 to SKILL-16).
- `test/elia/self_modification_test.exs` (reloading the folder, SKILL-6, SKILL-9).
- `test/elia/agent_test.exs` (the skills a turn is given, SKILL-7).
- `test/elia/skills/harness_test.exs` (the instructions that apply in every
  project, SKILL-8).
