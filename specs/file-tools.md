# File tools

Status: Implemented

`read_file`, `write_file`, `edit_file`, `list_files` and `delete_file` let the
agent work with files without the shell: read, create and change a file, list a
directory, and remove a file or an empty directory. Whether a call needs
approval depends on the path's workspace class, and a chat whose jail is on can
only reach its own workspace — so the file tools reach no further than a jailed
command does (ISOL-25).

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
- **FILE-8** `edit_file` checks that `old_string` occurs as requested (FILE-7)
  before it writes anything.
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
- **FILE-12** With the jail on for the chat (ISOL-16, ISOL-20), the file tools
  reach the workspace and nothing else: `read_file` on a path outside it is
  refused, naming the path, instead of asking for approval (FILE-4), and
  `write_file` and `edit_file` on such a path are refused as they are with the
  jail off (FILE-5). With the jail off, FILE-4 and FILE-5 are unchanged, so the
  user can still hand the agent a file outside the workspace by approving the
  read. The confinement follows the chat's jail decision and the host's, and not
  what bubblewrap can do: where the jail can't be built (ISOL-12) a command runs
  unjailed, but the file tools are confined all the same, since it is the user
  who turns the jail off when they want them to reach further.
- **FILE-13** The confinement follows real locations, not the path as written
  (WS-5), so a path inside the workspace that resolves through a symlink to a
  location outside it — a link to a credential, or to the settings database the
  jail hides (ISOL-5) — is refused too. Inside means what a jailed command in
  this workspace can reach besides the toolchain (ISOL-25): the workspace, and,
  for a chat worktree, the trees the jail's profile also binds there — the
  repository's git directory and the shared `deps` (ISOL-4, ISOL-13) — with
  `.elia` left out where the live tree is masked (ISOL-6). A path that doesn't
  exist yet is judged by its deepest existing ancestor, so `write_file` can
  still create a file and its parent directories (FILE-6).
- **FILE-14** The skill's instructions say that with the jail on the tools can't
  reach outside the workspace, so such a path is refused rather than offered for
  the user's approval (FILE-12), and that a symlink is followed no further than
  the workspace (FILE-13).
- **FILE-15** `list_files` lists one level of the directory at `path`, which
  defaults to the workspace root (FILE-1). The result's first line is
  `[<dir> (<n> entries)]`, with `<dir>` the directory's path relative to the
  workspace root (`.` for the root itself) and `<n>` the number of entries in
  it; then one line per entry, named by its path relative to the workspace
  root: a directory with a trailing `/`, a file with its size in bytes, a
  symlink with `->` and the target it points at, and anything else by name
  alone. Directories come before the rest, and each group is sorted by name
  case-insensitively. Entries are listed as they are — dotfiles and protected
  paths (WS-1) included, since reading them is not refused either.
- **FILE-16** `list_files` returns at most 200 entries. `limit` can lower the
  count but never raise it above 200. When entries are left out, the result
  ends with `[+<n> more entries]`, and the entries shown are the first ones in
  the order of FILE-15, so the rest can be reached by listing a subdirectory.
- **FILE-17** `list_files` fails, naming the path and the reason and changing
  nothing, when the path is missing or isn't a directory (a file path is read
  with `read_file`). An empty directory gives the header line and no entries.
- **FILE-18** Approval for `list_files` follows the read policy (FILE-4): it is
  never asked inside the workspace and required for a path outside it, and with
  the jail on a path outside the workspace — or one that resolves out of it
  (FILE-13) — is refused, naming the path, instead of being offered for
  approval (FILE-12).
- **FILE-19** `delete_file` removes the file, symlink or empty directory at
  `path`, and its result names the deleted path relative to the workspace root.
  It fails, naming the path and changing nothing, when the path doesn't exist,
  and when the path is a directory that isn't empty.
- **FILE-20** A symlink is deleted as a link, never followed: the delete
  removes the link itself and leaves whatever it points at alone. Whether it
  may be touched is decided like any other path (FILE-21), so with the jail on
  a link that resolves out of the workspace is refused (FILE-13), and with the
  jail off the class of the path as written decides (WS-1).
- **FILE-21** `delete_file` follows the path's class (FILE-5): under `skills/`
  without approval, other workspace files with approval, and a protected or
  outside path refused, naming the path. With the jail on, a path outside the
  workspace — or one that resolves out of it (FILE-13) — is refused as it is
  with the jail off (FILE-12).
- **FILE-22** `delete_file` takes the same per-file lock as `write_file` and
  `edit_file` (FILE-11), so a delete never races a write or edit of the same
  path.
- **FILE-23** Every list of the file tools names all five: the skill's
  description and instructions say the tools also list a directory and delete a
  file or empty directory, and that deleting needs the same approvals as
  writing (FILE-21); the `shell` tool's description sends file work to all five
  (SHELL-8); and the chat's tool card gives them its document icon (UI-15).

## Implementation

`Elia.Skills.Files` (the tools and the policies), with
`Elia.Workspace.real_location/1` (WS-5) and `Elia.Shell.reachable?/2` (ISOL-25)
for the confinement. `Elia.Explorer` (EXPL-3) lists directories for the
`/files` page with its own rules — protected paths filtered out, symlinks
refused — so `list_files` doesn't share it.

## Tests

`test/elia/self_modification_test.exs` (the policies, jail on and off, the
symlink escape, and the tools), `test/elia/shell_test.exs` (the jail's reach),
`test/elia/skills/files_test.exs` (the instructions).
