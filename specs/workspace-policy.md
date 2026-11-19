# Workspace policy

Status: Implemented

The workspace is the directory the agent works in: by default, Elia's own
source tree, or the folder of the chat's project (PROJ-12). Every path is put
in a class that decides what the agent's tools may do with it.

Since the file tools were retired (FILE) a class no longer decides what may be
written — a file is written by a command, and the jail is what confines that
command (ISOL-13) — so the classes decide where a chat may stand (`cd`, WD-5),
what a host-side read refuses (a folder skill's instruction file, SKILL-17) and
what the Files page may link (FLINK-5).

A path is put in a class by how it is written (WS-1 to WS-3) and judged by
where it lands where the written path would hide what it reaches (WS-7 to
WS-9): a link inside the workspace can otherwise name a protected or an outside
target as an ordinary path, and a host-side read that never asks for approval
(a link read as the project's instructions, SKILL-17) has no second check
behind it. No stored shape changes: nothing here alters what is saved or how it
is read.

## Requirements

- **WS-1** Paths are classified as:

  | Class | Paths |
  | --- | --- |
  | `:extension` | under `skills/` |
  | `:core` | the rest of the workspace |
  | `:protected` | `.git`, `_build`, `deps`, `.elia` at the root |
  | `:outside` | anything outside the workspace |

  What the class decides is where a chat may stand (WD-5), what a host-side
  read refuses (SKILL-17) and what the Files page may link (FLINK-5). No class
  decides what may be written: a file is written by a command, which the jail
  confines (ISOL-13).
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
  the rest of the path appended, so a path that isn't there is still judged by
  where it would land. The classes of WS-1 are decided on the path as
  written (WS-2, WS-3 — a `skills/` path that goes through a symlink is `:core`),
  which is what `Elia.Workspace.classify/2` answers; WS-7 to WS-9 judge a path
  by where it lands, and a caller that must not be fooled by a link — `cd`
  (WD-5) or a folder skill's instruction read (SKILL-17) — compares real
  locations itself.
- **WS-6** `real_location/1` follows at most eight links for one path, each
  link counting once, wherever it is in the path. A path whose links it can't
  finish within that bound — a longer chain, or a loop — has no real location:
  `real_location/1` returns `:unresolvable` for it, never a path inside the
  workspace, so the callers that judge a path refuse it (WD-5, SKILL-17).
- **WS-7** A path whose real location (WS-5) is `:protected` is treated as
  protected however it is written: a path in the workspace that resolves into
  `.git`, `_build`, `deps` or `.elia` at the root is refused where a protected
  path is (WD-5, SKILL-17), so a link — or a directory reached through one —
  cannot turn a protected target into an ordinary one.
- **WS-8** A path whose real location (WS-5) is `:outside` the workspace is
  treated as outside however it is written, so a path inside the workspace that
  resolves out of it is refused as an outside path (WD-5, SKILL-17, FLINK-5).
- **WS-9** A path with no real location (WS-6) — a link chain past the bound, or
  a loop — is refused, naming the path, by every host-side read that judges a
  path, rather than treated as a path inside the workspace.

## Out of scope

This is a policy boundary in the BEAM process, not a second jail. It does not
run a file operation in bubblewrap, so a refusal is not atomic at the kernel:
where the jail's own mount namespace would make a link out of the workspace a
dangling path, the refusal here is decided in the process that reads the file.
The read is resolved once and the resolved path is used (WD-5, SKILL-17), which
closes the window in which a link is swapped for another between the decision
and the operation; what it does not close is a *real* component of a resolved
path being replaced by a link afterwards. What a command reads or writes is
decided by its jail alone (ISOL-13), which is the kernel's own boundary and not
this one.

Also out of scope: the folder skills' own metadata reads, which are host reads
of `SKILL.md` and the skill's scripts as well. They are the same ingress and
need the same confinement, and are deliberately not covered by this change.

Nothing above is a requirement; this section records what the change
deliberately leaves out.

## Implementation

`Elia.Workspace` (the classes of WS-1, and `real_location/1` for where a path
lands — WS-5), with the callers that judge a path by its referent:
`Elia.Workdir` (`cd`, WD-5) and `Elia.Skills` (SKILL-17, SKILL-18).

## Tests

- `test/elia/self_modification_test.exs` (each class a path can be, a `..` and a
  link resolved before it is judged, a path that isn't there, the real
  location of a path, a link chain at and past the bound, a path judged by where
  it lands when that is protected, outside or unresolvable — WS-1 to WS-3, WS-5
  to WS-9).
- `test/elia/deployment_test.exs` (the workspace root, and the live tree Elia's
  own data and skills folder live under — WS-4).
- `test/elia_web/file_links_test.exs` (the class a mentioned path falls in,
  WS-1).