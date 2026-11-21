# File explorer

Status: Implemented

A Files page lets the user browse the workspace and read its files in the
browser, without opening a terminal or asking the agent. It is read-only and
deliberately small: a directory listing next to a viewer that shows a text file
as plain text and previews what the browser renders itself — a picture, a PDF, a
video, an audio file (EXPL-22). It browses the open project's folder (EXPL-15),
or a single chat's own workspace (EXPL-17), which is where a file the agent
mentions in that chat is opened (FLINK-5). The viewer has two modes for the
file in view (EXPL-30): its source as text, and the file itself as the browser
renders it — a page, a picture, a media file — with none of the viewer's own
chrome (EXPL-32).

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

- **EXPL-15** The page browses the open project (PROJ-28, PROJ-8): paths are
  relative to that project's folder, and there is no `project` query parameter
  — one in an older URL is ignored, and the open project is browsed as it
  otherwise would be. EXPL-1–EXPL-5 apply to whichever folder is in view.
- **EXPL-16** The page names the project it browses (`#project-name`, with the
  folder in its `title`) and has no project control of its own: the open project
  is changed with the header's switcher (PROJ-29), which every page carries and
  which switches this page in place (EXPL-29).
- **EXPL-29** The header's project switcher (PROJ-29) on this page switches the
  project there and then: the project chosen becomes the open one (PROJ-8,
  PROJ-28) and the page browses its folder without leaving the page, keeping
  the path in view when the new project has it and falling back to its root
  when it does not (EXPL-9), and leaving a chat in view behind (EXPL-18).

- **EXPL-17** The page can browse a chat's own workspace instead of a project
  folder: a `chat` query parameter names a saved chat (STORE), and paths are
  then relative to the workspace that chat works in (PROJ-12) — its project's
  folder, which for a chat in Elia's own project is the live tree (DEPLOY-1) —
  with EXPL-1–EXPL-5 applying to that root as to any other.
  The project in view is the chat's own (PROJ-9), whether or not it is the open
  one. It is how a file the agent mentions is opened, so the
  page shows the file as that chat's workspace has it (FLINK-5). A `chat` that
  isn't a saved chat is ignored, and the page browses
  the project as EXPL-15 says. Resolving the workspace never creates anything.
- **EXPL-18** The page says which workspace it browses: the project as now
  (EXPL-16) and, with a chat in view, that chat beside it (`#workspace-note`: a
  chat icon and the chat's title, STORE-33 — "New chat" before it has one —
  with the root in its `title`), so a chat's workspace is not mistaken for the
  project folder on its own. Switching the project (EXPL-29) leaves the chat
  behind — dropping `chat` from the URL — and keeps the path in view when that
  project has it.

- **EXPL-19** When the browsed root itself can't be listed — the folder is
  missing, unreadable or not a directory — the page shows a message saying so,
  naming the root, in place of EXPL-9's path message, and the listing is empty:
  it neither shows another directory's entries nor says the directory is empty.
  The page stays otherwise usable — the project name (EXPL-16) and, with a chat
  in view, the workspace note (EXPL-18) — so it can be left by switching project
  in the header (EXPL-29), and no other folder is browsed.

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
  in place of the text view in raw mode, which is the file's default mode
  (EXPL-30): an `img` (`#file-preview`) for an image, an
  `iframe` for a PDF, a `video` with the browser's controls for a video and an
  `audio` with them for an audio file, in a pane filling the room the listing
  leaves — an image scaled down to fit it, its aspect ratio kept and never
  enlarged past its own size, the other kinds filling it. The file's text is not
  read for it: there is no line count, no gutter, no `#file-content`, no
  truncation notice and no highlighting (EXPL-12), and the read cap (EXPL-4)
  does not apply. There is no binary notice either (EXPL-8), and an SVG — which
  EXPL-11 reads as `xml` — is a picture here rather than its source, which the
  source mode shows instead (EXPL-30).
- **EXPL-24** `GET /files/raw` serves a file's own bytes from the workspace the
  page browses, for a path of a kind the browser renders (EXPL-31), resolved the
  same way from the `path` and `chat` parameters it carries and the open project
  (EXPL-6, EXPL-15, EXPL-17), and judged by the same path rules (EXPL-1, EXPL-2,
  EXPL-20). The response carries the content type that kind gives it
  (EXPL-22, EXPL-31), `x-content-type-options: nosniff`, the file's
  `content-length` and
  `last-modified`, and an `etag` of its size and modification time with
  `cache-control: no-cache`; a request whose `if-none-match` is that etag is
  answered `304` with no body, so a page opened again revalidates a file instead
  of fetching it again, and a file that changed since is served afresh. A kind
  that can carry script — an image, an HTML document, an XML file (EXPL-31) — is
  also served with `content-security-policy: default-src 'none'; style-src
  'unsafe-inline'; sandbox`, so opening a file's own URL can't run its script in
  this app's origin, while the document's own inline styles still apply. Anything
  else — a path that is forbidden, reached through a symlink or protected, a
  directory, a file that isn't there or can't be read, or one no kind of raw view
  names (EXPL-31) — is a `404` whose body says nothing about the workspace, and
  no other file's bytes are served.
- **EXPL-25** The page renders a preview only for a path that is a previewable
  (EXPL-22), readable file of the browsed workspace: a previewable path that is
  missing, forbidden, reached through a symlink, protected, a directory or
  unreadable shows EXPL-9's message instead and no preview element at all, so
  the page never points the browser at a URL that would be a `404` (EXPL-24).
  The page and the raw route decide by the same check, so what the page previews
  or renders raw is what the route serves and nothing else.
- **EXPL-26** With a file that has a raw view (EXPL-31) the header names the
  file's path and size (EXPL-8) and carries a link to the file's raw URL
  (EXPL-24) — `#file-preview-open`, `target="_blank"` and `rel="noreferrer"` —
  so the file can be opened on a page of its own (a PDF at full size, a page
  rendered on its own) or saved with the browser's own controls; the view's own
  source (EXPL-23, EXPL-32) is that same URL.

### Raw view

The viewer has two modes for the file in view: the source as text, and the file
itself as the browser renders it. Raw mode is what a file with a rendering of
its own is for — an HTML page, a picture, an SVG, a media file — and the page
hands the browser the file's own bytes (EXPL-24) rather than the text the viewer
read.

- **EXPL-30** The viewer shows the file in view in one of two modes, named by a
  `mode` query parameter: `source`, the text view (EXPL-8, EXPL-11 - EXPL-13,
  EXPL-27), and `raw`, the file as the browser renders it (EXPL-32). A `mode`
  that is missing, that names neither, or that asks for `raw` for a file the
  browser renders nothing of (EXPL-31) is the file's default mode: `raw` for a
  file the browser renders of itself (EXPL-22), `source` for any other file.
- **EXPL-31** `Elia.Explorer.raw_file/2` names what the browser renders of a
  path in a workspace, with the content type to serve it as, or none: a file the
  page may preview (EXPL-25) as its own kind and type (EXPL-22), an HTML document
  (`html` or `htm`, ignoring case) as `text/html; charset=utf-8`, an XML file
  (`xml`, `heex`, `eex` or `leex`) and any other file the page reads as text
  (EXPL-4) as `text/plain; charset=utf-8`. A path that is forbidden, reached
  through a symlink, protected, a directory, missing, unreadable or binary has
  none (EXPL-1, EXPL-2, EXPL-5).
- **EXPL-32** In raw mode the viewer shows the file itself and not the text
  view: a kind the browser renders of itself (EXPL-22) as its preview element
  (EXPL-23), and any other kind EXPL-31 names in an `iframe` (`#file-raw`) whose
  source is the file's raw URL (EXPL-24) and which carries `sandbox` with no
  `allow-scripts`, filling the pane. There is no line count, gutter,
  highlighting (EXPL-12), truncation notice or binary notice, and the read cap
  (EXPL-4) does not apply to what is shown.
- **EXPL-33** The header carries a control that switches mode — `#mode-source`
  and `#mode-raw`, the one in view marked — for a file that has a raw view
  (EXPL-31), and it keeps the browsed workspace and the file in view while
  patching the URL (EXPL-7).

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
- A raw document's own subresources: the stylesheet, script, picture or font an
  HTML file names are not served and not resolved to the workspace, so a raw
  page shows its own markup, with whatever its inline styles say and nothing
  more. The policy EXPL-24 names is what keeps a file's script from running.
- Access control: like Sessions and System, anyone who can reach the app can
  read the (non-protected) workspace, the route that serves a preview's bytes
  (EXPL-24) included. Its socket is bound to this server's own origin
  ([SOCK](socket-origin.md)), which bounds the page, not the person.

## Stored data

Nothing stored changes. A project's `folder` is stored as the path it was
registered with (PROJ-2), symlink and all, and is never rewritten: the link is
followed when the root is browsed, not when the project is saved or read. An
existing project whose folder is a symlink therefore browses as it is, and no
migration is needed. A preview or a raw view reads a file and stores nothing:
the bytes it serves are the file's own, and the mode in view is a query
parameter the URL carries rather than anything stored.

## Implementation

`Elia.Explorer` (path safety, listing, reading, language, preview detection and
what the browser renders of a file, EXPL-31), `EliaWeb.FilesLive` (which
workspace it browses, EXPL-15 - EXPL-18 and EXPL-29, the preview it shows,
EXPL-22 - EXPL-26, the mode in view and the raw pane, EXPL-30, EXPL-32, EXPL-33,
and the line in view, EXPL-27),
`EliaWeb.FilesScope` (the workspace a page and a raw URL name, EXPL-15,
EXPL-17), `EliaWeb.Layouts` (the header's switcher on this page, EXPL-29),
`EliaWeb.FilesRawController` (the bytes a
raw view is made of, EXPL-24), `Elia.Deploy` (a chat's workspace, EXPL-17),
`EliaWeb.FileLinks` (the links that
open a chat's own workspace, FLINK),
the `Highlight` hook in `assets/js/highlight.js` (EXPL-13, and EXPL-27's mark
and scroll, after the highlighting so the mark survives it), and
highlight.js vendored in `assets/vendor/highlight/` (BSD-3-Clause).

## Tests

- `test/elia/explorer_test.exs` (path safety, the listing, reading and its
  refusals, a browsed root that is a symlink, the language a path maps to, the
  preview a path has and its content type, what the browser renders of a path —
  EXPL-1 to EXPL-5, EXPL-11, EXPL-20 to EXPL-22, EXPL-31).
- `test/elia_web/live/files_live_test.exs` (the page, its breadcrumbs, the
  viewer and its refusals, the language attribute, the header link, the project
  and the chat in view, a project whose folder is a symlink, the preview per
  kind and what it leaves out, a previewable path that can't be previewed, the
  mode in view and the default mode of each kind, the raw pane and the control
  that switches it, the line in view and a line it can't use —
  EXPL-6 to EXPL-10, EXPL-12, EXPL-13, EXPL-15 to EXPL-21, EXPL-23, EXPL-25 to
  EXPL-28, EXPL-29, EXPL-30, EXPL-32, EXPL-33).
- `test/elia_web/controllers/files_raw_test.exs` (the bytes of a file the
  browser renders, its content type and headers, the policy a script-carrying
  kind is served under, the revalidation it answers, and every refusal —
  EXPL-1, EXPL-2, EXPL-22, EXPL-24, EXPL-31).
- `test/elia_web/browser/files_preview_test.exs` (a picture of the workspace
  drawn by a real headless Chromium — EXPL-23, EXPL-24, EXPL-26).
- `test/elia_web/browser/files_raw_test.exs` (a real headless Chromium renders a
  raw page in the frame and runs none of its script — EXPL-24, EXPL-32).
- `test/elia_web/browser/files_line_test.exs` (the mark and the scroll a real
  headless Chromium makes of the line a URL names, after the highlighting —
  EXPL-27).
- `test/elia_web/file_links_test.exs` (the paths a link may name, EXPL-1,
  EXPL-2, EXPL-6, EXPL-9).
- `test/elia/preview_test.exs` (a path through a symlink refused, EXPL-2).
- No test: EXPL-14 — the colours come from the daisyUI theme variables in CSS,
  which a reviewer reads rather than a test.
