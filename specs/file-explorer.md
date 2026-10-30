# File explorer

Status: Implemented

A Files page lets the user browse the workspace and read text files in the
browser, without opening a terminal or asking the agent. It is read-only and
deliberately small: a directory listing next to a plain-text viewer.

## Requirements

### Browsing (`Elia.Explorer`)

- **EXPL-1** Paths are relative to the workspace root. A path that resolves
  outside the workspace, or into a `:protected` path (WS-1: `.git`, `_build`,
  `deps`, `.elia`), is refused as forbidden and never read or listed.
- **EXPL-2** Any path that goes through a symlink is refused as forbidden, so a
  link can't lead out of the workspace.
- **EXPL-3** A directory listing has one entry per child with its name,
  relative path, type (directory, file, symlink or other) and, for files, size in
  bytes. Directories come first, then files, each sorted by name ignoring
  case. Protected entries at the root are left out.
- **EXPL-4** Reading a file returns its text and size. Files over 256 KiB are
  cut at 256 KiB and marked truncated. A file with a NUL byte or invalid UTF-8
  is reported as binary and its content is not returned.
- **EXPL-5** Missing paths, reading a directory and listing a file are
  reported as distinct errors (not found, directory, not a directory). Special
  files (sockets, FIFOs, devices) and I/O failures are "unreadable"; they are
  never opened.

### Files page

- **EXPL-6** `/files` shows the workspace root. The `path` query parameter
  selects a directory or a file: a directory is listed; a file is shown in the
  viewer next to the listing of its parent directory.
- **EXPL-7** The listing has a breadcrumb trail from the root to the current
  directory, a parent entry (except at the root), and entries that open
  directories or files by patching the URL, so back/forward and links work.
  Symlinks and special files are shown but not opened. The open file is highlighted.
- **EXPL-8** The viewer shows the file's relative path, size and line count,
  and its text with line numbers, in a monospace pane that scrolls instead of
  wrapping. Truncated files say so. Binary files show a notice instead of
  content.
- **EXPL-9** A path that is forbidden or missing shows a message, and the
  listing falls back to the workspace root.
- **EXPL-10** The app header has a "Files" link to `/files`.

## Out of scope

- Editing, creating, deleting or uploading files (use the agent's file tools).
- Syntax highlighting, search, images and Markdown rendering.
- Access control: like Sessions and System, anyone who can reach the app can
  read the (non-protected) workspace.

## Implementation

`Elia.Explorer` (path safety, listing, reading), `EliaWeb.FilesLive`.

## Tests

`test/elia/explorer_test.exs`, `test/elia_web/live/files_live_test.exs`.
