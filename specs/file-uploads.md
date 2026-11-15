# File uploads

Status: Draft

A chat can take files from the browser. The composer's attach control uploads
them, and sending the message writes them into the chat's own workspace — its
own worktree when the chat is in Elia's own project (DEPLOY-1), its project's
folder otherwise (PROJ-12) — so the agent reaches them with its own file tools
(FILE), and the message names them. A chat's uploads are ordinary files in its
workspace and nothing else: they are not Elia's data, and no other chat sees
them. A file is kept as the user handed it over — no conversion, no inspection —
and one that can't be written is reported rather than dropped silently.

Elia's own tree ignores `uploads/`, so a chat's uploads are never committed with
its work.

## Requirements

### The composer

- **UPLOAD-1** The composer has an attach control — a button (`#upload-button`)
  around a file picker (`input[type=file]`) that takes one or more files of any
  type — and a file picked starts uploading at once, the pick itself being what
  starts it rather than the message being sent, with the composer showing its
  progress (`#upload-progress-<ref>`) until it is on the server.
- **UPLOAD-2** One message carries at most 10 files, each at most 25 MB. A file
  over either bound is not one the message carries: the composer says which
  bound it broke — in the line above the input (`#upload-error`) for the count,
  on the file's own chip (`#upload-<ref>`, where how far it is would be) for the
  size — and the message is not sent while it is attached. The files within the
  bounds stay attached.
- **UPLOAD-3** Each attached file shows in the composer as a chip
  (`#upload-<ref>`) with the name the browser gave it and its size in bytes, and
  a remove button (`#upload-remove-<ref>`) that drops it from the message.
- **UPLOAD-4** While the chat isn't idle (UI-24) the attach control is not there:
  no file can be picked or removed. A file already attached stays attached until
  the message is sent, which is what it was attached for.
- **UPLOAD-5** A message with attachments and no text is sent; one with neither
  is not (UI-22), and a send that succeeds clears the composer's attachments
  with its text (UI-23).

### Where the files go

- **UPLOAD-6** Sending a message with attachments writes each file into
  `uploads/` under the chat's workspace root (PROJ-12): the chat's own worktree
  in Elia's own project (DEPLOY-1), its project's folder otherwise. The
  directory is created when it isn't there.
- **UPLOAD-7** A file keeps the name the browser gave it, reduced to its base
  name — any directory part dropped, and a path separator or a control character
  replaced by `_` — and a name that is empty, `.` or `..` becomes `file`.
- **UPLOAD-8** A name `uploads/` already holds is never overwritten: the file
  takes the first free number before its extension (`shot.png`, `shot-1.png`,
  `shot-2.png`), so two uploads of one name both survive.
- **UPLOAD-9** A file that can't be written is reported in the composer
  (`#upload-error`), naming the file and the reason, and the message is not
  sent. A chat's workspace that cannot take the files at all is reported
  before any of them is taken out of the composer, so they stay attached.

### The message and the transcript

- **UPLOAD-10** A message that carries attachments names their
  workspace-relative paths, in the order they were attached, in one line after
  the user's text: `[Uploaded files: uploads/shot.png, uploads/report.pdf]`.
- **UPLOAD-11** A message that carries attachments records their
  workspace-relative paths in its `meta`, a value a provider is never sent
  (LLM-5).
- **UPLOAD-12** The transcript shows a user message that carries attachments as
  the user's own text — the line of UPLOAD-10 is not part of it — with one chip
  per file under it, each a link to that file's Files page in the chat's own
  workspace (`/files?chat=<id>&path=<relative path>`, FLINK-5), from the saved
  chat as well as from a message just sent.
- **UPLOAD-13** The compact view (UI-61) shows a user message that carries
  attachments even when it has no text of its own (UI-90).
- **UPLOAD-14** A message whose files are all it carries names nothing, so the
  title of a chat whose first message is one of those (STORE-7) is the first
  message the user *wrote*: `"New chat"` until they write one.
- **UPLOAD-15** A message is not sent while a file it carries is still
  uploading: the composer says so (`#upload-error`) and nothing is sent.

## Terms

- **attachment** — a file the user picked in the composer, carried by the
  message they are sending.
- **`uploads/`** — the directory at a chat's workspace root that attachments are
  written into.

## Out of scope

- Sending a file's content to the model: an attachment reaches the model as a
  path (UPLOAD-10), and the agent reads the file with its own tools. An image is
  not sent as an image, and a binary file reads as binary (FILE).
- Showing an uploaded image in the transcript: a chip is a link to the Files
  page, which shows a non-text file as binary (EXPL-8).
- Pasting or dropping a file onto the chat, and uploading from the Files page,
  which stays read-only (EXPL).
- Deleting an upload, a per-chat page of a chat's uploads, and any listing of
  them beyond the chat's own workspace (EXPL-17).
- Limits other than UPLOAD-2's: nothing the user can configure, and no
  per-file-type restriction.

## Stored data

Backward compatible, with nothing to migrate. A message with attachments carries
their paths in its `meta` (UPLOAD-11) — a map a message already has, which an
older version reads and ignores — and the files themselves are ordinary files in
the chat's workspace, not Elia's data. Nothing under `.elia` changes shape: a
chat saved before this feature loads as it did, and a chat saved now is read by
the older code with the line of UPLOAD-10 in it as nothing but text.

## Implementation

`EliaWeb.ChatLive` (the attach control — the pick starting the upload it
configures for, `auto_upload` (UPLOAD-1) — its chips and the transcript's),
`Elia.Agent` and `Elia.Agent.Session` (writing the files into the chat's own
workspace and appending the message), `Elia.LLM.Message` (a user message's
attachments, its `meta`, and the text the user wrote as against the line naming
the paths), `EliaWeb.FileLinks` (the link a chip gets, FLINK-5),
`assets/css/app.css` (the chips and the control's feedback, FEED).

## Tests

- `test/elia/upload_test.exs` (the workspace a chat's uploads land in, the name
  a file keeps, the number a taken name gets, the directory created, the line
  the message names the paths in and the `meta` it records, and the title a
  files-only first message leaves — UPLOAD-6 to UPLOAD-8, UPLOAD-10, UPLOAD-11,
  UPLOAD-14).
- `test/elia_web/live/chat_upload_test.exs` (the attach control, its bounds,
  the chips and removing one, a message with files and no text, one sent while
  a file is still on its way, a write that fails, the chips in the transcript
  and in the compact view — UPLOAD-1 to UPLOAD-5, UPLOAD-9, UPLOAD-12,
  UPLOAD-13, UPLOAD-15).
- `test/elia_web/browser/upload_test.exs` (a file picked in the composer
  uploading in a real browser, and the message it is sent with — UPLOAD-1,
  UPLOAD-12): that the pick is what starts the upload is the client's half of
  UPLOAD-1, which the LiveView suite cannot see — its helper drives an upload
  server-side, so it passes whatever the browser does with a pick (BROWSER-1).
