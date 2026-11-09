# File links

Status: Implemented

The agent names files constantly: a path in a reply, the path on a file tool's
card. A named file is usually something the user wants to look at, and the Files
page (EXPL) can show any of them. So the transcript turns such a mention into a
link to that file's own page, making a file the agent read, wrote or changed one
click away instead of something to find by hand.

The page it opens is the file **as that chat has it**: a chat in Elia's own
project works in its own worktree, not in the live tree (PROJ-12, DEPLOY-1), so
the link asks the Files page for that chat's workspace (EXPL-17) rather than for
the project folder — otherwise the user would read the deployed copy, or a
path that isn't there yet. A mention the Files page could not show (a command, a
path outside the chat's workspace, a protected one, one that doesn't exist)
stays exactly as it was: plain text.

## Requirements

### Mentions in a reply

- **FLINK-1** In an assistant message — saved or streaming (UI-8, UI-10), in
  either view (UI-60) — a Markdown inline code span (`` `…` ``) whose text names
  a path becomes a link when FLINK-5 allows it, keeping the text as its label
  and rendering it as code, so the mention reads as before and is one click
  away. The rest of the message renders as it does now (UI-25–UI-28), and a path
  inside a fenced code block is not affected: a code block is content, not a
  mention.
- **FLINK-2** A mention may carry a line suffix — `lib/elia/store.ex:41`,
  `lib/elia/store.ex:41:7` or `lib/elia/store.ex:41-58`. The suffix stays in the
  label (the agent's whole text is shown) and is left out of the link's target,
  which is the file itself.
- **FLINK-3** A mention may be relative to the chat's workspace or absolute: an
  absolute path inside it names the same file (PROJ-12, WS-1), and both link to
  the same relative page.
- **FLINK-4** The card of a tool call whose input has a `path` (UI-15, a file
  tool: FILE) links that path the same way, so the file an agent read, wrote or
  deleted is one click from its card. The rest of the card is unchanged, and a
  path FLINK-5 doesn't allow stays plain text.

### When a mention becomes a link

- **FLINK-5** A mention is linked only when the Files page could show it: the
  path must be inside the workspace the chat works in (PROJ-12 — its own
  worktree in Elia's own project, its project's folder otherwise), not into a
  protected path (WS-1: `.git`, `_build`, `deps`, `.elia`) or through a symlink
  (EXPL-1, EXPL-2), and exist there as a file or a directory. The link is that
  path's Files page for that chat — `/files?chat=<the chat's id>&path=<relative
  path>` (EXPL-6, EXPL-17) — so it opens the file as the chat itself has it.
  A mention that fails any of this stays plain text: never a link to a page that
  would show an error (EXPL-9). The check is made against that workspace as the
  message is rendered, so it follows a file that appears or goes.
- **FLINK-6** The mention adds no markup: the label is the agent's own text,
  escaped, and the URL is percent-encoded, so a path holding `&`, `<`, a space
  or a quote renders as text and still links to the right path (UI-27). Raw HTML
  in a message stays out, as before (UI-27).
- **FLINK-7** A linked mention still reads as a mention: its label keeps the
  inline-code look (monospace on the code background) and the link colours it
  and underlines it on hover rather than replacing that look. Clicking it opens
  the Files page at that path in the same tab, as the message's other links do
  (UI-25) — never in a new tab.

## Out of scope

- Reasoning text, notices and a tool's output (a `shell`'s stdout, a file's
  contents): a mention is a reply's inline code or a card's `path`, not text
  quoted from elsewhere.
- Linking prose that merely looks like a path: a mention is what the agent put
  in inline code, so an unquoted path in a sentence stays plain text.
- Another workspace's files: a mention is resolved in the chat's own workspace,
  so a path that only exists in the live tree, or in another project, is not
  offered.
- The header's "Files" link (EXPL-10): it keeps opening the project the page is
  about. Only a mention in a chat opens that chat's workspace.
- Editing, opening in an editor, or a hover preview of the file: the link opens
  the Files page (EXPL-6).

## Implementation

`EliaWeb.FileLinks` (which mentions count, resolving them in the chat's
workspace, the Files URL), `EliaWeb.Markdown.to_html/2` (the Markdown AST pass),
`EliaWeb.ChatLive` (the transcript item and the tool card),
`Elia.Deploy` (resolving a chat's workspace without creating anything),
`EliaWeb.FilesLive` (the `chat` in view, EXPL-17), `assets/css/app.css` (the look
of a linked mention, FLINK-7).

## Tests

`test/elia_web/file_links_test.exs` (which mentions link and which don't,
FLINK-2 - FLINK-6, and that the link is the chat's workspace),
`test/elia_web/markdown_test.exs` (a mention in a reply, FLINK-1, FLINK-6),
`test/elia_web/live/chat_live_test.exs` (a mention in the transcript and on a
tool card, FLINK-1, FLINK-4).
