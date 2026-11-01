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

## Implementation

`Elia.Workspace`.

## Tests

`test/elia/self_modification_test.exs`.
