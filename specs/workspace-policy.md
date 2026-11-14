# Workspace policy

Status: Implemented

The workspace is the directory the agent works in: by default, Elia's own
source tree, or the folder of the chat's project (PROJ-12). Every path is put
in a class that decides what the agent's tools may do with it.

## Requirements

- **WS-1** Paths are classified as:

  | Class | Paths | File tools may write |
  | --- | --- | --- |
  | `:extension` | under `skills/` | yes, without approval |
  | `:core` | the rest of the workspace | with approval |
  | `:protected` | `.git`, `_build`, `deps`, `.elia` at the root | never |
  | `:outside` | anything outside the workspace | never |

- **WS-2** Paths are fully expanded before they are classified, so `..`
  can't escape the workspace (`skills/../../etc` is `:outside`).
- **WS-3** A path under `skills/` that goes through a symlink is `:core`, so
  a symlink can't give extension rights to files elsewhere.
- **WS-4** The workspace root is a project's folder (PROJ-12), or Elia's own
  root — `config :elia, :workspace`, or the current directory if unset — for
  Elia's own project. The skills folder is `<root>/skills` and harness data is
  always in `.elia` under Elia's live tree (`Elia.Workspace.runtime_root/0`,
  which defaults to Elia's root; PROJ-13, DEPLOY-2).
- **WS-5** A path's *real location* can be asked for
  (`Elia.Workspace.real_location/1`): its path with symlinks followed, and, for
  a path that doesn't exist yet, the same for its deepest existing ancestor with
  the rest of the path appended, so a write target that isn't there is still
  judged by where it would land. The classes of WS-1 are decided on the path as
  written (WS-2, WS-3 — a `skills/` path that goes through a symlink is `:core`);
  a caller that must not be fooled by a link, like the file tools under the jail
  (FILE-13), compares real locations itself.

## Implementation

`Elia.Workspace`.

## Tests

- `test/elia/self_modification_test.exs` (each class a path can be, a `..` and a
  link resolved before it is judged, a write target that isn't there, the real
  location of a path — WS-1 to WS-3, WS-5).
- `test/elia/deployment_test.exs` (the workspace root, and the live tree Elia's
  own data and skills folder live under — WS-4).
- `test/elia_web/file_links_test.exs` (the class a mentioned path falls in,
  WS-1).
