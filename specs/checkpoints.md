# Checkpoints

Status: Retired

Retired: the filesystem isolation of per-chat worktrees (DEPLOY) replaced this
feature, as it replaced guarded files. Checkpoints existed to make the agent's
own edits undoable *while it edited the tree the server ran from*: the first
change of a turn snapshotted the workspace, so a bad turn could be rolled back
by the agent (the `rollback` tool), by the end-of-turn verification (VERIFY-4),
or by `/recover` when the app no longer compiled (RECOVER). A chat in Elia's own
project now edits its own git worktree on its own branch (DEPLOY-1), so a bad
turn cannot reach the running tree, and ordinary git is the undo: the chat's own
branch, the trunk `master`, and the deploy gate, which refuses to load a tree
whose suite or compile fails (DEPLOY-5, HOT-4). Nothing snapshots the workspace
any more, and no write takes a checkpoint (SHELL-6 is
retired with it). See `specs/deployment.md`.

## Requirements

- ~~**CKPT-1** A checkpoint is a git commit stored under
  `refs/elia/checkpoints/<ms timestamp>-<short sha>` and authored by
  "Elia <elia@localhost>". It is built with a temporary index, so HEAD, the
  current branch and the user's index stay unchanged.~~ Retired: nothing
  snapshots the workspace.
- ~~**CKPT-2** Snapshots include untracked files and respect `.gitignore`.
  The first change in a turn (from shell, file writes or script tools) takes
  one checkpoint for that turn; later changes in the same turn reuse it.~~
  Retired: the shell tool's checkpoint (SHELL-6) is gone with it, and no file
  write takes one.
- ~~**CKPT-3** If a checkpoint can't be taken, the tool that would change the
  workspace fails with an error and doesn't run.~~ Retired: there is no
  checkpoint to fail.
- ~~**CKPT-4** `changed_files(sha)` returns the absolute paths of files that
  differ between the checkpoint and the current workspace.~~ Retired: its only
  caller was the end-of-turn verification (VERIFY-3).
- ~~**CKPT-5** Rolling back restores the checkpoint's files and deletes files
  added since then. It first snapshots the current state and returns that
  snapshot's sha, so a rollback can be undone.~~ Retired: nothing rolls back.
- ~~**CKPT-6** `list_checkpoints` returns recent checkpoints, newest first,
  as `<short sha>  <timestamp>  <label>`.~~ Retired: the tool is gone.
- ~~**CKPT-7** The `rollback` tool needs approval. It rolls back to the given
  sha, or to this turn's checkpoint by default. It reloads skills and reports
  the sha to undo with. Running code doesn't change until a deploy.~~ Retired:
  in a worktree the chat's own branch is the undo, through ordinary git, and
  the trunk `master` is never touched by a turn.
- ~~**CKPT-8** Turn → checkpoint mappings are kept in memory only and are lost
  on restart. The refs stay.~~ Retired: there are no mappings.
- ~~**CKPT-9** Each entry from `list/1` also has the `tree` of the snapshot, and
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
  recurs through editing doesn't count: then all checkpoints are considered.~~
  Retired: its only caller was the recovery page (RECOVER-3), which is gone.
- ~~**CKPT-10** `rebase(turn_id)` replaces the checkpoint of a turn that has one
  with a new snapshot of the workspace as it is now, labelled
  `before agent turn <id> (after sub-task)`. A turn with none is left alone
  (its first change takes one, CKPT-2). Used by `reset_task` when the reset
  changed the caller's own workspace (an in-place sub-task, SUBTASK-22), so a
  later rollback of the caller can't restore the discarded work.~~ Retired:
  `reset_task` is gone (SUBTASK-22), and there is no rollback to guard against.

## Implementation

Removed: `Elia.Checkpoint` (and its child in `lib/elia/application.ex`), the
`Checkpoint.ensure/2` calls in `Elia.Skills.{Files,Shell,Folder}`, the
`Checkpoint.rebase/2` call in `Elia.Tasks`, and `Elia.Harness.verify/2`'s
rollback with it.

## Tests

The checkpoint tests in `test/elia/self_modification_test.exs`,
`test/elia/agent_test.exs` and `test/elia/tasks_test.exs` are removed, as is
`test/support/fake_checkpoints.ex`.
