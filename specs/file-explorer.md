# File explorer

Status: Implemented

A Files page lets the user browse the workspace and read its files in the
browser, without opening a terminal or asking the agent. It is read-only and
deliberately small: a directory listing next to a viewer that shows a text file
as plain text and previews what the browser renders itself — a picture, a PDF, a
video, an audio file (EXPL-22). It browses a project's folder, or a single
chat's own workspace (EXPL-17), which is where a file the agent mentions in that
chat is opened (FLINK-5).

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
- **EXPL-20** The browsed root (EXPL-15, EXPL-17) is judged by what it points
  at, so a root that is itself a symlink to a directory is listed and browsed
  as any other root is, while a path through a symlink *inside* it is still
  refused (EXPL-2).
- **EXPL-21** A browsed root whose link leads to something that is not a
  directory, to nothing, or into a chain that can't be followed is reported as
  EXPL-19 says for a root that can't be listed: not a directory, not found, or
  unreadable.

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
  listing falls back to the browsed root (EXPL-19 when the root itself is what
  can't be browsed).
- **EXPL-10** The app header has a "Files" link to `/files`.

- **EXPL-27** A `line` query parameter names a line of the file in view: the
  viewer marks that line and brings it into sight, so a link that names a file
  and a line (CITE-10) opens the file where that line is. A `line` that is not a
  positive whole number, that is past the text shown, or that comes with no text
  in view — a previewed file has none (EXPL-23) — is ignored, and the file opens
  as it otherwise would.
- **EXPL-28** The line belongs to the file it was named with: opening another
  file or directory leaves it out of the URL, so no file shows a line marked
  that belongs to another one.

- **EXPL-15** The page browses one project at a time: a `project` query
  parameter names it, and paths are relative to that project's folder
  (PROJ-22). `/files` with a missing or unknown id browses Elia's own project,
  and EXPL-1–EXPL-5 apply to whichever folder is in view.
- **EXPL-16** The page names the project it browses and has a control
  (`#project-picker`) to switch to another one, which keeps the current path
  when it exists there and falls back to the root when it doesn't.

- **EXPL-17** The page can browse a chat's own workspace instead of a project
  folder: a `chat` query parameter names a saved chat (STORE), and paths are
  then relative to the workspace that chat works in (PROJ-12) — its project's
  folder, which for a chat in Elia's own project is the live tree (DEPLOY-1) —
  with EXPL-1–EXPL-5 applying to that root as to any other.
  The project in view is the chat's own, so a `project` parameter alongside it
  doesn't override it. It is how a file the agent mentions is opened, so the
  page shows the file as that chat's workspace has it (FLINK-5). A `chat` that
  isn't a saved chat is ignored, and the page browses
  the project as EXPL-15 says. Resolving the workspace never creates anything.
- **EXPL-18** The page says which workspace it browses: the project as now
  (EXPL-16) and, with a chat in view, that chat beside it (`#workspace-note`: a
  chat icon and the chat's title, STORE-33 — "New chat" before it has one —
  with the root in its `title`), so a chat's workspace is not mistaken for the
  project folder on its own. The project picker (`#project-picker`) switches to that project's
  folder and leaves the chat behind — dropping `chat` from the URL — keeping
  the current path when it exists there (EXPL-16).

- **EXPL-19** When the browsed root itself can't be listed — the folder is
  missing, unreadable or not a directory — the page shows a message saying so,
  naming the root, in place of EXPL-9's path message, and the listing is empty:
  it neither shows another directory's entries nor says the directory is empty.
  The page stays otherwise usable — the project name, the picker
  (`#project-picker`) and, with a chat in view, the workspace note (EXPL-18) —
  so it can be left by switching project, and no other folder is browsed.

### Previews

A file the browser can render itself is shown as that, on the page, instead of
being read and shown as text: an image as a picture, a PDF in the browser's own
viewer, a video and an audio file with the browser's own controls. The page
hands the browser a URL to the file and the browser fetches the bytes from the
workspace itself (EXPL-24), so a preview of any size is served whole, the page
never holds a file's bytes in memory, and a large one is not read again when the
page is opened again.

- **EXPL-22** `Elia.Explorer.preview/1` names what the browser renders of a
  path, from its extension and ignoring case: `:image`, `:pdf`, `:video` or
  `:audio`, with the content type to serve it as (EXPL-24); a path nothing
  previews has none. An image is `png`, `jpg`, `jpeg`, `gif`, `webp`, `avif`,
  `bmp`, `ico` or `svg`; a video is `mp4`, `m4v`, `webm`, `ogv` or `mov`; an
  audio file is `mp3`, `wav`, `ogg`, `oga`, `m4a`, `flac`, `aac`, `opus` or
  `weba`; a PDF is `pdf`. Any other extension, and a path with none, has no
  preview.
- **EXPL-23** For a file it may preview (EXPL-25) the viewer shows the preview
  in place of the text view: an `img` (`#file-preview`) for an image, an
  `iframe` for a PDF, a `video` with the browser's controls for a video and an
  `audio` with them for an audio file, in a pane filling the room the listing
  leaves — an image scaled down to fit it, its aspect ratio kept and never
  enlarged past its own size, the other kinds filling it. The file's text is not
  read for it: there is no line count, no gutter, no `#file-content`, no
  truncation notice and no highlighting (EXPL-12), and the read cap (EXPL-4)
  does not apply. There is no binary notice either (EXPL-8), and an SVG — which
  EXPL-11 reads as `xml` — is a picture here, so its source is no longer shown.
- **EXPL-24** `GET /files/raw` serves a previewed file's own bytes from the
  browsed workspace, named by the same `path`, `project` and `chat` parameters
  as the page (EXPL-6, EXPL-15, EXPL-17) and judged by the same path rules
  (EXPL-1, EXPL-2, EXPL-20). The response carries the preview's content type
  (EXPL-22), `x-content-type-options: nosniff`, the file's `content-length` and
  `last-modified`, and an `etag` of its size and modification time with
  `cache-control: no-cache`; a request whose `if-none-match` is that etag is
  answered `304` with no body, so a page opened again revalidates a file instead
  of fetching it again, and a file that changed since is served afresh. An image
  — the only kind that can carry script — is also served with
  `content-security-policy: default-src 'none'; sandbox`, so opening a file's
  own URL can't run an SVG's script in this app's origin. Anything else — a path
  that is forbidden, reached through a symlink or protected, a directory, a file
  that isn't there or can't be read, or one nothing previews — is a `404` whose
  body says nothing about the workspace, and no other file's bytes are served.
- **EXPL-25** The page renders a preview only for a path that is a previewable
  (EXPL-22), readable file of the browsed workspace: a previewable path that is
  missing, forbidden, reached through a symlink, protected, a directory or
  unreadable shows EXPL-9's message instead and no preview element at all, so
  the page never points the browser at a URL that would be a `404` (EXPL-24).
  The page and the raw route decide by the same check, so what the page previews
  is what the route serves and nothing else.
- **EXPL-26** With a preview in view the header still names the file's path and
  size (EXPL-8) and carries a link to the file's raw URL (EXPL-24) —
  `#file-preview-open`, `target="_blank"` and `rel="noreferrer"` — so the file
  can be opened on a page of its own (a PDF at full size) or saved with the
  browser's own controls; the preview element's own source is that same URL.

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

- Editing, creating, deleting or uploading files (the agent does that with a
  shell command, SHELL-15).
- Search and Markdown rendering; images, PDFs, video and audio are previews now
  (EXPL-22). Highlighting covers a fixed set of languages only.
- Byte ranges, so seeking inside a long video or audio file is up to what the
  browser has buffered.
- Whether a file's bytes really are what its extension claims: the browser
  decides, and one that isn't shows as a broken picture or an empty player.
- A thumbnail in the listing, a preview of a text file, converting a file for
  the browser, and a download of its own: the open link (EXPL-26) and the
  browser's own save and controls are the answer.
- Access control: like Sessions and System, anyone who can reach the app can
  read the (non-protected) workspace, the route that serves a preview's bytes
  (EXPL-24) included. Its socket is bound to this server's own origin
  ([SOCK](socket-origin.md)), which bounds the page, not the person.

## Stored data

Nothing stored changes. A project's `folder` is stored as the path it was
registered with (PROJ-2), symlink and all, and is never rewritten: the link is
followed when the root is browsed, not when the project is saved or read. An
existing project whose folder is a symlink therefore browses as it is, and no
migration is needed. A preview reads a file and stores nothing: the bytes it
serves are the file's own.

## Implementation

`Elia.Explorer` (path safety, listing, reading, language and preview detection),
`EliaWeb.FilesLive` (which workspace it browses, EXPL-15 - EXPL-18, the
preview it shows, EXPL-22 - EXPL-26, and the line in view, EXPL-27),
`EliaWeb.FilesRawController` (the bytes a
preview is made of, EXPL-24), `Elia.Deploy` (a chat's workspace, EXPL-17),
`EliaWeb.FileLinks` (the links that
open a chat's own workspace, FLINK),
the `Highlight` hook in `assets/js/highlight.js` (EXPL-13, and EXPL-27's mark
and scroll, after the highlighting so the mark survives it), and
highlight.js vendored in `assets/vendor/highlight/` (BSD-3-Clause).

## Tests

- `test/elia/explorer_test.exs` (path safety, the listing, reading and its
  refusals, a browsed root that is a symlink, the language a path maps to, the
  preview a path has and its content type — EXPL-1 to EXPL-5, EXPL-11, EXPL-20
  to EXPL-22).
- `test/elia_web/live/files_live_test.exs` (the page, its breadcrumbs, the
  viewer and its refusals, the language attribute, the header link, the project
  and the chat in view, a project whose folder is a symlink, the preview per
  kind and what it leaves out, a previewable path that can't be previewed, the
  line in view and a line it can't use —
  EXPL-6 to EXPL-10, EXPL-12, EXPL-13, EXPL-15 to EXPL-21, EXPL-23, EXPL-25,
  EXPL-26, EXPL-27, EXPL-28).
- `test/elia_web/controllers/files_raw_test.exs` (the bytes of a previewed
  file, its content type and headers, the revalidation it answers, and every
  refusal — EXPL-1, EXPL-2, EXPL-22, EXPL-24).
- `test/elia_web/browser/files_preview_test.exs` (a picture of the workspace
  drawn by a real headless Chromium — EXPL-23, EXPL-24, EXPL-26).
- `test/elia_web/file_links_test.exs` (the paths a link may name, EXPL-1,
  EXPL-2, EXPL-6, EXPL-9).
- `test/elia/preview_test.exs` (a path through a symlink refused, EXPL-2).
- No test: EXPL-14 — the colours come from the daisyUI theme variables in CSS,
  which a reviewer reads rather than a test.
