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
- **CKPT-9** Each entry from `list/1` also has the `tree` of the snapshot, and
  `current_tree/0` returns the tree of the workspace as it is now.
  `recommended(checkpoints, current_tree)` picks the best rollback target from
  the newest-first list: the newest checkpoint labelled `before agent turn …`
  whose tree differs from `current_tree`. It returns `nil` if there is none,
  so a rollback to it always changes something.

  If the workspace is exactly the result of the most recent rollback (the
  newest `before rollback to <sha>` snapshot names a checkpoint in the list
  whose tree equals `current_tree`), only checkpoints older than that target
  are considered, so the recommendation moves further back and never forward
  to a state that was just left, such as a turn checkpoint taken by a
  read-only shell command after the damage was done. A state that merely
  recurs through editing doesn't count: then all checkpoints are considered.

- **CKPT-10** `rebase(turn_id)` replaces the checkpoint of a turn that has one
  with a new snapshot of the workspace as it is now, labelled
  `before agent turn <id> (after sub-task)`. A turn with none is left alone
  (its first change takes one, CKPT-2). Used by `reset_task` when the reset
  changed the caller's own workspace (an in-place sub-task, SUBTASK-22), so a
  later rollback of the caller can't restore the discarded work.

## Implementation

`Elia.Checkpoint`, `Elia.Skills.Harness`.

## Tests

`test/elia/self_modification_test.exs`, `test/elia_web/recovery_test.exs` (CKPT-6 ordering).
