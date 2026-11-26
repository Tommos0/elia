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

// TERM-44, TERM-45: the bar's modifier, which two hooks share — the bar arms it,
// and the terminal applies it to the next character typed on the soft keyboard.
// One object, in the module both hooks are built from, so the two see the same
// state instead of each keeping half of it. `terminal` is the hook that owns the
// channel, which is where a tap's key is sent (TERM-43, TERM-49).
const keys = {
  name: null,
  locked: false,
  terminal: null,
  watchers: [],

  watch(fn) {
    this.watchers.push(fn)
  },

  unwatch(fn) {
    this.watchers = this.watchers.filter(watcher => watcher !== fn)
  },

  set(name, locked) {
    this.name = name
    this.locked = !!locked
    this.watchers.forEach(fn => fn())
  },
}

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
    // TERM-22: the size the page opens with, before its own event arrives.
    this.fontSize = parseInt(this.el.dataset.fontSize, 10) || 9
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

    // SOCK-3, SOCK-5: the handshake carries the page's session proof — the
    // CSRF token of the session this server issued — and the socket refuses a
    // connection without one. It says the page came from this server, not who
    // is using it.
    this.socket = new Socket("/terminal", {params: {_csrf_token: csrfToken()}})
    this.socket.connect()
    this.join()

    // TERM-13, TERM-44: what is typed goes into the app's stdin — byte for byte,
    // unless the bar has a modifier armed for it.
    this.term.onData(data => this.typed(data))

    // TERM-42, TERM-49: the bar's taps go over this same channel, so a tap and a
    // typed character reach the app in the order they were made. The bar hook is
    // the other end of that (`keys.terminal`).
    keys.terminal = this

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

  // TERM-44: with a modifier armed on the bar, one character typed on the soft
  // keyboard is that modifier's key — Ctrl and `c` is `C-c`, which is the point
  // of arming one. (A bar key is not: see `press` below.) Everything else is text as it always was: a paste is not a
  // keystroke, and a character the notation cannot name takes no modifier.
  typed(data) {
    const modifier = keys.name
    const one = [...data].length === 1 && /^[A-Za-z0-9@?_^]$/.test(data)

    if (modifier && one) {
      // TERM-45: a locked modifier stays armed for the keys after this one.
      keys.set(keys.locked ? modifier : null, keys.locked)
      this.sendKeys(modifier + data)
    } else {
      this.sendText(data)
    }
  },

  // TERM-13: text goes as bytes, which is what the app's stdin takes.
  sendText(data) {
    this.channel.push("input", {data: bytesToBase64(new TextEncoder().encode(data))})
  },

  // TERM-43: a named key goes as its name in the notation the agent's own
  // keystrokes use — `<Esc>`, not the text `Esc`, which is what a bare name
  // would be (TERM-30) — so tmux expands it for the pane's own mode rather than
  // the browser mapping one to bytes itself.
  sendKeys(name) {
    this.channel.push("keys", {keys: `<${name}>`})
  },

  // TERM-44: a tap on the bar must not close the soft keyboard under it, so the
  // terminal's own input is left holding the focus.
  focusInput() {
    this.term.focus()
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
    keys.terminal = null
  },
}

// TERM-42, TERM-46, TERM-48: the key bar — the keys a phone's keyboard has not
// got. A button carries the name of the key it sends (`data-key`, in the
// notation the agent's own keystrokes use) or arms a modifier
// (`data-modifier`), and the terminal hook is what sends it, over the one
// channel this page has (TERM-43, TERM-49). Which modifier is armed is this
// hook's state and nobody else's: the server never sees it (TERM-42).
const REPEAT_DELAY = 400
const REPEAT_EVERY = 60
const CHOICE = "elia:terminal-keys"

export const TerminalKeysHook = {
  mounted() {
    this.timer = null
    // Whether the press already sent this button's key: a pointer sends on
    // `pointerdown`, so that holding a key can repeat, and the `click` that
    // follows it must not send a second time. A button reached with the
    // keyboard is a click and no pointer at all.
    this.sent = false
    this.toggle = document.querySelector("#terminal-keys-toggle")

    // A session starting is a fresh bar, and an armed modifier from the session
    // before it is not something to carry over.
    keys.set(null, false)
    this.renderKeys = () => this.render()
    keys.watch(this.renderKeys)
    this.render()

    this.released = () => this.stopRepeat()
    this.el.addEventListener("pointerdown", event => this.down(event))
    this.el.addEventListener("pointerleave", this.released)
    this.el.addEventListener("click", event => this.click(event))
    // A finger that comes off outside the bar — or is cancelled by the browser —
    // stops the repeat wherever it lands.
    window.addEventListener("pointerup", this.released)
    window.addEventListener("pointercancel", this.released)

    if (this.toggle) {
      this.toggle.addEventListener("click", () => this.flip())
      this.toggle.setAttribute("aria-pressed", String(this.visible()))
    }
  },

  destroyed() {
    this.stopRepeat()
    keys.unwatch(this.renderKeys)
    window.removeEventListener("pointerup", this.released)
    window.removeEventListener("pointercancel", this.released)
  },

  // TERM-44: the soft keyboard has to stay open under the bar, so a press must
  // not take the focus off the terminal's own input.
  down(event) {
    const button = event.target.closest("button")
    if (!button) return

    event.preventDefault()
    this.sent = true
    this.press(button)
    this.startRepeat(button)
  },

  click(event) {
    const button = event.target.closest("button")

    if (this.sent) {
      this.sent = false
      return
    }

    this.press(button)
  },

  // TERM-42, TERM-44: a key button sends the key it names, and a modifier button
  // arms, locks or turns off. A bar key is not given the armed modifier: tmux
  // expands the names it knows and types the rest as text, so `C-Escape` put in
  // front of a button's name would write those letters into the app, while
  // `C-Tab` and `C-Up` are keys. What a bar button can send is what its own name
  // carries — Ctrl-C is a button of its own (TERM-42) — and the armed modifier
  // is for the characters typed on the soft keyboard.
  press(button) {
    if (!button) return

    if (button.dataset.modifier) return this.arm(button.dataset.modifier)

    const name = button.dataset.key
    if (name) this.send(name)
  },

  // TERM-44, TERM-45: a tap arms it for the next character typed, a tap while it
  // is armed locks it for every character after that, and a tap while it is
  // locked turns it off. Tapping the other modifier moves to it.
  arm(modifier) {
    if (keys.name !== modifier) return keys.set(modifier, false)
    keys.set(keys.locked ? null : modifier, !keys.locked)
  },

  send(name) {
    keys.terminal?.sendKeys(name)
    keys.terminal?.focusInput()
  },

  // TERM-46: holding an arrow repeats it — once after a short delay, then at a
  // steady rate — and letting go stops it.
  startRepeat(button) {
    if (!("repeat" in button.dataset)) return

    this.stopRepeat()
    this.timer = setTimeout(() => {
      this.timer = setInterval(() => this.press(button), REPEAT_EVERY)
    }, REPEAT_DELAY)
  },

  stopRepeat() {
    clearTimeout(this.timer)
    clearInterval(this.timer)
    this.timer = null
  },

  // TERM-45: off, armed for one key, and locked are told apart by what the
  // button looks like and by what it says it is.
  render() {
    for (const button of this.el.querySelectorAll("[data-modifier]")) {
      const armed = keys.name === button.dataset.modifier
      const state = !armed ? "off" : keys.locked ? "locked" : "armed"

      button.dataset.state = state
      button.setAttribute("aria-pressed", String(armed))
      button.classList.toggle("btn-primary", armed)
      button.classList.toggle("btn-outline", !armed)
      button.classList.toggle("ring-2", state === "locked")
      button.classList.toggle("ring-primary", state === "locked")
    }
  },

  // TERM-48: the page's own answer to the pointer's default, remembered in this
  // browser. The class is on the document, put there while the page is parsed
  // (root.html.heex), so the choice is in place before the first paint.
  flip() {
    this.set(!this.visible())
  },

  set(on) {
    document.documentElement.classList.toggle("elia-keys-on", on)
    document.documentElement.classList.toggle("elia-keys-off", !on)

    try {
      localStorage.setItem(CHOICE, on ? "on" : "off")
    } catch (_) {
      /* a browser that refuses storage still gets the choice for this page */
    }

    if (this.toggle) this.toggle.setAttribute("aria-pressed", String(on))
  },

  // TERM-48: what the page is showing now — the choice when there is one, the
  // pointer's own answer when there is not.
  visible() {
    const root = document.documentElement.classList

    if (root.contains("elia-keys-on")) return true
    if (root.contains("elia-keys-off")) return false

    return matchMedia("(pointer: coarse)").matches
  },
}
