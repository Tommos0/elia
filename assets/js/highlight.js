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

export const Highlight = {
  mounted() { highlight(this.el) },
  // LiveView restores the server's plain text on patches, so run again.
  updated() { highlight(this.el) },
}
