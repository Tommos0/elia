# Folder skills

Status: Implemented

Skills can be added without recompiling: a folder under `skills/` with a
`SKILL.md` and, optionally, script-backed tools. The agent can write these
itself.

## Requirements

- **FOLDER-1** Each directory directly under a `skills/` folder is a candidate
  skill. It must contain `SKILL.md`. The `skills/` folders are Elia's own and,
  for a chat with a project of its own, the project's (PROJ-18).
- **FOLDER-2** `SKILL.md` starts with a `---` frontmatter block of
  `key: value` lines. `name` (matching `^[a-z0-9][a-z0-9_-]{0,63}$`) and
  `description` are required. The body after the frontmatter is the skill's
  instructions.
- **FOLDER-3** The skill's instructions end with "Skill folder: <relative path>",
  relative to the workspace root the skill was loaded from.
- **FOLDER-4** The optional `tools.json` file is a JSON list of tools. Each
  has `name` (matching `^[a-zA-Z0-9_-]{1,64}$`), `description` and `command`,
  and optionally `input_schema` (an object schema; defaults to empty) and
  `timeout_seconds` (default 60).
- **FOLDER-5** Load errors are specific: a missing `SKILL.md`, missing
  frontmatter, an invalid or missing field, invalid JSON, or
  "tools.json entry <i>: <reason>".
- **FOLDER-6** A script tool runs its `command` through `Elia.Shell.run/2`,
  like the shell tool, so with `bash -c` where bash is installed and POSIX
  `sh -c` otherwise (SHELL-2), in the skill folder.
- **FOLDER-7** Tool input never goes into the command line. It is passed as
  JSON in `ELIA_INPUT`, and each top-level string, number or boolean field as
  `ELIA_ARG_<FIELD>` (upper-cased, with non-alphanumeric characters replaced
  by `_`). `ELIA_WORKSPACE` holds the workspace root the skill was loaded from
  (PROJ-12).
- **FOLDER-8** Script tools always need approval, because the agent can write
  them without approval (WS-1).
- **FOLDER-9** A script tool's output and exit status are formatted like the
  shell tool's (SHELL-4).

## Implementation

`Elia.Skills.Folder`.

## Tests

- `test/elia/self_modification_test.exs` (the `folder skills` block: the
  directories it finds, `SKILL.md` and its frontmatter, `tools.json`, the errors
  a load reports, a script tool run with its input beside the command and its
  output formatted as the shell tool's — FOLDER-1, FOLDER-2, FOLDER-4 to
  FOLDER-7, FOLDER-9).
- `test/elia/skills_test.exs` (the "Skill folder:" line and a name conflict,
  FOLDER-3).
- `test/elia/auto_approve_test.exs` (a script tool always needs approval, so a
  chat's default set holds it, FOLDER-8).
- `test/elia/command_isolation_test.exs` (a script tool follows the call's jail
  and workspace, FOLDER-6).
