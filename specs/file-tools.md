# File tools

Status: Implemented

`read_file`, `write_file` and `edit_file` let the agent work with files
without the shell. Whether a call needs approval depends on the path's
workspace class.

## Requirements

- **FILE-1** Paths are resolved relative to the workspace root.
- **FILE-2** `read_file` returns up to 2,000 lines, starting at `offset`
  (1-based, default 1). `limit` can lower the count but never raise it above
  2,000.
- **FILE-3** When only part of a file is returned, the output starts with
  `[lines <first>-<last> of <total>]`.
- **FILE-4** `read_file` needs approval only for paths outside the workspace.
- **FILE-5** `write_file` and `edit_file` follow the path's class (WS-1):
  extension → no approval; core → approval; protected or outside → refused,
  naming the path.
- **FILE-6** `write_file` creates parent directories and overwrites the
  file.
- **FILE-7** `edit_file` replaces `old_string` with `new_string`. It fails if
  `old_string` is empty or not found, or if it occurs more than once and
  `replace_all` isn't set. The error says how many times it occurs.
- **FILE-8** Both write tools checkpoint the workspace before their first
  change in a turn (CKPT-2). `edit_file` checks the replacement before taking
  the checkpoint.
- **FILE-9** Success results name the relative path and the bytes written or
  the number of replacements.
- **FILE-10** The skill's instructions open by telling the model to use these
  tools, not shell commands (`cat`, `sed`, `echo >`, scripts), to read, create
  and edit files, because the file tools apply the workspace policy (WS-1).
- **FILE-11** Calls to `write_file` and `edit_file` for the same file are
  serialised, so concurrent calls (LOOP-10) never lose each other's changes:
  every successful call's change is in the final file. The order between
  concurrent calls isn't guaranteed, so an edit that depends on another edit to
  the same file may fail with "old_string not found". Calls for different files
  don't wait for each other.

## Implementation

`Elia.Skills.Files`.

## Tests

`test/elia/self_modification_test.exs`.
