// Client-side syntax highlighting for the file explorer (EXPL-13).
//
// highlight.js core plus a fixed set of languages, bundled from
// assets/vendor/highlight. The server sends plain text and names the language
// in `data-language`; this hook swaps the text for highlighted markup.
import hljs from "../vendor/highlight/core.js"
import bash from "../vendor/highlight/languages/bash.js"
import c from "../vendor/highlight/languages/c.js"
import cpp from "../vendor/highlight/languages/cpp.js"
import css from "../vendor/highlight/languages/css.js"
import diff from "../vendor/highlight/languages/diff.js"
import dockerfile from "../vendor/highlight/languages/dockerfile.js"
import elixir from "../vendor/highlight/languages/elixir.js"
import erlang from "../vendor/highlight/languages/erlang.js"
import go from "../vendor/highlight/languages/go.js"
import ini from "../vendor/highlight/languages/ini.js"
import javascript from "../vendor/highlight/languages/javascript.js"
import json from "../vendor/highlight/languages/json.js"
import makefile from "../vendor/highlight/languages/makefile.js"
import markdown from "../vendor/highlight/languages/markdown.js"
import plaintext from "../vendor/highlight/languages/plaintext.js"
import python from "../vendor/highlight/languages/python.js"
import ruby from "../vendor/highlight/languages/ruby.js"
import rust from "../vendor/highlight/languages/rust.js"
import shell from "../vendor/highlight/languages/shell.js"
import sql from "../vendor/highlight/languages/sql.js"
import typescript from "../vendor/highlight/languages/typescript.js"
import xml from "../vendor/highlight/languages/xml.js"
import yaml from "../vendor/highlight/languages/yaml.js"

const languages = {bash, c, cpp, css, diff, dockerfile, elixir, erlang, go, ini, javascript, json, makefile, markdown, plaintext, python, ruby, rust, shell, sql, typescript, xml, yaml}

for (const [name, definition] of Object.entries(languages)) {
  hljs.registerLanguage(name, definition)
}

function highlight(el) {
  const language = el.dataset.language
  if (!language || !hljs.getLanguage(language)) return

  try {
    // highlight.js escapes the text, and only wraps tokens in <span>s, so the
    // text content (and the line count) stays the same.
    const {value} = hljs.highlight(el.textContent, {language, ignoreIllegals: true})
    el.innerHTML = value
  } catch (_error) {
    // Leave the plain text in place.
  }
}

// The class of the mark a named line gets (EXPL-27).
const markClass = "file-line-mark"

// EXPL-27: mark the line the server named in `data-line` and bring it into
// sight. Both are the browser's own — the mark is a `span` over that line's
// characters, and the scroll is the pane's — and both come after the
// highlighting, which has replaced the element's markup by now.
function mark(el) {
  // A previous mark is not part of the server's text, so it goes first: a
  // line that is no longer named (or a file with no line at all) keeps none.
  el.querySelectorAll(`span.${markClass}`).forEach((span) => span.replaceWith(...span.childNodes))

  const line = Number.parseInt(el.dataset.line ?? "", 10)
  if (!Number.isInteger(line) || line < 1) return

  const text = el.textContent
  let start = 0

  for (let n = 1; n < line; n++) {
    const newline = text.indexOf("\n", start)
    if (newline === -1) return
    start = newline + 1
  }

  const end = text.indexOf("\n", start)
  const span = wrap(el, start, end === -1 ? text.length : end)
  if (span) span.scrollIntoView({block: "center"})
}

// Wraps the flat text's characters from `start` to `end` in a single `span` of
// their own: the line may begin or end inside a token highlight.js wrapped, so
// the range is built from the text nodes it falls in, and the tokens that
// straddle it are cloned rather than flattened, keeping their colours. The text
// itself is unchanged, so the line numbers still line up (EXPL-13).
function wrap(el, start, end) {
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
  let offset = 0
  let from = null
  let to = null

  while (walker.nextNode()) {
    const node = walker.currentNode
    const length = node.data.length

    if (!from && start < offset + length) from = [node, start - offset]
    if (from && end <= offset + length) {
      to = [node, end - offset]
      break
    }

    offset += length
  }

  if (!from || !to) return null

  const range = document.createRange()
  range.setStart(from[0], from[1])
  range.setEnd(to[0], to[1])

  const span = document.createElement("span")
  span.className = markClass
  span.appendChild(range.extractContents())
  range.insertNode(span)

  return span
}

export const Highlight = {
  mounted() {
    highlight(this.el)
    mark(this.el)
  },
  // LiveView restores the server's plain text on patches, so run again. The
  // mark goes after the highlighting either way: highlight.js replaces the
  // element's markup, and a mark applied before it would go with it (EXPL-27).
  updated() {
    highlight(this.el)
    mark(this.el)
  },
}
