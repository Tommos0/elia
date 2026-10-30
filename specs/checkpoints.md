# Checkpoints

Status: Implemented

Before the agent changes anything, the workspace is snapshotted to a git ref,
so a bad turn can be undone. Snapshots never disturb the user's own git
state.

## Requirements

- **CKPT-1** A checkpoint is a git commit stored under
  `refs/elia/checkpoints/<ms timestamp>-<short sha>` and authored by
  "Elia <elia@localhost>". It is built with a temporary index, so HEAD, the
  current branch and the user's index stay unchanged.
- **CKPT-2** Snapshots include untracked files and respect `.gitignore`.
  The first change in a turn (from shell, file writes or script tools) takes
  one checkpoint for that turn; later changes in the same turn reuse it.
- **CKPT-3** If a checkpoint can't be taken, the tool that would change the
  workspace fails with an error and doesn't run.
- **CKPT-4** `changed_files(sha)` returns the absolute paths of files that
  differ between the checkpoint and the current workspace.
- **CKPT-5** Rolling back restores the checkpoint's files and deletes files
  added since then. It first snapshots the current state and returns that
  snapshot's sha, so a rollback can be undone.
- **CKPT-6** `list_checkpoints` returns recent checkpoints, newest first,
  as `<short sha>  <timestamp>  <label>`.
- **CKPT-7** The `rollback` tool needs approval. It rolls back to the given
  sha, or to this turn's checkpoint by default. It reloads skills and reports
  the sha to undo with. Running code doesn't change until `hot_reload`.
- **CKPT-8** Turn → checkpoint mappings are kept in memory only and are lost
  on restart. The refs stay.

## Implementation

`Elia.Checkpoint`, `Elia.Skills.Harness`.

## Tests

`test/elia/self_modification_test.exs`, `test/elia_web/recovery_test.exs` (CKPT-6 ordering).
