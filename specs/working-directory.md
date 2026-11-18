# Working directory

Status: Implemented

A chat has a working directory: the directory its file tool calls (FILE) and
its `shell` call (SHELL) resolve a relative path against. It starts as the
chat's workspace root (PROJ-12, WS-4), and the `cd` tool changes it, so a chat
can work inside one part of a tree — the package of a monorepo, a subdirectory
of a project — without repeating the prefix in every path it names.

It is the chat's own state, like its title or its jail setting: saved with the
chat (STORE-46), so a restart, a deploy or a resumed turn doesn't send the chat
back to the root. It changes what a relative path *names*, never what a path is
*allowed* to be: every path is still judged by its own class (WS-1) and its own
real location (WS-5), so a chat cannot reach more of the machine by standing
somewhere else.

## Requirements

- **WD-1** A chat has a working directory — the directory a file tool call
  (FILE) and a `shell` call (SHELL-2) resolve a relative path against — which
  starts as the chat's workspace root (PROJ-12, WS-4).
- **WD-2** The working directory belongs to the chat, not to a turn: it outlives
  the turn that set it, the session process and a restart, because it is saved
  with the chat (STORE-46).
- **WD-3** `cd` sets the chat's working directory to the directory that `path`
  names — an absolute path, or one relative to the current working directory —
  and returns the new directory relative to the workspace root, `.` for the root
  itself.
- **WD-4** `cd` with no `path` changes nothing and returns the current working
  directory in the form of WD-3, so a chat can ask where it is.
- **WD-5** `cd` fails, changing nothing and naming the path and the reason, when
  the path does not exist, is not a directory, has no real location (WS-6), or
  whose real location (WS-5) is outside the workspace (WS-8).
- **WD-6** `cd` never needs approval: it changes no file and grants no reach of
  its own, since every path a tool is given later is judged by its own class
  (WS-1) whether the chat changed directory or not.
- **WD-7** A saved working directory that is no longer a directory inside the
  chat's workspace — what a workspace that has moved leaves behind — reads as
  the workspace root when the chat loads, and a chat working in its workspace
  root carries no `cwd` entry at all (STORE-46).
- **WD-8** A relative path given to a file tool resolves against the working
  directory (FILE-1), while what the tools return keeps naming paths relative
  to the workspace root (FILE-9, FILE-15, FILE-26), so a result reads the same
  wherever the chat stands.
- **WD-9** A `shell` call runs its command in the working directory (SHELL-2).
- **WD-10** A `cd` takes effect from the next step: the calls of one step run at
  the same time (LOOP-10) and every one of them resolves against the directory
  as it was when the step began, so a `cd` never moves a call of its own step.
- **WD-11** The `workdir` skill's instructions and the `cd` tool's description
  say what the working directory is, that a relative path resolves against it,
  and that `cd` changes it and needs no approval (WD-6); the `files` skill's
  instructions and the `shell` skill's instructions and tool description say
  where a relative path resolves and that `cd` changes it, since `cd` is not one
  of their own tools.
- **WD-12** `cd` called with no chat to change the directory of returns an error
  result naming that, and changes nothing.

## Stored data

A saved chat gains one optional key, `cwd`: the chat's working directory as an
absolute path, written only when it isn't the workspace root (STORE-46, WD-7).
The change is backward compatible and needs no migration: a chat saved before
it has no `cwd` key and reads exactly as it did — its working directory is its
workspace root, which is where its tools ran until now (WD-1). Nothing else in
the file changes shape, and no other stored data is read or written.

## Out of scope

- A chat's terminal (TERM): it keeps its own pty and its own lifetime, and
  moving the chat's working directory doesn't move it. `cd` inside the terminal
  is the terminal shell's own business.
- A folder skill's script tool (FOLDER), `Elia.Harness.run_tests/3` and the
  deploy's own commands: each keeps running in the tree it is given, not in the
  chat's working directory.
- `spawn_task`: a child still starts in the parent's workspace (the live tree in
  Elia's own project), not in the parent's working directory, and a child's
  working directory is its own (SUBTASK).
- Nothing of the UI: the chat's page and its settings page don't show the
  working directory, a `cd` card keeps the default icon and reads `Using cd`
  (UI-15), and its calls count under "Other tools" in the context breakdown
  (CTX-5).
- `cd` is not a shell: there is no `~`, no globbing, no `-` for the previous
  directory and no environment. It names one directory, and a chat that wants a
  shell's own `cd` has the terminal for it.
- The `deps` and `.git` of the live tree are `:protected` paths (WS-1), so `cd`
  into them is refused even though a jailed command may reach them (ISOL-25); a
  command can still name such a path
  absolutely.

## Implementation

`Elia.Workdir` (the working directory of a tool call's context, and the
resolution and refusal of WD-5), `Elia.Skills.Workdir` (the skill and its `cd`
tool), `Elia.Agent.Session` (the `:cwd` state, `{:set_cwd, path}` and `:cwd`
calls, saving and loading of WD-2 and WD-7) with `Elia.Agent.set_cwd/2`, and
`Elia.Store`'s `cwd:` option and `load_cwd/1` (STORE-46). The callers that
resolve a relative path through it are `Elia.Skills.Files` (FILE-1),
`Elia.Skills.Shell` (SHELL-2) and `Elia.Agent.Loop`, which refreshes the step's
working directory from the session at the start of each step (WD-10).

## Tests

- `test/elia/working_directory_test.exs` (the context's working directory, the
  file tools and the shell resolving through it, `cd` setting it and reporting
  it, each refusal, its persistence across a session and a restart, the step
  boundary and the instructions — WD-1 to WD-12, and the stored key of
  STORE-46).
