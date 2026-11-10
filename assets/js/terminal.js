// A chat's terminal, in the browser (TERM-12, TERM-13, TERM-14, TERM-15,
// TERM-22).
//
// The session is a stream of bytes, so it does not go through the LiveView that
// owns the page: it has a channel of its own (`EliaWeb.TerminalChannel`, on
// `/terminal`). This hook is the other end of it — xterm.js writes what the
// session sends, and what the user types and the size of their box go back.
// The element it is mounted on belongs to it alone (`phx-update="ignore"`),
// because xterm.js draws into it and LiveView must not touch it.

import {Socket} from "phoenix"
import {Terminal} from "@xterm/xterm"
import {FitAddon} from "@xterm/addon-fit"

function csrfToken() {
  const meta = document.querySelector("meta[name='csrf-token']")
  return meta ? meta.getAttribute("content") : ""
}

// A terminal's bytes are not text: a keystroke is a byte, a paste is bytes, and
// half a UTF-8 character can arrive on its own. JSON carries bytes as base64,
// which is what both directions use (TERM-12, TERM-13).
function bytesToBase64(bytes) {
  let binary = ""
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

function base64ToBytes(data) {
  const binary = atob(data)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

export const TerminalHook = {
  mounted() {
    this.fontSize = parseInt(this.el.dataset.fontSize, 10) || 13
    this.chatId = this.el.dataset.chatId

    this.term = new Terminal({
      fontSize: this.fontSize,
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
      cursorBlink: true,
      // The same bound the session's own captures use (TERM-14, TERM-26).
      scrollback: 2000,
      theme: {
        background: "#181825",
        foreground: "#cdd6f4",
        cursor: "#f5e0dc",
        selectionBackground: "#585b70",
      },
    })

    this.fit = new FitAddon()
    this.term.loadAddon(this.fit)
    this.term.open(this.el)

    // TERM-15: the pty is resized to the box the browser can draw, on every
    // change of it — a phone turning, the font size changing, the page's own
    // layout settling. Registered before the first fit, which is itself a
    // change of size when the page is narrower than the session's own guess.
    this.term.onResize(({cols, rows}) => this.sendSize(cols, rows))

    this.fit.fit()

    this.socket = new Socket("/terminal", {params: {_csrf_token: csrfToken()}})
    this.socket.connect()
    this.join()

    // TERM-13: what is typed, byte for byte, into the app's stdin. xterm.js
    // gives the app its own echo, so nothing is drawn here.
    this.term.onData(data =>
      this.channel.push("input", {data: bytesToBase64(new TextEncoder().encode(data))})
    )

    this.observer = new ResizeObserver(() => this.fit.fit())
    this.observer.observe(this.el)

    // TERM-22: the font size is the page's setting; the terminal is the hook's,
    // so it arrives as an event rather than as markup.
    this.handleEvent("font_size", ({size}) => {
      this.term.options.fontSize = size
      this.fit.fit()
    })
  },

  // TERM-12, TERM-14: the channel, and what it says. A join is answered with
  // the screen the session has now, so a reload or a reconnect shows the app as
  // it is rather than an empty terminal.
  join() {
    this.channel = this.socket.channel(`terminal:${this.chatId}`, {})

    this.channel.on("screen", ({data}) => {
      this.term.reset()
      this.term.write(base64ToBytes(data))
    })

    this.channel.on("output", ({data}) => this.term.write(base64ToBytes(data)))

    // TERM-17: the session dropped this tab for falling behind. Joining again
    // is the whole answer: the screen it sends is the current one.
    this.channel.on("overflow", () => {
      this.channel.leave()
      setTimeout(() => this.join(), 250)
    })

    this.channel
      .join()
      .receive("ok", () => {
        this.fit.fit()
        // TERM-15: the size a channel can be told about is only one it is
        // joined for, so the current one goes now rather than only on a later
        // change.
        this.sendSize(this.term.cols, this.term.rows)
        this.term.focus()
      })
      .receive("error", ({message}) => {
        this.term.write(`\r\n[${message || "this chat has no terminal"}]\r\n`)
      })
  },

  sendSize(cols, rows) {
    if (this.channel && this.channel.state === "joined") {
      this.channel.push("resize", {cols, rows})
    }
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
    if (this.channel) this.channel.leave()
    if (this.socket) this.socket.disconnect()
    this.term.dispose()
  },
}
