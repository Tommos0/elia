# Spec citations

Status: Implemented

The agent cites spec requirements by ID constantly — the specs cross-reference
each other, a brief names the IDs a step must satisfy, a ledger entry keeps
them — and a citation is terse: `FLINK-5` says nothing at all unless the spec is
open beside it. So the chat carries the text: a requirement ID an assistant
message cites shows what that requirement says when the pointer rests on it, and
a citation is readable where it is written. A touch screen has no hover and no
browser shows a `title` on a tap, so a tap shows the text too (CITE-7); the text
is the citation's own either way, and no part of it needs the bundle — a page
whose JavaScript never loaded has the citation and its hover tooltip.

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
- **CITE-3** The citation's own text is the label and the tooltip is an
  attribute of the element holding it, and both are HTML-escaped: a requirement
  holding `<`, `&`, a quote or a line break adds no markup to the message and
  renders as text (UI-27).
- **CITE-4** The tooltip is what the corpus holds as the message is rendered: an
  ID a spec in the chat's workspace defines has one, and an ID only a spec that
  has gone — or a requirement a spec no longer defines — stops having one. A
  workspace with no readable `specs/` leaves every citation as plain text, never
  as an error in the transcript.
- **CITE-5** A citation reads as a citation: its text is unchanged, and it is
  marked as having more to show — a dotted underline and a `help` cursor — while
  it stays text: it goes nowhere and is no control, so no link, no button, and
  nothing for Enter or Space to act on. What it does is show its text: the
  pointer resting on it (CITE-2), and a tap or a click on it (CITE-7).
- **CITE-6** A fenced code block is content, not a citation: an ID inside one is
  left alone, and so are the text of a link and an image's alt text.
- **CITE-7** A tap or a click on a citation shows that requirement's text — the
  same text the hover tooltip carries (CITE-2, CITE-4) — in a popover beside the
  citation and over the page, so a touch screen, which shows no hover tooltip at
  all, reads a citation the way a pointer does. The popover is an overlay: the
  message's own text and layout stay as they are.
- **CITE-8** The popover closes as soon as it is no longer wanted: a second tap
  on the same citation closes it, and so does a tap or a click anywhere else, an
  Escape press, a scroll of the transcript, and the citation going from the page
  — a message re-rendered without it (UI-10) — so no requirement's text lingers
  over content it no longer belongs to. The popover takes no tap of its own: it
  is a tooltip, and a tap in its place reaches what is behind it.
- **CITE-9** The popover is the client's own: the server renders it empty and
  hidden, the browser fills it with the text of the citation that was tapped and
  places it beside it, and LiveView never patches it (IMG-7, IMG-8).

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
- Opening the spec: a tap shows the requirement's text where it is written
  (CITE-7), and never takes the reader to the file.
- Anything else a tap could do: no copy of the text, no panel that stays on the
  page, and no long-press of our own — the popover is the whole of it.
- A hover tooltip of our own: with a pointer the browser's `title` tooltip is
  what shows the text (CITE-2), and the popover is what a tap has instead.
- Another page: the Files viewer showing a spec file, and every other view, keep
  their text as it is.

## Implementation

`Elia.Specs` (the corpus: which IDs a workspace's `specs/*.md` define, and each
one's text), `Elia.Specs.Cache` (the parsed corpus, kept while the files it was
made from are unchanged), `EliaWeb.SpecRefs` (the Markdown AST pass that marks a
citation), `EliaWeb.Markdown.to_html/2` (the pass, in a chat's context),
`EliaWeb.ChatLive` (the transcript item, which already holds that context, and
the popover: the `#spec-tip` element and the `.SpecTip` hook beside the image
viewer's), `assets/css/app.css` (the look of a citation, CITE-5).

## Tests

`test/elia/specs_test.exs` (CITE-2, CITE-3, CITE-4) — which IDs a workspace
defines, what each one's text is, and what a corpus that is edited or absent
does.
`test/elia_web/markdown_test.exs` (CITE-1, CITE-3, CITE-5, CITE-6) — a citation
in a reply: inline code, plain text, escaping, a code block, a link's text.
`test/elia_web/live/chat_live_test.exs` (CITE-1) — a citation in the transcript,
saved and streaming.
`test/elia_web/browser/chat_browser_test.exs` (CITE-5, CITE-7, CITE-8, CITE-9) —
a tap and the popover are the browser's own, which is the layer for it
(`specs/browser-tests.md`): a tap on a citation shows its text beside it, and the
ways the popover closes.
