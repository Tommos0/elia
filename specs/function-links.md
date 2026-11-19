# Function links

Status: Implemented

The agent names Elixir functions constantly — `Elia.Store.save/1`,
`EliaWeb.FileLinks.url/2` — and a name says little without the code it is: which
file defines it, and where in that file. The Files page (EXPL) can show any file
the chat's workspace holds, at a line (EXPL-27), so the transcript turns such a
mention into a link to the definition's own line: the source of a function the
agent names is one click away instead of something to find by hand. It is a file
mention (FLINK) one step further in — where a path names a file, a function
names a file and a line, and the definition is what decides both.

A mention resolves in the workspace the chat works in (PROJ-12, FLINK-5), read
as that workspace has it while the message is rendered (CITE-4), so what the link
opens is the code the chat was talking about. A function the workspace does not
define — one of Elixir's own, one of a dependency's, a typo — stays exactly as it
was: plain text.

## Requirements

### Mentions in a reply

- **FUNC-1** In an assistant message — saved or streaming (UI-8, UI-10), in
  either view (UI-60) — a token that names an Elixir function (FUNC-2) becomes a
  link when the chat's workspace defines it (FUNC-4), keeping the token as the
  link's label, in an inline code span and in the message's plain text alike.
  Every other token, and the rest of the message, renders as it does now
  (UI-25–UI-28). A fenced code block is content, not a mention, and so are the
  text of a link and an image's alt text.
- **FUNC-2** A mention is `<Module>.<function>/<arity>`: the module is one or
  more dot-separated parts, each starting with a capital letter, the function
  name is lower-case letters, digits and underscores with at most one trailing
  `?` or `!`, and the arity is a whole number. A bare module, a function named
  without an arity, and a token broken by a space are not mentions.
- **FUNC-3** A mention written with Elixir's `Elixir.` prefix names the same
  module, and links the same, as one written without it.
- **FUNC-4** A mention links only when the workspace the chat works in (PROJ-12,
  FLINK-5) defines that module and a function of that name and arity. The link
  is that file's Files page at the function's line — `/files?chat=<the chat's
  id>&path=<the file>&line=<the line>` (EXPL-6, EXPL-17, EXPL-27) — so it opens
  the source where the function is written. A function the workspace does not
  define stays plain text: never a link to a page that would show an error
  (EXPL-9). The check is made against that workspace as the message is rendered,
  so it follows a function that appears or goes.
- **FUNC-5** The line is the first line of the function's definition in that
  file: the `def`, `defp`, `defmacro`, `defmacrop` or `defdelegate` head that
  names it, and the first of a function's clauses. The module is the one the
  definition is inside: a definition within another module belongs to that inner
  module, not to the outer one.
- **FUNC-6** The arities a mention may name are the ones the definition creates,
  so a definition with default arguments answers to each arity its defaults make
  possible: `def f(a, b \\ 1)` is `f/1` and `f/2`, and `f/0` names nothing there.
- **FUNC-7** The mention adds no markup: its label is the agent's own token and
  the URL is percent-encoded, and what a reply writes around one renders as it
  did before (UI-27). Raw HTML in a message stays out, as before (UI-27).
- **FUNC-8** A linked mention still reads as a mention: where it was inline code
  it keeps the inline-code look, and the link colours it and underlines it on
  hover rather than replacing that look. Clicking it opens the Files page at that
  line in the same tab, as the message's other links do (UI-25) — never in a new
  tab.

### The definitions a workspace holds

- **FUNC-9** The definitions are read from the workspace's own `.ex` and `.exs`
  files, leaving out the protected paths (WS-1: `.git`, `_build`, `deps`,
  `.elia`), `tmp/`, a dependency's `node_modules`, and a path reached through a
  symlink — so a module only a dependency, a build output or an unlanded
  worktree (DEPLOY-28) defines is not one the workspace defines. A file that
  can't be read or parsed is left out of it, never an error in the transcript
  (CITE-4).
- **FUNC-10** A file defines the modules its own `defmodule`s name, so a module
  in a file whose path doesn't match its name is found as it is, and a module
  that several files define is the one whose path sorts first.

## Out of scope

- A function only another tree defines: a mention resolves in the chat's own
  workspace (FUNC-4), so one only a worktree the chat has not landed defines
  stays plain text, as a path in one does (FLINK-5).
- Elixir's own and a dependency's functions: `Enum.map/2` and `Req.get/2` are not
  in the workspace's own source (FUNC-9), so they stay text — the link opens the
  code the chat works on, which is what the Files page shows.
- A bare module name, a function named without an arity, a variable, an operator
  and the `&` of a capture: the mention is `Module.fun/arity` (FUNC-2).
- A type, a callback, a `defstruct`, a module attribute and a macro the mention
  names by a name no definition of it has: the mention is a function's definition
  (FUNC-5).
- Reasoning text, notices, a compaction summary, a tool call's input and its
  output, and the user's own message: a mention is an assistant message's text
  (CITE-1's list).
- A tooltip or any other hover text: the link opens the line itself (EXPL-27).
- A jump to a definition outside the Files page, an editor and a hover preview:
  the link opens the Files page (EXPL-6), as a file mention's does (FLINK).
- Making the agent write the link itself: the transcript links a mention and the
  agent's own text is unchanged (FUNC-7).

## Stored data

Nothing stored changes. A message keeps the text the agent wrote, and the link is
derived from the workspace each time the message is rendered; no definition is
written anywhere.

## Implementation

`Elia.Source` (the definitions a workspace's own source holds: the modules each
file defines, and each function's name, arity and line — FUNC-4 to FUNC-6,
FUNC-9, FUNC-10), `Elia.Source.Cache` (the parsed index, kept while the files it
was made from are unchanged, as `Elia.Specs.Cache` keeps the corpus),
`EliaWeb.FunctionLinks` (which tokens are mentions, resolving them in the chat's
workspace, the Files URL — FUNC-1 to FUNC-4, FUNC-7), `EliaWeb.Markdown.to_html/2`
(the AST pass, in a chat's context, before the file-mention and citation passes,
which leave a link alone), `EliaWeb.FileLinks` (the URL a line takes, CITE-10's),
and `EliaWeb.ChatLive` (the transcript item, which already holds that context).
The look of a linked mention (FUNC-8) needs no rule of its own: the one a file
mention already has — `.markdown a:has(> code)` in `assets/css/app.css` — covers
it.

## Tests

- `test/elia/source_test.exs` (the module a file defines, a function's line and
  arities, default arguments, a nested module, a module two files define, the
  paths left out, a file that can't be parsed, a symlink, and an edit that is
  seen — FUNC-4, FUNC-5, FUNC-6, FUNC-9, FUNC-10).
- `test/elia_web/function_links_test.exs` (which tokens link and which don't,
  the URL and its line, the `Elixir.` prefix, and no context at all — FUNC-2,
  FUNC-3, FUNC-4).
- `test/elia_web/markdown_test.exs` (a mention in a reply, in an inline code span
  and in prose, a code block, a link's text, an image's alt text, and escaping —
  FUNC-1, FUNC-2, FUNC-3, FUNC-7, FUNC-8).
- `test/elia_web/live/chat_live_test.exs` (a mention in the streaming draft and
  in the saved transcript — FUNC-1, FUNC-4).
