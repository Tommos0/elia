# Projects

Status: Implemented

Elia works in project folders. A project is a named folder on disk; every chat
belongs to one, and that folder is the workspace its tools work in. A project
brings its own `AGENTS.md` and `skills/`, which are added to Elia's own; the
instructions and tools that only make sense while changing Elia's own code are
kept apart from the ones that apply in every project.

## Requirements

### The registry

- **PROJ-1** A project is `%{id, name, folder, harness?}`: an id of 12
  URL-safe characters (STORE-5), a non-blank `name` (trimmed on save), the
  absolute path of an existing directory `folder`, and `harness?` true only
  for Elia's own project.
- **PROJ-2** Projects are saved as one Erlang term in `.elia/projects.term`
  (Elia's data dir, PROJ-13), written atomically like a session (STORE-2). A
  missing, unreadable or corrupt file reads as "no projects" rather than an
  error.
- **PROJ-3** Elia's own project always exists: id `harness`, name "Elia",
  `harness?` true, and folder `Elia.Workspace.root/0` (the live tree, DEPLOY-3).
  It is always first in a listing, and its folder follows
  `Elia.Workspace.root/0` even if the file holds another one. Each of its chats
  works in its own worktree (DEPLOY-1).
- **PROJ-4** `list/0` returns Elia's project first, then the others by name
  (case-insensitive, then by id).
- **PROJ-5** `get/1` returns the project with that id, or `nil`. `harness/0` is
  Elia's own project.
- **PROJ-6** `create/2` takes a name and a folder. A blank name is
  `{:error, :blank_name}` and a folder that isn't an existing directory is
  `{:error, :not_a_directory}`; otherwise the project is saved and returned as
  `{:ok, project}`.
- **PROJ-7** `delete/1` removes a project and returns `:ok`. Elia's own project
  can't be deleted (`{:error, :harness_project}`); an unknown id is `:ok`; a
  project's chats are never deleted with it.
- **PROJ-8** `default/0` is the project a new chat starts in: the one
  `set_default/1` last stored (in `Elia.Settings`, so it survives a restart),
  else Elia's own project. `set_default/1` with an unknown id leaves the
  default alone.

### Chats and projects

- **PROJ-9** A chat belongs to a project: saving a session stores its
  `project_id` (STORE-19), and a listed chat carries it (STORE-20). A chat
  without one belongs to Elia's own project.
- **PROJ-10** A sub-task chat belongs to its parent's project.
- **PROJ-11** Starting a chat in a project (PROJ-26) calls `set_default/1`, so
  the next new chat starts there (PROJ-8).

### The project folder is the workspace

- **PROJ-12** The folder of a chat's project is the workspace root for that
  chat's tools: `read_file`, `write_file` and `edit_file` resolve and classify
  paths against it (WS-1–WS-3), `shell` runs there, and folder-skill scripts
  get it in `ELIA_WORKSPACE` (FOLDER-7). A chat in Elia's own project is the
  exception: its workspace root is its own worktree, not the project folder
  (DEPLOY-1).
- **PROJ-13** Elia's own data — `.elia/projects.term` and `.elia/sessions/` —
  lives in Elia's root (the live tree, DEPLOY-2) whatever project a chat
  belongs to, so a project folder is never written to by the harness itself.
- **PROJ-14** Checkpoints, `mix test` verification and the deploy workflow are
  bound to Elia's own project: the file and shell tools only checkpoint when
  their project is Elia's own (DEPLOY-1), and only Elia's own project has the
  `self-modification` skill (PROJ-17).

### Instructions and skills

- **PROJ-15** The system prompt of a chat in project P is the base prompt, then
  P's `AGENTS.md` when it has one, then one section per skill (SKILL-5;
  SKILL-10–SKILL-13 apply to P's folder instead of Elia's root).
- **PROJ-16** The `harness` skill keeps the instructions that apply in every
  project — prefer a folder skill over changing code, reload skills, and run
  the tests before finishing — with the tools `reload_skills`, `run_tests` and
  `update_ledger` (SKILL-7, COMPACT-22).
- **PROJ-17** A built-in `self-modification` skill carries what only applies to
  Elia's own code: changing Elixir files, checkpoints, the spec-driven
  workflow and merging to the trunk (`master`), with the tools
  `list_checkpoints` and `rollback`. A chat has it only when its project is
  Elia's own.
- **PROJ-18** A chat's skills are the built-in skills (PROJ-17), the folder
  skills of Elia's `skills/` dir (SKILL-2–SKILL-4) and the folder skills of
  project P's `skills/` dir. P's are skipped when P's folder is Elia's root, so
  they are not loaded twice.
- **PROJ-19** A project's own folder skills follow FOLDER-1–FOLDER-9 like
  Elia's. A folder that fails to load is logged and the remaining skills still
  load.
- **PROJ-20** A project's skills are re-read for every model step, so a skill
  the agent writes into the project applies from the next step without
  `reload_skills`.
- **PROJ-21** `Elia.Skills.for_project/1` returns `{skills, errors}` for a
  project; `Elia.Skills.resolve/2` resolves a session's `skills` option
  against its project (SKILL-14).

### The file explorer

- **PROJ-22** The file explorer browses one project at a time:
  `/files?project=<id>` (default: Elia's own), with paths relative to that
  project's folder. `/files` with an unknown or missing project id uses Elia's
  own.

### The interface

- **PROJ-23** `/projects` lists every project with its name, folder and number
  of chats (`#project-<id>`), a form to create one from a name and a folder
  (`#new-project`), and a delete button (`#delete-project-<id>`) for every
  project except Elia's. Creating with a folder that isn't a directory shows
  the error and adds nothing; deleting asks for confirmation.
- **PROJ-24** The chat sidebar groups chats by project: a header per project
  (`#project-header-<id>`) with the project's name and a "New chat" button
  (`#new-chat-<id>`) starting a chat in it (PROJ-26), and that project's chats
  below, newest first at the top level (UI-4), with a task chat nested under
  its parent, oldest first (UI-45). Projects with no chats still show their
  header.
- **PROJ-25** The header on every page has a "Projects" link (`#projects-link`)
  next to "Chats".
- **PROJ-26** `/p/<project id>/new` starts a chat in that project (PROJ-11) and
  redirects to `/c/<new id>`; an unknown project id redirects to `/`. The
  sidebar's "New chat" button (UI-31) starts a chat in the default project
  (PROJ-8), which is the open chat's project when there is one.

## Out of scope

- Checkpoints, rollback and `mix test` verification apply to Elia's own
  project only (PROJ-14); a project folder that is its own git repo is not
  snapshotted.
- Projects have no per-project model, provider or settings.

## Implementation

`Elia.Projects`, `Elia.Workspace`, `Elia.Store`, `Elia.Agent`, `Elia.Agent.Session`,
`Elia.Agent.Loop`, `Elia.Skills`, `Elia.Skills.Harness`,
`Elia.Skills.SelfModification`, `Elia.Skills.Files`, `Elia.Skills.Shell`,
`Elia.Skills.Folder`, `Elia.Skills.Tasks`, `Elia.Explorer`, `Elia.LLM.Context`,
`EliaWeb.ProjectsLive`, `EliaWeb.ChatLive`, `EliaWeb.FilesLive`,
`EliaWeb.Router`, `EliaWeb.Layouts`.

## Tests

`test/elia/projects_test.exs`, `test/elia/store_test.exs`,
`test/elia/skills_test.exs`, `test/elia/agent_test.exs`,
`test/elia_web/live/projects_live_test.exs`,
`test/elia_web/live/chat_live_test.exs`, `test/elia_web/live/files_live_test.exs`.
