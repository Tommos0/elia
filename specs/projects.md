# Projects

Status: Implemented

Elia works in project folders. A project is a named folder on disk; every chat
belongs to one, and that folder is the workspace its tools work in. A project
brings its own `AGENTS.md` and `skills/`, which are added to Elia's own; the
instructions and tools that only make sense while changing Elia's own code are
kept apart from the ones that apply in every project.

One project is open at a time: it is the one the header names beside the logo,
the chat list holds its chats and no other project's, and the switcher in the
header changes it. Opening a chat opens that chat's project, so the header, the
list and the page agree about where the user is.

Every project has a colour — one the user picks from a palette, or the one its
name gives it — and the app's own badge at the top left is painted in the open
project's (PROJ-42, PROJ-46).

## Requirements

### The registry

- **PROJ-1** A project is `%{id, name, folder, color, allowlist, harness?}`: an
  id of 12 URL-safe characters (STORE-5), a non-blank `name` (trimmed on save),
  the absolute path of a directory `folder` — one that exists when the project
  is created (PROJ-6) and may be gone later (PROJ-27) — a `color` that is a
  palette name (PROJ-42) or `nil` for the one the name gives it (PROJ-43), an
  `allowlist` of hosts (PROJ-49), and `harness?` true only for Elia's own
  project.
- **PROJ-2** Projects are saved as one Erlang term in `.elia/projects.term`
  (Elia's data dir, PROJ-13), written atomically like a session (STORE-2). A
  missing, unreadable or corrupt file reads as "no projects" rather than an
  error.
- **PROJ-3** Elia's own project always exists: id `harness`, name "Elia",
  `harness?` true, and folder `Elia.Workspace.root/0` (the live tree, DEPLOY-3).
  It is always first in a listing, and its folder follows
  `Elia.Workspace.root/0` even if the file holds another one. Each of its chats
  works in that folder, as a chat in any project does (PROJ-12, DEPLOY-1).
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
- **PROJ-27** A project whose folder is no longer there stays in the registry
  and is listed, and its chats keep it (PROJ-7, PROJ-9).

### Chats and projects

- **PROJ-9** A chat belongs to a project: saving a session stores its
  `project_id` (STORE-19), and a listed chat carries it (STORE-20). A chat
  without one, and a chat whose `project_id` names no project in the registry
  (PROJ-5) — one whose project has been deleted (PROJ-7) — belong to Elia's own
  project, which is what its session resolves it to (PROJ-12, PROJ-28).
- **PROJ-10** A sub-task chat belongs to its parent's project.
- **PROJ-11** Starting a chat in a project (PROJ-26) calls `set_default/1`, so
  the next new chat starts there (PROJ-8) and that project is the open one
  (PROJ-28).

- **PROJ-31** The chats of a project are the listed chats (STORE-6) whose
  `project_id` (STORE-20) is that project's id, and Elia's own project's also
  include the chats that belong to it by PROJ-9 — those with no `project_id`
  and those whose `project_id` names no project (PROJ-5, PROJ-7). The chat list
  holds the open project's chats and no other project's (PROJ-28, UI-4).

### The project folder is the workspace

- **PROJ-12** The folder of a chat's project is the workspace root for that
  chat's tools: `shell` runs there and its jail holds it (ISOL-13, WD-9), `cd`
  judges a path against it (WD-1, WD-5), and folder-skill scripts get it in
  `ELIA_WORKSPACE` (FOLDER-7).
  There is no exception for Elia's own project: a chat in it works in that
  folder, which is the live tree (DEPLOY-1). A chat may `cd` into a directory
  inside it (WD-1), and it may make a git worktree of its own inside it
  (DEPLOY-28) — neither changes what its tools call the workspace root.
- **PROJ-13** Elia's own data — `.elia/projects.term` and `.elia/sessions/` —
  lives in Elia's root (the live tree, DEPLOY-2) whatever project a chat
  belongs to, so a project folder is never written to by the harness itself.
- **PROJ-14** The deploy workflow is bound to Elia's own project: its `AGENTS.md`
  carries the instruction to make a worktree of one's own and to merge into the
  trunk (PROJ-15, DEPLOY-28, DEPLOY-13), so only a chat in it is told to.

### Instructions and skills

- **PROJ-15** The system prompt of a chat in project P is the base prompt, then
  P's `AGENTS.md` when it has one, then a section naming P's secrets when it has
  any (SECRET-12), then one section per skill (SKILL-5; SKILL-10–SKILL-13 apply
  to P's folder instead of Elia's root).
- **PROJ-16** The `harness` skill keeps the instructions that apply in every
  project — prefer a folder skill over changing code, reload skills, and run
  the tests before finishing — with the tools `reload_skills` and
  `update_ledger` (SKILL-7, COMPACT-22): a test run is the `shell` tool's
  (VERIFY-11).
- ~~**PROJ-17** A built-in `self-modification` skill carries what only applies to
  Elia's own code: changing Elixir files, the spec-driven workflow and merging
  to the trunk (`master`). It has no tools of its own. A chat has it only when
  its project is Elia's own.~~ Retired: everything it said is in Elia's own
  project's `AGENTS.md`, which every chat in that project is given (PROJ-15,
  SKILL-10), so it was a second copy of that instruction and nothing else, and
  the built-in skills are now the same for every project (SKILL-7).
- **PROJ-18** A chat's skills are the built-in skills (SKILL-7), the folder
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

- ~~**PROJ-22** The file explorer browses one project at a time:
  `/files?project=<id>` (default: Elia's own), with paths relative to that
  project's folder.~~ Superseded by EXPL-15: the explorer browses the open
  project (PROJ-28), with paths relative to its folder.

### Colours

- **PROJ-42** `Elia.Projects.palette/0` is the colours a project can be: each
  is `%{name, hex}` — a lowercase name and the `#rrggbb` the interface paints —
  the same entries in the same order for every caller.
- **PROJ-43** `color/1` resolves a project's colour to a palette entry
  (PROJ-42): the one its `color` names, else the one its `name` derives
  (`auto_color/1`), the same name always deriving the same entry — so a
  project keeps its colour across a restart, and one whose stored colour is no
  longer in the palette (PROJ-44) still has one. Every project has a colour,
  Elia's own included.
- **PROJ-44** `set_color/2` stores a palette name on a project and returns the
  saved project as `{:ok, project}`; `nil` clears it, so the project goes back
  to the colour its name derives (PROJ-43); a name the palette does not hold is
  `{:error, :unknown_color}` and stores nothing. Elia's own project takes one
  like any other.
- **PROJ-45** The projects page (PROJ-23) carries the picker for a project's
  colour: a swatch per palette entry (`#project-color-<id>-<name>`, painted in
  that entry's `hex`) and one for the derived colour
  (`#project-color-<id>-auto`), with the project's current choice marked
  `data-selected="true"`. Pressing a swatch stores it (PROJ-44) and shows the
  page with it chosen; pressing the automatic one clears the stored colour.
- **PROJ-46** The header's app icon — the badge at the top left, `#app-icon` —
  is painted in the open project's colour (PROJ-28, PROJ-43) on every page, and
  follows the open project when the switcher changes it (PROJ-29); with no open
  project it is the theme's primary.
- **PROJ-47** A project's colour stands beside its name wherever the interface
  lists it: a swatch in a row of the switcher's menu (`#project-swatch-<id>`,
  PROJ-29) and the project's own icon on the projects page (`#project-icon-<id>`,
  PROJ-23), each painted in the colour the header's icon uses for it (PROJ-46).

### The allowlist

- **PROJ-49** A project has an allowlist of hosts (NET-28): `allowlist/1`
  returns its entries cleaned (NET-7), and `set_allowlist/2` stores a list whose
  every entry is one of NET-7's forms, or returns the first entry that is not
  one and stores nothing. A stored project keeps its list in the registry file
  (PROJ-2); Elia's own project, which the registry never holds (PROJ-3), keeps
  it in the settings database under a key of its own. A project with no list has
  an empty one.
- **PROJ-50** The projects page (PROJ-23) shows each project's allowlist as a
  field (`#project-allowlist-<id>`) holding its entries one per line, with a Save
  (`#save-project-allowlist-<id>`) that applies it when it is pressed; a list
  holding an entry that is not one of NET-7's forms changes nothing and the page
  shows the message for that project (`#project-allowlist-error-<id>`, NET-11).

### The interface

- **PROJ-23** `/projects` lists every project with its name, folder and number
  of chats (`#project-<id>`), a form to create one from a name (`#new-project`),
  and a delete button (`#delete-project-<id>`) for every project except Elia's.
  Deleting asks for confirmation.
- **PROJ-48** A project's row carries a Files button (`#project-files-<id>`) on
  every project but Elia's own: pressing it makes that project the open one
  (PROJ-8, PROJ-28) and opens the Files page (EXPL-6), which browses it
  (EXPL-15).
- ~~**PROJ-24** The chat sidebar groups chats by project: a header per project
  (`#project-header-<id>`) with the project's name and a "New chat" button
  (`#new-chat-<id>`) starting a chat in it (PROJ-26), and that project's chats
  below, newest first at the top level (UI-4), with a task chat nested under
  its parent, oldest first (UI-45). Projects with no chats still show their
  header.~~ Retired: the list holds the open project's chats and no other
  project's (PROJ-28, PROJ-31, UI-4), so there is nothing left to group, and a
  task chat is still nested under its parent (UI-45).
- ~~**PROJ-25** The header on every page has a "Projects" link (`#projects-link`)
  next to the header's "Chats" control (UI-32, the chat list's drawer toggle
  wherever there is no chat list on the page itself).~~ Retired: the header
  shows the open project next to the logo instead (PROJ-29), and the projects
  page (PROJ-23) is reached from the switcher's menu (PROJ-30).
- **PROJ-26** `/p/<project id>/new` starts a chat in that project (PROJ-11) and
  redirects to `/c/<new id>`; an unknown project id redirects to `/`. The
  sidebar's "New chat" button (UI-31) starts a chat in the open project
  (PROJ-28), which is the open chat's project when the page shows one.
- **PROJ-28** The open project — the project the interface works in — is
  `Elia.Projects.default/0` (PROJ-8): the one the switcher (PROJ-29) last
  opened, or a chat was last started in (PROJ-11, PROJ-26), and it is still
  that one after a restart. Opening a chat opens its project: a page showing a
  chat (UI-2) makes that chat's project (PROJ-9) the open one. The open project
  is what the header names (PROJ-29) and the only project whose chats the chat
  list holds (PROJ-31, UI-4).
- **PROJ-29** Every page's header shows the open project next to the logo: its
  name (PROJ-1) stands where the header showed the app's name, as the trigger
  of the project switcher (`#project-switcher`) — so with Elia's own project
  open it reads "Elia" (PROJ-3). Pressing it lists every project
  (`#project-option-<id>`, in `list/0` order, PROJ-4), the open one marked with
  `data-open="true"`, and choosing one makes it the open project (PROJ-8,
  PROJ-28) and opens its chat list: `/chats` for that project (UI-77), which
  resumes its most recent chat or starts a chat in it — except on the Files
  page, which it switches in place instead (EXPL-29). The menu closes when a
  project is chosen, on Escape, and on a press outside it.
- **PROJ-30** The switcher's menu ends with an entry (`#manage-projects-link`)
  leading to the projects page (PROJ-23), labelled for what that page holds —
  every project, with the form that creates one and the button that deletes one
  — rather than for creating alone. The header itself carries no "Projects" link
  (PROJ-25).

### Creating a project by its name

- **PROJ-32** The projects root is the folder Elia makes a project's own folder
  in: `Elia.Projects.root/0` is `Elia.Settings`' `:projects_root` (CONF-1), and
  `~/elia-projects` when none is stored. It survives a restart and is never
  committed (CONF-4).
- **PROJ-33** `Elia.Projects.set_root/1` stores the projects root, trimmed and
  expanded, so `~` and a relative path resolve to a folder; a blank value is
  `{:error, :blank_root}` and leaves the stored root alone.
- **PROJ-34** `Elia.Projects.create/1` takes a project's name alone and makes it
  in the folder the projects root names for it (PROJ-32): the folder's name is
  the project's name lowercased, with every run of characters that are neither
  letters nor digits replaced by `-` and leading and trailing `-` removed. A
  blank name, and a name whose folder comes out empty, are
  `{:error, :blank_name}`.
- **PROJ-35** The folder is created with its parents, so a projects root that is
  not there yet is made as well. A folder that is already there and holds
  anything is `{:error, :folder_exists}` — creation never writes into a folder
  that is not the one it makes — a folder that couldn't be made is
  `{:error, :folder_failed}`, and neither saves a project (PROJ-6). A folder
  that is there and holds nothing is used, so creating again after a failed
  attempt works.
- **PROJ-36** The new folder is a git repository with one commit: `git init`
  where the folder has no repository, a `README.md` naming the project and an
  `AGENTS.md` for the chats that will work there, each written only when the
  folder has no such file, and the two committed as the initial commit.
- **PROJ-37** The initial commit uses the machine's git identity; where git has
  none configured, creation supplies one derived from the machine's user, so
  creating a project does not fail for want of a git identity.
- **PROJ-38** Whatever stops the new folder becoming a repository with one
  commit — no git on the machine, git refusing to initialize the repository or
  to commit, a file that can't be written — does not fail the creation: the
  folder, what it holds and the project are still made, and `create/1` returns
  them as `{:ok, project, :no_repository}` rather than `{:ok, project}`
  (PROJ-41).
- **PROJ-39** The projects page's form (`#new-project`) takes a name and nothing
  else: creating makes the project's folder under the projects root (PROJ-32,
  PROJ-34), and the page shows that root beside the form (PROJ-40). Each error
  it can get reads as a message in `#project-error` — `:blank_name`,
  `:folder_exists` and `:folder_failed` — and nothing is added to the listing.
- **PROJ-40** The page shows the projects root and sets it: `#projects-root-path`
  holds it, an input (`#projects-root-input`) with a save button
  (`#save-project-root`) stores what the input holds (PROJ-33) and the page then
  shows the new root; a blank entry is shown in `#projects-root-error` and
  leaves the stored root alone.
- **PROJ-41** A creation whose repository was not set up (PROJ-38) says so in
  the flash: the project is named and the page says its git repository was not
  set up, rather than reporting a plain success.

## Out of scope

- The deploy workflow applies to Elia's own project only (PROJ-14): a chat in
  another project works directly in the project's folder, with no worktree —
  and so does a chat in Elia's own project, unless it makes one for itself
  (DEPLOY-1, DEPLOY-28).
- Projects have no per-project model, provider or settings.
- Creating a project by its name (PROJ-34 to PROJ-38) makes a folder and a
  repository and nothing else: no remote, no branch chosen, no dependency and no
  scaffolding beyond `README.md` and `AGENTS.md`, and a folder that is already
  there is never adopted (PROJ-35). Attaching a project to a folder that is
  already there — `Elia.Projects.create/2` (PROJ-6) — is not something the
  interface offers: the page makes a folder of its own.
- Creating a project is something the interface does. The agent has no tool for
  it, and `Elia.Projects.create/1` is not reachable from a chat.

## Stored data

Backward compatible, with nothing to migrate. The registry (PROJ-2) gains two
fields: a project's `color` (PROJ-1, PROJ-42) and a project's `allowlist`
(PROJ-1, PROJ-49). A file written before this change has neither, and a project
read without an `allowlist` has an empty one, which reaches nothing (NET-10),
and nothing is rewritten by that. Such a file has no colour, and a project read
without one takes `color: nil` (PROJ-2), which is
the colour its name derives (PROJ-43) — so such a file reads as a project with a
colour, and nothing is rewritten. A stored name the palette no longer holds
(PROJ-42) reads the same way, as `nil`. The file keeps its shape otherwise and
its version stays 1. Elia's own project, which the registry never holds
(PROJ-3), keeps its colour in the settings database, under a key of its own
(PROJ-44): a database written before this change has none, which reads as the
colour its name derives. Its allowlist is kept the same way, under a key of its
own (PROJ-49), and a database written before this change has none, which reads
as the empty list. The open project is the default project the settings
database already held (PROJ-8, PROJ-28): the same key and the same values, with
the meaning the interface gives it widened from "where a new chat starts" to
"the project the interface works in", so a value stored by an older version says
what it said. Nor does a chat's saved `project_id` (STORE-19) change: a chat
whose project is gone already resolved to Elia's own project when its session
loaded, which is now stated for a view too (PROJ-9, PROJ-12).

The projects root is one new key of the settings database (PROJ-32, PROJ-33):
the database holds keys and values, and one written before this change has no
value under `:projects_root`, which reads as the default root — so this too is
backward compatible, with nothing to migrate. The registry file keeps its shape:
a project made from a name is an ordinary project by PROJ-1, saved with the same
fields in the same file (PROJ-2), and the folder it made is a folder like any
other, so a project created this way and one attached to an existing folder are
indistinguishable afterwards.

## Implementation

`Elia.Projects`, `Elia.Settings`, `Elia.Workspace`, `Elia.Store`, `Elia.Agent`, `Elia.Agent.Session`,
`Elia.Agent.Loop`, `Elia.Skills`, `Elia.Skills.Harness`,
`Elia.Skills.Shell`,
`Elia.Skills.Folder`, `Elia.Skills.Tasks`, `Elia.Explorer`, `Elia.LLM.Context`,
`EliaWeb.ProjectsLive`, `EliaWeb.ChatLive`, `EliaWeb.ChatList`,
`EliaWeb.FilesLive`,
`EliaWeb.Router`, `EliaWeb.Layouts`.

## Tests

- `test/elia/projects_test.exs` (a project's shape, the file it is saved in,
  Elia's own project, `list/0`, `get/1`, `create/2`, `delete/1`, `default/0`,
  `chats_of/1` and the project a chat belongs to, a
  project whose folder is gone, the projects root and creating from a name,
  with the folder it makes, its errors, the repository and its initial commit
  and identity, the palette, a project's colour and `set_color/2` —
  PROJ-1 to PROJ-9, PROJ-27, PROJ-31 to PROJ-38, PROJ-42 to PROJ-44, PROJ-49).
- `test/elia/deployment_test.exs` (the deploy bound to Elia's own project, and
  the tree Elia's own data lives in whatever project a chat belongs to —
  PROJ-3, PROJ-13, PROJ-14).
- `test/elia/skills_test.exs` (a project's own skills, re-read for every step —
  PROJ-18 to PROJ-21).
- `test/elia/agent_test.exs` (a chat's project as its workspace, its system
  prompt and its skills — PROJ-9, PROJ-12, PROJ-15, PROJ-18).
- `test/elia/skills/harness_test.exs` (the instructions that apply in every
  project, PROJ-16).
- `test/elia/tasks_test.exs` (a sub-task's project, PROJ-10).
- `test/elia_web/live/projects_live_test.exs` (the Projects page, PROJ-23; the
  Files button in a project's row, PROJ-48; creating from a name, the projects
  root control and what the page says after a creation whose repository was not
  set up, a project's allowlist field and its Save — PROJ-39 to PROJ-41,
  PROJ-50).
- `test/elia_web/live/chat_live_test.exs` (a chat started in a project, and
  opening a chat of another project making it the open one — PROJ-8, PROJ-11,
  PROJ-12, PROJ-26, PROJ-28).
- `test/elia_web/live/project_switcher_test.exs` (the project the header names,
  its menu, choosing a project, the entry to the projects page and no
  "Projects" link — PROJ-28 to PROJ-30).
- `test/elia_web/live/project_colors_test.exs` (the picker on the projects page,
  the header's app icon in the open project's colour, and the swatch beside a
  project's name — PROJ-45 to PROJ-47).
- `test/elia_web/live/chat_list_test.exs` (a list holding the open project's
  chats only, a chat whose project is gone under Elia's own — PROJ-31).
- `test/elia_web/live/dashboard_test.exs` (the projects card and the default
  project, PROJ-8, PROJ-9).
- `test/elia_web/live/files_live_test.exs` (the project a page browses, and one
  whose folder is gone — PROJ-12, PROJ-27).
