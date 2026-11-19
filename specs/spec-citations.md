# Spec citations

Status: Implemented

The agent cites spec requirements by ID constantly — the specs cross-reference
each other, a brief names the IDs a step must satisfy, a ledger entry keeps
them — and a citation is terse: `FLINK-5` says nothing at all unless the spec is
open beside it. So the chat carries the text: a requirement ID an assistant
message cites shows what that requirement says when the pointer rests on it, and
a citation is readable where it is written. A touch screen has no hover, so a
tap shows the text too (CITE-7), and the tooltip is the app's own rather than
the browser's `title`, because it carries links: where the requirement is
written, and every other requirement its statement names (CITE-10, CITE-11), so
a citation leads on to the spec it came from. A page whose bundle never loaded
still has the citation and its text in the browser's own `title` (CITE-13), and
nothing more.

The corpus is the one the chat's own workspace holds (PROJ-12) — `specs/*.md` of
the folder the chat works in, the workspace a file mention resolves in
(FLINK-5) — so a citation shows the requirement as that chat has it, and a
project whose workspace has no `specs/` has nothing to show and renders as it
did before. Nothing here is stored: a message keeps the text the agent wrote,
and the tooltip is derived from the corpus each time the message is rendered.

## Requirements

- **CITE-1** In an assistant message's Markdown — saved and streaming (UI-8,
  UI-10), in either view (UI-60) — a token that is a requirement ID the corpus
  defines (`<PREFIX>-<n>`, SPEC-1) carries that requirement's text as a tooltip
  (CITE-2), in an inline code span and in the message's plain text alike. Every
  other token, and a token naming a requirement the corpus does not define, is
  rendered as it is now (UI-25–UI-28).
- **CITE-2** The tooltip is the requirement's own statement: what the spec
  writes after the ID, with the spec's line wrapping collapsed to single spaces,
  and, for a retired requirement, its retirement reason as well (SPEC-5). The
  statement is otherwise the spec's own text — its inline code and emphasis
  included — and the entry's own markers (the bullet, the `**` around the ID,
  the `~~` of a retirement) are not part of it.
- **CITE-3** The citation's own text is the label, and the tooltip is the
  server's markup: the statement (CITE-2) with the statement's own characters
  escaped, so a requirement holding `<`, `&`, a quote or a line break adds no
  markup to the message or to the tooltip and renders as text (UI-27), and only
  the links the server builds (CITE-10, CITE-11) are markup.
- **CITE-4** The tooltip is what the corpus holds as the message is rendered: an
  ID a spec in the chat's workspace defines has one, and an ID only a spec that
  has gone — or a requirement a spec no longer defines — stops having one. A
  workspace with no readable `specs/` leaves every citation as plain text, never
  as an error in the transcript.
- **CITE-5** A citation reads as a citation: its text is unchanged, and it is
  marked as having more to show — a dotted underline and a `help` cursor — while
  it stays text: it goes nowhere and is no control, so no link, no button, and
  nothing for Enter or Space to act on (the tooltip's own links are the
  tooltip's, CITE-12). What it does is show its text: the pointer resting on it
  (CITE-2), and a tap or a click on it (CITE-7).
- **CITE-6** A fenced code block is content, not a citation: an ID inside one is
  left alone, and so are the text of a link and an image's alt text.
- **CITE-7** A tap or a click on a citation, and the pointer resting on it, show
  that requirement's text — the same text either way (CITE-2, CITE-4) — in a
  tooltip beside the citation and over the page, so a touch screen, which shows
  no hover at all, reads a citation the way a pointer does. The tooltip is an
  overlay: the message's own text and layout stay as they are.
- **CITE-8** The tooltip closes as soon as it is no longer wanted: the pointer
  leaving the citation and the tooltip, a second tap on the same citation, a tap
  or a click anywhere else, an Escape press, a scroll of the transcript, and the
  citation going from the page — a message re-rendered without it (UI-10) — so
  no requirement's text lingers over content it no longer belongs to. The
  tooltip takes no tap of its own: a tap in its place reaches what is behind it,
  and only its links (CITE-12) are otherwise.
- **CITE-9** The tooltip is the client's own: the server renders it empty and
  hidden, the browser fills it with the markup of the citation it was opened for
  (CITE-3) and places it beside that citation, and LiveView never patches it
  (IMG-7, IMG-8).
- **CITE-10** The tooltip says where the requirement is written: a link, labelled
  with the requirement's spec file and line (`specs/spec-citations.md:12`),
  which opens the Files page at that line (EXPL-22) in the workspace the chat
  works in (CITE-4, FLINK-5).
- **CITE-11** Every requirement the statement names — a token the corpus defines
  (CITE-1) — is a link in the tooltip to that requirement's own file and line,
  as CITE-10's link is; a token the corpus does not define stays text.
- **CITE-12** A tooltip's links take the pointer: the pointer may leave the
  citation for the tooltip without the tooltip closing (CITE-8), and a click on
  a link opens it.
- **CITE-13** While the bundle's hook runs, no citation carries a `title`, so
  the browser's own tooltip never shows beside the app's; a page whose bundle
  never loaded keeps the citation and its `title` (CITE-2, CITE-3).

## Out of scope

- The corpus of another tree: a citation is looked up in the workspace the chat
  works in, so a spec that only exists in another project, or only in a
  worktree the chat has not landed, shows nothing.
- `specs/plans/*.md`: a plan defines no requirement ID (SPEC-8), so it is not
  part of the corpus.
- A bare prefix with no number (`FLINK`, `SPEC`), and a citation of a
  requirement that never existed.
- Reasoning text, notices, the compaction summary, a tool call's input and
  output, and the user's own message: a citation is an assistant message's text.
- The citation as the way into the spec: the citation itself goes nowhere
  (CITE-5), and it is the tooltip's own link that opens the file (CITE-10).
- The statement's own Markdown: it shows as the spec's characters (CITE-2) — a
  backtick or an `**` in it is a character, not markup — and only the
  requirements it names are links (CITE-11).
- The keyboard: the citation is no control (CITE-5), so the tooltip and its
  links are a pointer's and a tap's.
- A file mention in a reply: `lib/elia/specs.ex:12` keeps FLINK-2's behaviour —
  the line suffix belongs to the label and the link opens the file — where a
  citation's link names its line (CITE-10).
- Anything else a tap could do: no copy of the text, no panel that stays on the
  page, and no long-press of our own — the tooltip is the whole of it.
- Another page: the Files viewer showing a spec file, and every other view, keep
  their text as it is.

## Implementation

`Elia.Specs` (the corpus: which IDs a workspace's `specs/*.md` define, each
one's statement, and the file and line it is written at), `Elia.Specs.Cache`
(the parsed corpus, kept while the files it was made from are unchanged),
`EliaWeb.SpecRefs` (the Markdown AST pass that marks a citation, and the
tooltip's markup), `EliaWeb.FileLinks` (the Files page URL a citation's link
takes, EXPL-22), `EliaWeb.Markdown.to_html/2` (the pass, in a chat's context),
`EliaWeb.ChatLive` (the transcript item, which already holds that context, and
the tooltip: the `#spec-tip` element and the `.SpecTip` hook beside the image
viewer's), `assets/css/app.css` (the look of a citation, CITE-5).

## Tests

`test/elia/specs_test.exs` (CITE-2, CITE-3, CITE-4, CITE-10) — which IDs a
workspace defines, what each one's text is, the file and line each one is
written at, and what a corpus that is edited or absent does.
`test/elia_web/markdown_test.exs` (CITE-1, CITE-3, CITE-5, CITE-6, CITE-10,
CITE-11) — a citation in a reply: inline code, plain text, escaping, a code
block, a link's text, and the tooltip's links.
`test/elia_web/live/chat_live_test.exs` (CITE-1) — a citation in the transcript,
saved and streaming.
`test/elia_web/browser/chat_browser_test.exs` (CITE-5, CITE-7, CITE-8, CITE-9,
CITE-12, CITE-13) — a hover, a tap, the tooltip's links and the ways the tooltip
closes are the browser's own, which is the layer for it
(`specs/browser-tests.md`).
