# File explorer

Status: Implemented

A Files page lets the user browse the workspace and read text files in the
browser, without opening a terminal or asking the agent. It is read-only and
deliberately small: a directory listing next to a plain-text viewer. It browses
a project's folder, or a single chat's own workspace (EXPL-17), which is where
a file the agent mentions in that chat is opened (FLINK-5).

## Requirements

### Browsing (`Elia.Explorer`)

- **EXPL-1** Paths are relative to the workspace root (the browsed project's
  folder, EXPL-15, or a chat's workspace, EXPL-17). A path that resolves
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

- **EXPL-15** The page browses one project at a time: a `project` query
  parameter names it, and paths are relative to that project's folder
  (PROJ-22). `/files` with a missing or unknown id browses Elia's own project,
  and EXPL-1–EXPL-5 apply to whichever folder is in view.
- **EXPL-16** The page names the project it browses and has a control
  (`#project-picker`) to switch to another one, which keeps the current path
  when it exists there and falls back to the root when it doesn't.

- **EXPL-17** The page can browse a chat's own workspace instead of a project
  folder: a `chat` query parameter names a saved chat (STORE), and paths are
  then relative to the workspace that chat works in (PROJ-12) — its own
  worktree when the chat is in Elia's own project (DEPLOY-1), its project's
  folder otherwise — with EXPL-1–EXPL-5 applying to that root as to any other.
  The project in view is the chat's own, so a `project` parameter alongside it
  doesn't override it. It is how a file the agent mentions is opened, so the
  page shows the file as that chat has it rather than the live tree's copy
  (FLINK-5). A `chat` that isn't a saved chat is ignored, and the page browses
  the project as EXPL-15 says. Resolving the workspace never creates one: a
  chat without a worktree is browsed in its project's folder.
- **EXPL-18** The page says which workspace it browses: the project as now
  (EXPL-16) and, with a chat in view, that chat beside it (`#workspace-note`: a
  chat icon and the chat's title, STORE-33 — "New chat" before it has one —
  with the root in its `title`), so a worktree is not mistaken for the project
  folder. The project picker (`#project-picker`) switches to that project's
  folder and leaves the chat behind — dropping `chat` from the URL — keeping
  the current path when it exists there (EXPL-16).

### Syntax highlighting

Highlighting runs in the browser. The server only names the language and
always sends the plain text, so the socket payload doesn't grow.

- **EXPL-11** `Elia.Explorer.language/1` maps a file path to a highlight.js
  language name from its extension or, for a few well-known files, its base
  name (`Makefile`, `Dockerfile`, `mix.lock`). Matching ignores case. Unknown
  files have no language.
- **EXPL-12** The content element carries `data-language` when the language is
  known and the file is at most 128 KiB; otherwise it is left unhighlighted.
  A truncated file is never highlighted.
- **EXPL-13** A client hook on the content element highlights it with a
  bundled highlight.js (core plus a fixed set of languages) when it mounts and
  after each update, replacing its text with the highlighted markup. The
  highlighted text equals the original, so line numbers still line up. If
  highlighting fails the plain text stays.
- **EXPL-14** Token colours come from the daisyUI theme variables, so they
  follow the light/dark toggle without a separate highlight theme.

## Out of scope

- Editing, creating, deleting or uploading files (use the agent's file tools).
- Search, images and Markdown rendering. Highlighting covers a fixed set of
  languages only.
- Access control: like Sessions and System, anyone who can reach the app can
  read the (non-protected) workspace.

## Implementation

`Elia.Explorer` (path safety, listing, reading, language detection),
`EliaWeb.FilesLive` (which workspace it browses, EXPL-15 - EXPL-18),
`Elia.Deploy` (a chat's workspace, EXPL-17), `EliaWeb.FileLinks` (the links that
open a chat's own workspace, FLINK),
the `Highlight` hook in `assets/js/highlight.js`, and
highlight.js vendored in `assets/vendor/highlight/` (BSD-3-Clause).

## Tests

`test/elia/explorer_test.exs`, `test/elia_web/live/files_live_test.exs` (the
project and the chat in view, EXPL-15 - EXPL-18).
