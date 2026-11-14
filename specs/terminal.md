# Terminal

Status: Draft

A Terminal page shows a chat a real terminal: a pty running a command — the
user's own shell, or a terminal app the agent started — drawn with xterm.js in
the browser, with keystrokes going back the other way. It answers what the
[`shell` tool](shell-tool.md) cannot: an app that has to run *while* you watch
it and take input — a REPL, `htop`, a watch-mode test run, an interactive
installer — instead of a command that finishes and comes back as a block of
text.

The session layer is **tmux, driven in control mode**. tmux is what gives the
command a pty: the BEAM has none, and a plain port gives a child no line
discipline, no window size and no `SIGWINCH`, so a full-screen app drawn
through one is wrong from the first redraw. tmux also owns the two things a
terminal in a browser needs and cannot fake — resizing the pty to the client's
box, and telling a client what is on the screen *now* after a reconnect.
Control mode is what makes it work with a plain port: `tmux -C attach` reads
commands on stdin and writes notifications on stdout, so nothing on the Elixir
side needs a pty of its own.

Elia still owns the process. One session is one jailed, niced process tree —
the tmux server, the client and the app inside them — started through the same
jail argv as a tool call ([ISOL-2](command-isolation.md)) and the same priority
wrapper ([PRIO-1](process-priority.md)), in the chat's own workspace, and
killed as a whole when the session stops. So a terminal is not a way around the
guardrails: it is the same confinement as a command, held open.

## Requirements

### Sessions

- **TERM-1** A chat has at most one terminal session at a time. Starting one
  while another is running is refused, with what to do about it (stop it, or
  use it), rather than silently replacing it — the second start is a tool call
  the model made, and killing a session the user is watching is the user's
  decision (TERM-3). A session whose command has exited is not running, so a
  new one starts normally.
- **TERM-2** A session runs in the chat's workspace root: the chat's project
  folder (PROJ-12), which for a chat in Elia's own project is that chat's own
  worktree (DEPLOY-1). It gets the environment a jailed command gets (ISOL-8)
  and a terminal of its own (TERM-7).
- **TERM-3** A session stops when the user presses Stop, when the chat is
  deleted, or when its command exits on its own. Stopping kills the whole
  process tree and the namespace it runs in, so nothing is left running: the
  kill is the one a timed-out command gets (SHELL-3, ISOL-10), and the jail
  takes its pid namespace with it. No process of a stopped session outlives it.
- **TERM-4** A session records how it ended — the command's exit status, or the
  stop — and the page says so (TERM-23).
- **TERM-5** The page's default command is the configured one, or the user's
  login shell (`$SHELL`, else `bash`, else `sh`) started as a login shell, in
  the workspace. The command is editable on the page before starting (TERM-19),
  so a terminal app is one field away from a shell.
- **TERM-6** A session belongs to the running server and does not survive a
  restart or a deploy: it is a process tree of this VM (TERM-3), and a deploy
  restarts the server. The page says a session ended this way instead of
  showing an empty terminal that looks broken (TERM-23). A session that
  outlives the server would have to sit outside the jail, which is the trade
  this feature does not make.

### Guardrails

- **TERM-7** The session's process tree is jailed with the argv a command gets
  (ISOL-2, ISOL-13), built by `Elia.Shell` rather than by a second copy of it:
  one definition of the jail, so a change to it reaches the terminal too, and a
  host with no bubblewrap (ISOL-12) behaves as it does for a command. The
  profile follows the workspace as it does for a command (ISOL-13), so a chat
  worktree gets the worktree's binds and its dependency overlay.
- **TERM-8** The session runs at the lower CPU and I/O priority a command runs
  at (PRIO-1, PRIO-3, PRIO-4) through `Elia.Priority`, and the whole tree under
  it inherits it. A watch-mode test run or a TUI in a terminal therefore
  doesn't take the machine from the UI and the agent loops — the reason the
  wrapper exists (PRIO), and the case it was written for.
- **TERM-9** What a terminal can reach is what a jailed command in that
  workspace can reach (ISOL-25), because it is the same jail: the workspace,
  plus for a worktree the trees its profile binds, and never the masked
  `.elia` (ISOL-6). A chat whose jail the user turned off (ISOL-16) gets an
  unjailed terminal — the user's own machine, on purpose — and both the page
  and the tool's result say so (ISOL-17), at the moment it matters.
- **TERM-10** Starting a session from the agent (`terminal_start`, TERM-24)
  needs the user's approval, like the `shell` tool (SHELL-1, APPR). A session
  the user opens from the page needs none: the user is the one acting. What is
  approved is the *command*, not the session: **keystrokes into a running
  session are never individually approved** — an approved terminal is an
  approved shell, and the page's Stop is the control. The spec says so plainly
  because it is the one place a terminal is weaker than the `shell` tool, whose
  every call is approved.
- **TERM-11** A terminal is not a turn: starting one returns at once instead of
  holding the turn open, and a running session doesn't make the chat busy or
  show it as working (SESS). Nothing a session prints goes into the transcript
  — the transcript keeps the tool call and its result (the session's page and
  status), and the output belongs on the page, which is the point of it.

### Streaming

- **TERM-12** Output reaches the browser as bytes over a Phoenix Channel and is
  written into xterm.js as it arrives, without a reload and without going
  through the LiveView's diffing, which is for markup, not for a terminal
  stream.
- **TERM-13** Keystrokes and pasted text go back as bytes and reach the
  command's stdin unchanged — control characters, escape sequences and
  non-ASCII included — with the app's own echo, not the browser's. What is
  typed arrives in order and is never re-encoded or line-buffered on the way.
- **TERM-14** A client that joins — the first open, a reload, or a reconnected
  socket (CONN) — is sent the session's current screen and its scrollback
  first, and the live stream from then on, so a reconnect shows the app as it
  is rather than an empty terminal or a screen that stops where the socket
  dropped. Output written in the moment of the join may be repeated or missed;
  nothing else about the session changes, and the app is not restarted to
  satisfy a client.
- **TERM-15** The pty is resized to the client's box: on join, and whenever the
  browser's size or the page's layout changes, the app's terminal is set to the
  columns and rows the browser's font metrics allow. An app that redraws on
  `SIGWINCH` redraws, and a phone gets the width it actually has (TERM-22)
  instead of a 80-column screen squeezed into it.
- **TERM-16** More than one browser tab may watch the same session: each is
  sent the stream, and input from any of them reaches the command. A session is
  the chat's, not the tab's.
- **TERM-17** The session never buffers unbounded output for a client that
  can't keep up: a client that falls too far behind is disconnected and told
  so, and re-joins with the current screen (TERM-14) rather than making the
  session hold its backlog in memory.
- **TERM-18** The control channel is joined only for a session that exists and
  belongs to the chat it claims (TERM-2), and a join for a session that has
  ended returns what ended it (TERM-4) instead of a stream that never starts.

### Page

- **TERM-19** `/c/:id/terminal` is the chat's terminal page: in the browser
  pipeline and the default `live_session`, like the app's other pages, shown
  with the chat's title, and reachable from the chat.
- **TERM-20** With no running session the page shows what would run — the
  default command (TERM-5) in an editable field, the workspace it runs in, and
  whether the jail is on (TERM-9) — with a Start button.
- **TERM-21** With a running session the page shows the terminal filling the
  page — its own width on a phone, not the chat column — with the command, its
  status (running, or exited with status N) and a Stop button.
- **TERM-22** The page is legible and usable at a phone width: the terminal
  fits its box (TERM-15) instead of overflowing sideways, and the font size is
  a setting on the page so a small screen can trade columns for legibility.
- **TERM-23** A session that has ended reads as what it is, with what ended it
  — the command's status, the stop, or the restart (TERM-4, TERM-6) — and a
  chat with no session reads as an offer to start one. Neither is a blank
  terminal that looks broken.
- **TERM-24** xterm.js is a local asset in the bundle, not a CDN: the page
  works with the network gone and inside the installed app (PWA), like the rest
  of the UI.

### Tools

- **TERM-25** `terminal_start` starts a session with a command the model gives,
  in the chat's workspace, needing approval (TERM-10), and returns at once
  (TERM-11) with the session's page and its status. It refuses when the chat
  already has a running session (TERM-1), and says the jail is off when it is
  (TERM-9).
- **TERM-26** `terminal_read` returns the session's current screen — up to the
  configured scrollback lines — as plain text, truncated like a command's
  output (SHELL-5), so the agent can see what an app is showing without a
  screenshot. A session that has ended is read as well as one that is running —
  what an app printed before it died is usually what is wanted — and the screen
  says which of the two it is and how the session ended (TERM-4, TERM-23).
  Only a chat with no terminal at all is an error, and it says so.
- **TERM-27** `terminal_stop` stops the session (TERM-3) and returns how it
  ended (TERM-4).
- **TERM-28** The skill's instructions say when a terminal is the right tool —
  an app that must run while the user watches it or types into it, where the
  `shell` tool's finish-and-return shape is wrong — that starting one needs
  approval and that the user can then type into it, that it runs jailed and at
  lower priority like a command (TERM-7, TERM-8), that its output is not in the
  transcript, that reading the screen is `terminal_read`, not `shell`, and that
  the agent can type into a running session with `terminal_send` (TERM-30),
  which needs approval of its own (TERM-32).

#### Typing in

- **TERM-30** `terminal_send` types into the chat's terminal, so the agent can
  drive an app the user is watching: `keys` is a short notation in which text
  goes as it is and `<Name>` names a key in *tmux's* vocabulary — `<C-x>`,
  `<C-s>`, `<Escape>`, `<Enter>`, `<Tab>`, `<Up>`, `<BSpace>`, `<F5>` — so the
  model uses key names it already knows, and the familiar spellings of the same
  keys (`<Esc>`, `<CR>`, `<PgUp>`) are taken as those keys. A `<...>` that does
  not look like a key name — prose, `<b>`, a single character, `<foo bar>` — is
  still literal text, so a `<` needs no escaping, where one that does look like
  a key name and is not one tmux knows is refused rather than typed (TERM-31).
  What reaches
  the app is what a keyboard would send, as bytes, in order (TERM-13) — the same
  door the browser's keystrokes come through, in the same session, jail and
  priority as everything else (TERM-2, TERM-7, TERM-8).
- **TERM-31** A named key goes to tmux *by name* and is expanded there, never
  mapped to bytes by Elia: tmux knows the pane's current mode, so an app that
  turned on application cursor keys (`ESC [ ? 1 h`, DECCKM) gets `ESC O A` for
  `<Up>` where one that did not gets `ESC [ A` (verified against tmux 3.5a). A
  name is accepted only if it is one tmux itself knows — or one of the aliases
  of TERM-30 — optionally with `C-`, `M-` or `S-` in front; an unknown name is
  refused with an error rather than passed on, because tmux would take it for
  literal text and type a typo into someone's shell, and because the name is
  spliced into a command line tmux parses. Text goes as `send-keys -H` hex, so
  nothing a model sends can be read as a tmux command (TERM-13).
- **TERM-32** `terminal_send` needs the user's approval, like `shell` (APPR-7),
  and the call shows the keys it would send; the chat's auto-approval switch
  waives it as it does for any tool (APPR-8). This does not touch TERM-10: what
  the *user* types on the page is still never approved, because that is the user
  acting, where this is the agent acting.
- **TERM-33** Sending reads the screen back only when the call asks for it:
  `read: true` waits `wait_ms` (default 300, clamped to a few seconds) and
  returns the screen the way `terminal_read` returns it (TERM-26); without it
  the call returns as soon as the keys are sent, and a send that reads nothing
  puts no screen text in the transcript (TERM-11). The wait is what makes the
  read see the effect of the keys: a step's tools run concurrently (LOOP-10), so
  a `terminal_read` called alongside a `terminal_send` can read the screen as it
  was before them.
- **TERM-34** Sending is refused, saying which, when the chat has no terminal
  and when its command has ended: there is nothing to type into, and a send
  never starts or restarts a session (TERM-1, TERM-23, TERM-26).

### Availability

- **TERM-29** Where tmux isn't installed the feature is unavailable and says
  so: the page explains it, with what to install, instead of a Start button
  that fails, and `terminal_start` returns that as its error (the shape of
  ISOL-12's missing-bubblewrap notice). The tmux path is configuration,
  resolved from `PATH` when unset.

## Configuration

```elixir
config :elia, Elia.Terminal,
  tmux: nil,             # resolved from PATH when unset
  default_command: nil,  # nil: the user's login shell (TERM-5)
  scrollback_lines: 2_000,  # what terminal_read returns, and what a join replays
  max_sessions: 8        # across chats, a bound on pty processes
```

## Out of scope

- **~~Typing into a session from the agent~~** (`terminal_send`). Removed:
  `terminal_send` is in the spec now (TERM-30..TERM-34), with the answer this
  entry was waiting for — the agent's keystrokes get the approval the agent's
  commands get, and no more (TERM-32).
- **Pasting as a paste.** A send arrives as keystrokes, the way a user typing
  them would, so an app that asks for bracketed paste (`ESC [ 200 ~`) sees a
  fast typist rather than a paste. tmux's own `paste-buffer` is the way to a
  real one if that turns out to matter (TERM-30).
- **A session that survives a restart or a deploy** (TERM-6). It would need the
  process tree to sit outside the jail, or a detached namespace the next server
  can re-enter, which is the thing the jail is for.
- **Several terminals per chat, or a terminal per project.** One per chat keeps
  the lifecycle (TERM-1, TERM-3) and the page simple; a chat that needs two can
  use tmux's own windows inside the one session, which is the point of the
  session layer.
- **Access control.** Like Logs and Sessions, anyone who can reach the app can
  open a terminal in any chat's workspace. The jail (TERM-7) bounds what it can
  reach, not who may open it.
- **A shell in the live tree rather than a chat's workspace.** A chat's
  terminal is its workspace's (TERM-2); the deploy and the live tree have no
  page of their own.
- **Recording or replaying a session's output**, sharing it, or keeping it
  across sessions. The page shows the live screen; the transcript keeps the
  tool call (TERM-11).
- **A window size on a detached session, mouse reporting, and sixel/kitty image
  protocols** — what xterm.js and tmux support between them is what a terminal
  here is.

## Implementation

`Elia.Terminal` (the session registry and its supervisor, one per chat),
`Elia.Terminal.Session` (the port, control mode's notifications, the screen,
the resize, the keys and the stop), `Elia.Terminal.Keys` (the `<Name>` notation,
the aliases and the key-name whitelist, TERM-30, TERM-31), `Elia.Shell` (the
jail argv
exposed for TERM-7 — the terminal must not carry a second copy of it),
`Elia.Priority` (the wrapper), `Elia.Skills.Terminal` (the tools and the
instructions), `EliaWeb.TerminalLive` (the page), `EliaWeb.TerminalSocket` and
`EliaWeb.TerminalChannel` (the stream), `assets/js/terminal.js` (the xterm.js
hook), the router and the endpoint (the socket), `assets/package.json`
(xterm.js and its fit addon).

The exact tmux interface is settled in the implementation against the tmux the
host has, and the spec follows if it moves: control mode's notifications
(`%output` with escaped bytes, `%begin`/`%end` around a command's reply) for the
stream, `capture-pane` for TERM-14 and TERM-26, `refresh-client -C` for
TERM-15, `send-keys` for TERM-13 and TERM-30 — by name for a key, `-H` with hex
bytes for text, so nothing a model sends can be read as a tmux command
(TERM-31). A tmux whose control mode doesn't hold up would mean the session
layer moves — to the app under a pty allocated by `script`, at the cost of
TERM-15 — and that is a spec change, not a silent substitution.

## Tests

`test/elia/terminal_test.exs` (the argv: jail and priority, one session per
chat, the stop leaving nothing running, the missing tmux, the screen and resize
commands, and the keys reaching a real app — a name expanded by tmux for the
pane's own mode — TERM-1 to TERM-11), `test/elia/terminal/keys_test.exs` (the notation, its aliases
and the whitelist, TERM-30, TERM-31),
`test/elia_web/live/terminal_live_test.exs` (the page's states,
TERM-19..TERM-23), `test/elia_web/terminal_channel_test.exs` (join,
keystrokes to the command's stdin, output to the client, resize, a join for an
ended session, TERM-12..TERM-18), `test/elia/skills/terminal_test.exs` (the
tools, TERM-24 to TERM-28 and TERM-30 to TERM-34), and
`test/elia_web/browser/terminal_test.exs` for the parts that are a browser:
typing into a running shell and seeing its echo, and a resize that reaches the
pty (BROWSER-1). A test that needs tmux skips where it isn't installed
(TERM-29), like the jail's tests where bubblewrap is missing (ISOL-12).
